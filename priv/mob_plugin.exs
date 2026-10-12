# Mob plugin manifest (see PLAN.md). mob_dev cross-compiles egit's NIF and
# libgit2 into one static archive, libgit.a, per target ABI and links it into
# the app; the driver table registers it as the static NIF `git`.
#
# Android only so far; HTTPS through mbedTLS (vendor/mbedtls).
libgit2_sources = Code.eval_file(Path.join(__DIR__, "native/sources.exs")) |> elem(0)

# mbedTLS ships its generated sources in release tags, so the library is
# compiled as is. Its private headers sit next to the sources and are found
# through quoted includes, so vendor/mbedtls/library is not an include dir
# (its common.h would shadow libgit2's).
mbedtls_sources =
  Path.join(__DIR__, "../vendor/mbedtls/library/*.c")
  |> Path.wildcard()
  |> Enum.map(&Path.relative_to(&1, Path.expand("..", __DIR__)))
  |> Enum.sort()

%{
  name: :egit,
  mob_version: "~> 0.9",
  plugin_spec_version: 1,
  description: "libgit2 bindings (egit) for Mob apps",
  nifs: [
    %{
      # egit's ERL_NIF_INIT(git, …): the static NIF name and init symbol.
      module: :git,
      lang: :cpp_archive,
      platform: :android,
      nm_symbol: "git_nif_init",
      sources: ["c_src/git.cpp" | libgit2_sources ++ mbedtls_sources],
      # priv/native first: it holds git2_features.h, which CMake would generate.
      includes: [
        "priv/native",
        "vendor/libgit2/include",
        "vendor/libgit2/src/libgit2",
        "vendor/libgit2/src/util",
        "vendor/libgit2/deps/llhttp",
        "vendor/libgit2/deps/xdiff",
        "vendor/mbedtls/include"
      ],
      cxxflags: [
        "-std=c++20",
        "-O2",
        "-DNDEBUG",
        "-DHAVE_FORMAT",
        "-DHAVE_SRCLOC",
        "-DSTATIC_ERLANG_NIF_LIBNAME=git"
      ],
      # As libgit2's CMake build compiles them. The SHA1DC_* defines only matter
      # to the sha1dc sources. GIT_DEFAULT_CERT_LOCATION is the CA store libgit2
      # loads at init; Android has had it since API 1. egit's
      # set_ssl_cert_locations/1 replaces it at runtime (e.g. with the APEX store).
      cflags: [
        "-std=c99",
        "-O2",
        "-DNDEBUG",
        "-D_GNU_SOURCE",
        "-fvisibility=hidden",
        "-DSHA1DC_NO_STANDARD_INCLUDES=1",
        "-DSHA1DC_CUSTOM_INCLUDE_SHA1_C=\"git2_util.h\"",
        "-DSHA1DC_CUSTOM_INCLUDE_UBC_CHECK_C=\"git2_util.h\"",
        "-DMBEDTLS_CONFIG_FILE=\"egit_mbedtls_config.h\"",
        "-DGIT_DEFAULT_CERT_LOCATION=\"/system/etc/security/cacerts\""
      ]
    }
  ]
}
