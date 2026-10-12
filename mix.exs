defmodule Egit.MixProject do
  use Mix.Project

  # Mix build of egit for use as a Mob plugin (see PLAN.md). rebar.config and
  # the Makefiles stay the upstream host build; this file only compiles
  # src/git.erl. The NIF itself is cross-compiled by mob_dev from
  # priv/mob_plugin.exs, so no native step runs here.
  def project do
    [
      app: :egit,
      version: "0.3.0",
      elixir: "~> 1.18",
      language: :erlang,
      deps: []
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
