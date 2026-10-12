defmodule Egit do
  @moduledoc """
  Git repositories for Mob apps, on top of egit's `:git` NIF (libgit2).

  Each repository is a process (`Egit.Repo`) that owns the libgit2 handle and
  runs every operation on it, so a screen never holds the handle itself and
  never blocks on the network.

  ## Local operations

  Synchronous; they return `{:ok, result}` or `{:error, reason}`:

      {:ok, repo} = Egit.init(Egit.path("logbook"))
      {:ok, _} = Egit.add(repo, "entries.json")
      {:ok, {:ok, sha}} = Egit.commit(repo, "New entry")
      {:ok, status} = Egit.status(repo)

  Any other `:git` function taking the repository first goes through `run/4`:
  `Egit.run(repo, :list_branches, [[]])`.

  ## Network operations

  `clone/3`, `fetch/3`, `pull/3` and `push/4` return at once; the result
  arrives in the caller's mailbox, e.g. in a screen:

      def handle_info({:egit, repo, {:clone, :ok}}, socket), do: ...
      def handle_info({:egit, _repo, {:fetch, {:error, reason}}}, socket), do: ...

  The result is `:ok`, `{:error, reason}`, or `:deferred`: the host was
  unreachable while the app was in the background (Android cuts background
  apps off the network), and the operation will run again, with a second
  message, when the app becomes active.

  Credentials go in `opts` as egit takes them (`CREDENTIALS.md`), e.g.
  `%{credentials: %{type: :token, token: token}}`; keep the token in the
  app's secure storage, not in code or config.

  ## Where repositories live

  `path/1` puts them under the app's documents directory. Never put one
  under `MOB_BEAMS_DIR`: a deploy replaces it.
  """

  @type repo :: pid()
  @type network_op :: :clone | :fetch | :pull | :push

  @typedoc """
  Why an operation failed:

    * `:nif_not_loaded` - no native library (a host without a NIF build);
    * `:not_ready` - the repository is still being cloned;
    * `{:network, message}` - host unreachable with the app in the foreground;
    * `{:certificate, message}` - TLS certificate refused;
    * `{:git, message}` - any other libgit2 / egit error.
  """
  @type reason ::
          :nif_not_loaded
          | :not_ready
          | {:network, String.t()}
          | {:certificate, String.t()}
          | {:git, term()}

  @call_timeout 15_000

  # ── Repositories ────────────────────────────────────────────────────────────

  @doc "Opens an existing repository."
  @spec open(Path.t()) :: {:ok, repo()} | {:error, reason()}
  def open(path) do
    start({:open, path})
  end

  @doc "Creates a repository (`opts`: `[:bare]` for a bare one)."
  @spec init(Path.t(), [:bare]) :: {:ok, repo()} | {:error, reason()}
  def init(path, opts \\ []) do
    start({:init, path, opts})
  end

  @doc """
  Clones `url` into `path`. Returns the repository at once; the caller
  receives `{:egit, repo, {:clone, result}}`. After a failed clone the
  repository process stops.
  """
  @spec clone(String.t(), Path.t(), map()) :: {:ok, repo()} | {:error, reason()}
  def clone(url, path, opts \\ %{}) do
    start({:clone, url, path, opts, self()})
  end

  @doc "Stops the repository process, freeing the libgit2 handle."
  @spec close(repo()) :: :ok
  def close(repo) do
    case DynamicSupervisor.terminate_child(Egit.RepoSupervisor, repo) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  @doc "The repository's working directory."
  @spec workdir(repo()) :: Path.t()
  def workdir(repo) do
    GenServer.call(repo, :path)
  end

  @doc """
  Where to keep a repository named `name`: `<documents>/git/<name>`, the
  documents directory being `Mob.Storage.dir(:documents)`.
  """
  @spec path(String.t()) :: Path.t()
  def path(name) do
    documents =
      try do
        apply(Mob.Storage, :dir, [:documents])
      rescue
        UndefinedFunctionError ->
          raise ArgumentError, "Egit.path/1 needs Mob.Storage; give a full path instead"
      end

    Path.join([documents, "git", name])
  end

  # ── Network operations ──────────────────────────────────────────────────────

  @doc "Fetches from `remote`. Result: `{:egit, repo, {:fetch, result}}`."
  @spec fetch(repo(), String.t(), map()) :: :ok
  def fetch(repo, remote \\ "origin", opts \\ %{}) do
    cast(repo, :fetch, [remote, opts])
  end

  @doc "Fetches and merges from `remote`. Result: `{:egit, repo, {:pull, result}}`."
  @spec pull(repo(), String.t(), map()) :: :ok
  def pull(repo, remote \\ "origin", opts \\ %{}) do
    cast(repo, :pull, [remote, opts])
  end

  @doc """
  Pushes `refs` (the remote's configured push refspecs when empty) to
  `remote`. Result: `{:egit, repo, {:push, result}}`.
  """
  @spec push(repo(), String.t(), [String.t()], map()) :: :ok
  def push(repo, remote \\ "origin", refs \\ [], opts \\ %{}) do
    cast(repo, :push, [remote, refs, opts])
  end

  # ── Local operations ────────────────────────────────────────────────────────

  @doc "`:git.status/1`."
  @spec status(repo()) :: {:ok, map()} | {:error, reason()}
  def status(repo) do
    run(repo, :status)
  end

  @doc "`:git.add/2`: stages a path, a list of paths, or `\".\"`."
  @spec add(repo(), String.t() | [String.t()]) :: {:ok, map()} | {:error, reason()}
  def add(repo, paths) do
    run(repo, :add, [paths])
  end

  @doc "`:git.commit/2`: commits the index. The result is egit's `{:ok, sha | nil}`."
  @spec commit(repo(), String.t()) :: {:ok, term()} | {:error, reason()}
  def commit(repo, message) do
    run(repo, :commit, [message])
  end

  @doc """
  Runs `:git.<fun>(handle, args...)` in the repository's process.

  Waits up to `timeout` ms: a call queues behind a network operation already
  running on the same repository.
  """
  @spec run(repo(), atom(), list(), timeout()) :: {:ok, term()} | {:error, reason()}
  def run(repo, fun, args \\ [], timeout \\ @call_timeout) when is_atom(fun) and is_list(args) do
    GenServer.call(repo, {:run, fun, args}, timeout)
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp start(args) do
    {:ok, _} = Application.ensure_all_started(:egit)

    case DynamicSupervisor.start_child(Egit.RepoSupervisor, {Egit.Repo, args}) do
      {:ok, repo} -> {:ok, repo}
      {:error, {:shutdown, reason}} -> {:error, reason}
      {:error, {:already_started, repo}} -> {:ok, repo}
      {:error, reason} -> {:error, {:git, reason}}
    end
  end

  defp cast(repo, op, args), do: GenServer.cast(repo, {op, args, self()})

  @doc false
  # Runs an egit call, turning what it raises into {:error, reason}.
  @spec attempt((-> term())) :: {:ok, term()} | {:error, reason()}
  def attempt(fun) do
    {:ok, fun.()}
  rescue
    e in ErlangError ->
      case e.original do
        {:not_loaded, _} -> {:error, :nif_not_loaded}
        message when is_binary(message) -> {:error, classify(message)}
        other -> {:error, {:git, other}}
      end

    e ->
      {:error, {:git, Exception.message(e)}}
  end

  # libgit2's messages for a host it could not resolve or reach.
  @unreachable ["failed to resolve address", "failed to connect"]

  @doc false
  @spec classify(String.t()) :: reason()
  def classify(message) do
    cond do
      String.contains?(message, @unreachable) -> {:network, message}
      String.contains?(message, "SSL certificate") -> {:certificate, message}
      true -> {:git, message}
    end
  end

  @doc false
  # Whether the app is in the foreground; always true without Mob (host).
  @spec foreground?() :: boolean()
  def foreground? do
    apply(Mob.Device, :foreground?, [])
  rescue
    _ -> true
  end
end
