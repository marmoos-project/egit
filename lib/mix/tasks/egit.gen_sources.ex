defmodule Mix.Tasks.Egit.GenSources do
  @shortdoc "Regenerates the libgit2 source list for the Mob plugin build"

  @moduledoc """
  Regenerates `priv/native/sources.exs`, the libgit2 C sources that
  `priv/mob_plugin.exs` hands to mob_dev's `cpp_archive` builder, and checks the
  hand-maintained build settings against libgit2's own build.

      mix egit.gen_sources [--ndk PATH] [--check] [--keep]

  It runs libgit2's CMake configure (`vendor/libgit2`) for Android arm64 with
  the plugin's options (`@cmake_options` below), then:

    * writes the sources from the generated `compile_commands.json`, relative
      to the repo root;
    * compares the generated `git2_features.h` with
      `priv/native/git2_features.h`, which stays hand-merged (it covers every
      ABI and, later, iOS), and reports the defines that differ;
    * reports the `-D` flags libgit2 compiles with that the manifest's
      `:cflags` lack.

  Run it after moving the `vendor/libgit2` submodule. The mbedTLS sources need
  no list: the manifest takes every `vendor/mbedtls/library/*.c`.

  ## Options

    * `--ndk PATH` - Android NDK root. Defaults to `$ANDROID_NDK_HOME`,
      `$ANDROID_NDK_ROOT`, then the newest NDK under `$ANDROID_HOME/ndk`,
      `$ANDROID_SDK_ROOT/ndk` or `~/Android/Sdk/ndk`.
    * `--check` - write nothing; fail if `sources.exs` is out of date.
    * `--keep` - keep the CMake build directory and print its path.

  Needs `cmake` and `ninja` on the `PATH`.
  """
  use Mix.Task

  # libgit2 build options for the plugin; see PLAN.md, "Decisions". The mbedTLS
  # library paths and CERT_LOCATION are added by cmake_args/3: CMake only
  # checks that they exist, and the archive is built by mob_dev, not CMake.
  @cmake_options [
    "-DCMAKE_BUILD_TYPE=Release",
    "-DBUILD_SHARED_LIBS=OFF",
    "-DBUILD_TESTS=OFF",
    "-DBUILD_EXAMPLES=OFF",
    "-DBUILD_CLI=OFF",
    "-DUSE_THREADS=ON",
    "-DUSE_SSH=OFF",
    "-DUSE_HTTPS=mbedTLS",
    "-DUSE_NTLMCLIENT=OFF",
    "-DUSE_GSSAPI=OFF",
    "-DUSE_AUTH_NEGOTIATE=OFF",
    "-DUSE_AUTH_NTLM=OFF",
    "-DREGEX_BACKEND=regcomp",
    "-DUSE_SHA1=CollisionDetection",
    "-DUSE_SHA256=Builtin",
    "-DUSE_BUNDLED_ZLIB=OFF",
    "-DUSE_HTTP_PARSER=builtin"
  ]

  # Mob's minimum Android API (MobDev.Plugin.CppArchive builds for it too).
  @android_api 28

  @sources_file "priv/native/sources.exs"
  @features_file "priv/native/git2_features.h"
  @manifest_file "priv/mob_plugin.exs"

  # Defines git2_features.h is expected to differ on: the hand-merged header
  # picks the arch from the pointer size instead of CMake's single value.
  @features_expected_extra ~w(GIT_ARCH_32)

  # -D flags from the NDK toolchain or the build type, not libgit2's own.
  @toolchain_defines ~w(ANDROID NDEBUG _FORTIFY_SOURCE)

  @switches [ndk: :string, check: :boolean, keep: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("Unknown options: #{inspect(invalid)}")

    root = Path.dirname(Mix.Project.project_file())
    libgit2 = Path.join(root, "vendor/libgit2")

    unless File.exists?(Path.join(libgit2, "CMakeLists.txt")),
      do: Mix.raise("#{libgit2} is empty; run `git submodule update --init vendor/libgit2`")

    ndk = opts[:ndk] || find_ndk() || Mix.raise("No Android NDK found; pass --ndk PATH")
    toolchain = Path.join(ndk, "build/cmake/android.toolchain.cmake")
    unless File.exists?(toolchain), do: Mix.raise("No CMake toolchain file at #{toolchain}")

    for exe <- ~w(cmake ninja),
        is_nil(System.find_executable(exe)),
        do: Mix.raise("#{exe} not found on the PATH")

    build = Path.join(System.tmp_dir!(), "egit_gen_sources_#{System.unique_integer([:positive])}")

    try do
      configure(libgit2, build, toolchain, ndk, root)
      commands = build |> Path.join("compile_commands.json") |> File.read!() |> JSON.decode!()

      sources_ok? = write_sources(commands, root, opts[:check])
      check_features(Path.join(build, "gen_headers/git2_features.h"), Path.join(root, @features_file))
      check_defines(commands, Path.join(root, @manifest_file))

      if opts[:check] && !sources_ok?,
        do: Mix.raise("#{@sources_file} is out of date; run `mix egit.gen_sources`")
    after
      if opts[:keep],
        do: Mix.shell().info("CMake build directory kept: #{build}"),
        else: File.rm_rf!(build)
    end
  end

  # ── CMake ───────────────────────────────────────────────────────────────────

  defp configure(libgit2, build, toolchain, ndk, root) do
    Mix.shell().info("Configuring libgit2 with #{Path.basename(ndk)} NDK…")
    File.mkdir_p!(build)

    {output, status} =
      System.cmd("cmake", cmake_args(libgit2, build, toolchain, root), stderr_to_stdout: true)

    if status != 0 do
      Mix.shell().error(output)
      Mix.raise("CMake configure of libgit2 failed (exit #{status})")
    end
  end

  defp cmake_args(libgit2, build, toolchain, root) do
    # FindmbedTLS wants library files; empty stand-ins are enough to configure.
    fake = Path.join(build, "fake_mbedtls")
    File.mkdir_p!(fake)

    [tls, x509, crypto] =
      for name <- ~w(libmbedtls.a libmbedx509.a libmbedcrypto.a) do
        path = Path.join(fake, name)
        File.touch!(path)
        path
      end

    ["-S", libgit2, "-B", build, "-G", "Ninja", "-Wno-dev", "-Wno-deprecated"] ++
      [
        "-DCMAKE_TOOLCHAIN_FILE=#{toolchain}",
        "-DANDROID_ABI=arm64-v8a",
        "-DANDROID_PLATFORM=android-#{@android_api}",
        "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON"
      ] ++
      @cmake_options ++
      [
        "-DMBEDTLS_INCLUDE_DIR=#{Path.join(root, "vendor/mbedtls/include")}",
        "-DMBEDTLS_LIBRARY=#{tls}",
        "-DMBEDX509_LIBRARY=#{x509}",
        "-DMBEDCRYPTO_LIBRARY=#{crypto}",
        # Must exist on the host; the manifest sets the device path itself.
        "-DCERT_LOCATION=#{tls}"
      ]
  end

  defp find_ndk do
    explicit = Enum.find_value(~w(ANDROID_NDK_HOME ANDROID_NDK_ROOT), &System.get_env/1)

    if explicit do
      explicit
    else
      [System.get_env("ANDROID_HOME"), System.get_env("ANDROID_SDK_ROOT"), Path.expand("~/Android/Sdk")]
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "ndk/*")))
      |> Enum.filter(&File.dir?/1)
      |> Enum.max_by(&ndk_version/1, Version, fn -> nil end)
    end
  end

  # NDK directories are named like 27.2.12479018.
  defp ndk_version(dir) do
    case Version.parse(Path.basename(dir)) do
      {:ok, version} -> version
      :error -> Version.parse!("0.0.0")
    end
  end

  # ── sources.exs ─────────────────────────────────────────────────────────────

  # Returns whether the file on disk already matched.
  defp write_sources(commands, root, check?) do
    sources =
      commands
      |> Enum.map(&Path.relative_to(&1["file"], root))
      |> Enum.uniq()
      |> Enum.sort()

    path = Path.join(root, @sources_file)

    old =
      case File.read(path) do
        {:ok, _} -> path |> Code.eval_file() |> elem(0)
        {:error, _} -> []
      end

    added = sources -- old
    removed = old -- sources

    cond do
      added == [] and removed == [] ->
        Mix.shell().info("#{@sources_file}: up to date (#{length(sources)} files)")
        true

      check? ->
        report_changes(added, removed)
        false

      true ->
        File.write!(path, render_sources(sources))
        Mix.shell().info("#{@sources_file}: written (#{length(sources)} files)")
        report_changes(added, removed)
        false
    end
  end

  defp render_sources(sources) do
    """
    # libgit2 C sources for the cpp_archive NIF, relative to the plugin root.
    # Generated by `mix egit.gen_sources` from libgit2's CMake configure for
    # Android; do not edit by hand.
    [
    #{Enum.map_join(sources, ",\n", &~s(  "#{&1}"))}
    ]
    """
  end

  defp report_changes(added, removed) do
    for f <- added, do: Mix.shell().info("  + #{f}")
    for f <- removed, do: Mix.shell().info("  - #{f}")
  end

  # ── Hand-maintained settings ────────────────────────────────────────────────

  defp check_features(generated, ours) do
    cmake = defines_in(generated)
    local = defines_in(ours)

    missing = MapSet.difference(cmake, local) |> Enum.sort()

    extra =
      MapSet.difference(local, cmake)
      |> Enum.reject(&(&1 in @features_expected_extra))
      |> Enum.sort()

    if missing == [] and extra == [] do
      Mix.shell().info("#{@features_file}: matches libgit2's CMake output")
    else
      Mix.shell().error("#{@features_file} differs from libgit2's CMake output; merge by hand:")
      for d <- missing, do: Mix.shell().error("  missing #define #{d}")
      for d <- extra, do: Mix.shell().error("  extra   #define #{d}")
    end
  end

  # Every macro the header defines, whatever #if it sits under, minus its
  # include guard.
  defp defines_in(path) do
    ~r/^\s*#\s*define\s+([A-Za-z_][A-Za-z0-9_]*)/m
    |> Regex.scan(File.read!(path), capture: :all_but_first)
    |> List.flatten()
    |> Enum.reject(&(&1 == "INCLUDE_features_h__"))
    |> MapSet.new()
  end

  defp check_defines(commands, manifest) do
    wanted =
      commands
      |> Enum.flat_map(&command_defines/1)
      |> Enum.reject(&(&1 in @toolchain_defines))
      |> MapSet.new()

    {manifest_map, _} = Code.eval_file(manifest)

    have =
      manifest_map.nifs
      |> Enum.flat_map(&Map.get(&1, :cflags, []))
      |> Enum.flat_map(&define_name/1)
      |> MapSet.new()

    case wanted |> MapSet.difference(have) |> Enum.sort() do
      [] ->
        Mix.shell().info("#{@manifest_file}: cflags carry every libgit2 -D flag")

      missing ->
        Mix.shell().error("#{@manifest_file}: cflags lack libgit2's -D flags:")
        for d <- missing, do: Mix.shell().error("  -D#{d}")
    end
  end

  defp command_defines(%{"arguments" => args}), do: Enum.flat_map(args, &define_name/1)
  defp command_defines(%{"command" => cmd}), do: cmd |> OptionParser.split() |> Enum.flat_map(&define_name/1)

  defp define_name("-D" <> define), do: [define |> String.split("=", parts: 2) |> hd()]
  defp define_name(_), do: []
end
