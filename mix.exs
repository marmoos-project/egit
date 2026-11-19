defmodule Egit.MixProject do
  use Mix.Project

  # Mix build of egit for use as a Mob plugin (see PLAN.md). rebar.config and
  # the Makefiles stay the upstream host build. The device NIF is
  # cross-compiled by mob_dev from priv/mob_plugin.exs.
  #
  # A host NIF is built from c_src/Makefile, against the system libgit2, by
  # `mix compile.egit_nif` (lib/mix/tasks/compile.egit_nif.ex): in the test
  # build only, see there.
  def project do
    [
      app: :egit,
      version: "0.3.0",
      elixir: "~> 1.18",
      language: :erlang,
      compilers: Mix.compilers() ++ [:egit_nif],
      # Test helpers, loaded by test/test_helper.exs: not tests.
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")],
      deps: deps()
    ]
  end

  defp deps do
    [
      # mix mob.validate_plugin / mob.plugin.keygen / mob.plugin.sign.
      # Dev-only: never part of a host app's dependency tree.
      {:mob_dev, "~> 0.7.16", only: :dev, runtime: false}
    ]
  end

  # Mirrors src/egit.app.src, which Mix does not read.
  def application do
    [
      description: ~c"Native git Erlang interface library",
      mod: {Egit.Application, []},
      extra_applications: [:logger]
    ]
  end
end
