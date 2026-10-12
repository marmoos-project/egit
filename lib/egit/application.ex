defmodule Egit.Application do
  @moduledoc false
  # Started by Mob at boot like every activated plugin's application
  # (Mob.Plugins.start/1), or by Egit's first call on a host.
  use Application

  require Logger

  # Android 14+ keeps the system CA store in an updatable APEX module; the
  # path libgit2 is built with (/system/etc/security/cacerts, see
  # priv/mob_plugin.exs) can lag behind it.
  @apex_cacerts "/apex/com.android.conscrypt/cacerts"

  @impl Application
  def start(_type, _args) do
    use_apex_cacerts()

    children = [
      {Registry, keys: :unique, name: Egit.Registry},
      {DynamicSupervisor, name: Egit.RepoSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Egit.Supervisor)
  end

  defp use_apex_cacerts do
    if File.dir?(@apex_cacerts) do
      try do
        :ok = :git.set_ssl_cert_locations(nil, @apex_cacerts)
      catch
        # No NIF (host build): nothing to configure.
        :error, {:not_loaded, _} ->
          :ok

        kind, reason ->
          Logger.warning(
            "[egit] keeping the built-in CA store, #{@apex_cacerts} failed: " <>
              Exception.format_banner(kind, reason)
          )
      end
    end

    :ok
  end
end
