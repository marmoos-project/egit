defmodule Egit.Repo do
  @moduledoc """
  The process that owns one repository. Use it through `Egit`.

  egit's repository handle is only safe in the process that opened it: the NIF
  frees it when that process exits, whoever else still holds the term. So this
  process opens (or clones) the repository and runs every operation on it,
  local and network alike. That also serialises them, as libgit2 requires for
  a single `git_repository`.

  Network operations (`clone`, `fetch`, `pull`, `push`) are casts; the result
  goes to the process that asked, as `{:egit, repo, {op, result}}`. A network
  operation that cannot resolve or reach its host while the app is not in the
  foreground (Android cuts background apps off the network) is put on hold:
  the caller gets `{:egit, repo, {op, :deferred}}`, and the operation runs
  again when the app becomes active.
  """
  use GenServer, restart: :temporary

  @network_ops [:clone, :fetch, :pull, :push]
  @retry_delay 1_000

  @typedoc "What `Egit` hands back to the process that asked."
  @type event :: {:egit, pid(), {Egit.network_op(), :ok | :deferred | {:error, Egit.reason()}}}

  @doc false
  def start_link(args) do
    path =
      case args do
        {:open, path} -> path
        {:init, path, _opts} -> path
        {:clone, _url, path, _opts, _reply_to} -> path
      end

    name = {:via, Registry, {Egit.Registry, path}}

    GenServer.start_link(__MODULE__, args, name: name)
  end

  # ── Server ──────────────────────────────────────────────────────────────────

  @impl GenServer
  def init({:open, path}) do
    init_local(path, fn -> :git.open(path) end)
  end

  def init({:init, path, opts}) do
    init_local(path, fn -> :git.init(path, opts) end)
  end

  def init({:clone, url, path, opts, reply_to}) do
    state = new_state(path)
    {:ok, state, {:continue, {:clone, [url, path, opts], reply_to}}}
  end

  defp init_local(path, open) do
    case Egit.attempt(open) do
      {:ok, handle} -> {:ok, %{new_state(path) | handle: handle}}
      # :shutdown keeps a refused open out of the error log.
      {:error, reason} -> {:stop, {:shutdown, reason}}
    end
  end

  defp new_state(path) do
    %{path: path, handle: nil, deferred: [], subscribed: false}
  end

  @impl GenServer
  def handle_continue({:clone, args, reply_to}, state) do
    {:noreply, network(:clone, args, reply_to, state)}
  end

  @impl GenServer
  def handle_call(:path, _from, state) do
    {:reply, state.path, state}
  end

  def handle_call({:run, _fun, _args}, _from, %{handle: nil} = state) do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call({:run, fun, args}, _from, state) do
    {:reply, Egit.attempt(fn -> apply(:git, fun, [state.handle | args]) end), state}
  end

  @impl GenServer
  def handle_cast({op, _args, reply_to}, %{handle: nil} = state) when op in @network_ops do
    send(reply_to, {:egit, self(), {op, {:error, :not_ready}}})
    {:noreply, state}
  end

  def handle_cast({op, args, reply_to}, state) when op in @network_ops,
    do: {:noreply, network(op, [state.handle | args], reply_to, state)}

  @impl GenServer
  # The network block is lifted around the time the app becomes active; give
  # it a moment before retrying.
  def handle_info({:mob_device, :did_become_active}, %{deferred: [_ | _]} = state) do
    Process.send_after(self(), :retry_deferred, @retry_delay)
    {:noreply, state}
  end

  def handle_info(:retry_deferred, state) do
    {retry, state} = {Enum.reverse(state.deferred), %{state | deferred: []}}

    state =
      Enum.reduce(retry, state, fn {op, args, reply_to}, acc ->
        network(op, args, reply_to, acc, true)
      end)

    {:noreply, maybe_unsubscribe(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ── Network operations ──────────────────────────────────────────────────────

  # `retried?` is true when the operation already waited for the foreground
  # once: a second failure is reported, not deferred again, unless the app went
  # back to the background meanwhile.
  defp network(op, args, reply_to, state, retried? \\ false) do
    case Egit.attempt(fn -> apply(:git, op, args) end) |> normalize(op) do
      {:ok, result} ->
        state = if op == :clone, do: %{state | handle: result}, else: state
        send(reply_to, {:egit, self(), {op, :ok}})
        state

      {:error, {:network, _}} = error ->
        if Egit.foreground?() do
          report_error(op, error, reply_to, state)
        else
          if not retried?, do: send(reply_to, {:egit, self(), {op, :deferred}})
          subscribe(%{state | deferred: [{op, args, reply_to} | state.deferred]})
        end

      {:error, _} = error ->
        report_error(op, error, reply_to, state)
    end
  end

  defp report_error(op, error, reply_to, state) do
    send(reply_to, {:egit, self(), {op, error}})
    # A failed clone leaves nothing to own.
    if op == :clone, do: exit(:normal)
    state
  end

  # egit's fetch / pull / push return `ok | {error, Msg}` rather than raising;
  # clone returns the handle.
  defp normalize({:ok, {:error, message}}, _op) when is_binary(message),
    do: {:error, Egit.classify(message)}

  defp normalize({:ok, :ok} = ok, _op), do: ok
  defp normalize({:ok, _handle} = ok, :clone), do: ok
  defp normalize({:ok, other}, _op), do: {:error, {:git, other}}
  defp normalize({:error, _} = error, _op), do: error

  # Mob.Device is reached through apply/3 so egit builds and runs without Mob.
  defp subscribe(%{subscribed: true} = state), do: state

  defp subscribe(state) do
    try do
      :ok = apply(Mob.Device, :subscribe, [:app])
      %{state | subscribed: true}
    catch
      # No Mob.Device (host): nothing will say the app is active again.
      _, _ -> state
    end
  end

  defp maybe_unsubscribe(%{deferred: [], subscribed: true} = state) do
    try do
      apply(Mob.Device, :unsubscribe, [])
    catch
      _, _ -> :ok
    end

    %{state | subscribed: false}
  end

  defp maybe_unsubscribe(state), do: state
end
