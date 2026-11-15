defmodule Mix.Tasks.Compile.EgitNif do
  @shortdoc "Builds the host NIF, for tests"
  @moduledoc """
  Builds egit's NIF for the host with `c_src/Makefile`, against the system
  libgit2 (found with `pkg-config`), into `<app path>/native/git.so`, where
  `git:on_load/0` looks after `priv/`. Never into `priv/`: `_build` symlinks
  it to the sources, so it would be shared by every env and bundled into a
  Mob app. On a device the NIF is static, cross-compiled by mob_dev from
  `priv/mob_plugin.exs`.

  It runs in the test build only, `_build/test`, egit's own or that of an app
  depending on it: Mix compiles a dependency in `:prod`, so `Mix.env/0` does
  not tell, but its build path is the app's. `EGIT_HOST_NIF=1` forces it in
  any build, `EGIT_HOST_NIF=0` skips it.

  `make` only rebuilds when `c_src/` changed.
  """
  use Mix.Task.Compiler

  @impl Mix.Task.Compiler
  def run(_args) do
    if host_nif?(), do: build(), else: {:noop, []}
  end

  @impl Mix.Task.Compiler
  def clean do
    File.rm_rf!(native_dir())
    :ok
  end

  defp host_nif? do
    case System.get_env("EGIT_HOST_NIF") do
      "1" -> true
      "0" -> false
      _ -> Path.basename(Mix.Project.build_path()) == "test"
    end
  end

  defp build do
    native = native_dir()

    env = [
      {"SO_OUTPUT", Path.join(native, "git.so")},
      {"OBJ_DIR", Path.join(native, "obj")},
      {"HAVE_FORMAT", "1"},
      {"HAVE_SRCLOC", "1"}
    ]

    case System.cmd("make", ["-s", "-C", "c_src"], env: env, stderr_to_stdout: true) do
      {_output, 0} ->
        {:ok, []}

      {output, status} ->
        Mix.shell().error(output)
        Mix.raise("egit: host NIF build failed (make exited with #{status})")
    end
  end

  defp native_dir, do: Path.join(Mix.Project.app_path(), "native")
end
