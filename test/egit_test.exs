defmodule EgitTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  defp commit_file(repo, name, content) do
    File.write!(Path.join(Egit.workdir(repo), name), content)
    {:ok, _} = Egit.add(repo, name)
    {:ok, {:ok, sha}} = Egit.commit(repo, "add #{name}")
    sha
  end

  defp configure(repo) do
    {:ok, :ok} = Egit.run(repo, :config_set, ["user.name", "egit test"])
    {:ok, :ok} = Egit.run(repo, :config_set, ["user.email", "egit@example.invalid"])
  end

  describe "local operations" do
    @describetag :nif

    test "init, add, commit, status, log", %{tmp_dir: dir} do
      {:ok, repo} = Egit.init(Path.join(dir, "work"))
      configure(repo)

      sha = commit_file(repo, "README.md", "hello\n")

      assert {:ok, status} = Egit.status(repo)
      assert status == %{}
      assert {:ok, [^sha]} = Egit.run(repo, :rev_list, [["HEAD"], []])
      assert :ok = Egit.close(repo)
      refute Process.alive?(repo)
    end

    test "open of a missing repository is an error, not a crash", %{tmp_dir: dir} do
      assert {:error, {:git, message}} = Egit.open(Path.join(dir, "nope"))
      assert message =~ "Failed to open git repo"
    end

    test "close is idempotent", %{tmp_dir: dir} do
      {:ok, repo} = Egit.init(Path.join(dir, "work"))
      assert :ok = Egit.close(repo)
      assert :ok = Egit.close(repo)
    end
  end

  describe "gitlinks" do
    @describetag :nif

    # A submodule recorded without being checked out: the target is a sibling
    # repository, and the gitlink's path is an empty directory.
    setup %{tmp_dir: dir} do
      {:ok, target} = Egit.init(Path.join(dir, "ship"))
      configure(target)
      sha = commit_file(target, "meta.md", "ship\n")

      {:ok, repo} = Egit.init(Path.join(dir, "voyage"))
      configure(repo)
      commit_file(repo, ".gitmodules", ~s([submodule "ship"]\n\tpath = ship\n\turl = ../ship\n))
      File.mkdir_p!(Path.join(dir, "voyage/ship"))

      %{repo: repo, target: target, sha: sha}
    end

    defp tree(repo) do
      {:ok, %{type: :tree, commits: entries}} = Egit.run(repo, :cat_file, ["HEAD:"])
      entries
    end

    test "a gitlink to a commit of another repository round-trips", %{repo: repo, sha: sha} do
      assert {:ok, :ok} = Egit.run(repo, :index_add_gitlink, ["ship", sha])
      assert {:ok, {:ok, _}} = Egit.commit(repo, "link ship")

      assert {"ship", "commit", ^sha, 0o160000} = List.keyfind(tree(repo), "ship", 0)
      assert {:ok, %{}} == Egit.status(repo)
    end

    test "a gitlink is replaced, and removed with remove/2", %{
      repo: repo,
      target: target,
      sha: sha
    } do
      {:ok, :ok} = Egit.run(repo, :index_add_gitlink, ["ship", sha])
      {:ok, {:ok, _}} = Egit.commit(repo, "link ship")

      sha2 = commit_file(target, "meta.md", "ship 2\n")
      assert {:ok, :ok} = Egit.run(repo, :index_add_gitlink, ["ship", sha2])
      {:ok, {:ok, _}} = Egit.commit(repo, "move ship")
      assert {"ship", "commit", ^sha2, 0o160000} = List.keyfind(tree(repo), "ship", 0)

      assert {:ok, :ok} = Egit.run(repo, :remove, ["ship"])
      {:ok, {:ok, _}} = Egit.commit(repo, "unlink ship")
      refute List.keyfind(tree(repo), "ship", 0)
    end

    test "without its empty directory, a gitlink shows as deleted", %{
      tmp_dir: dir,
      repo: repo,
      sha: sha
    } do
      {:ok, :ok} = Egit.run(repo, :index_add_gitlink, ["ship", sha])
      {:ok, {:ok, _}} = Egit.commit(repo, "link ship")

      File.rmdir!(Path.join(dir, "voyage/ship"))
      assert {:ok, %{worktree: [deleted: "ship"]}} = Egit.status(repo)
    end

    test "an invalid commit id is an error", %{repo: repo, sha: sha} do
      assert {:ok, {:error, "Invalid commit id abc"}} =
               Egit.run(repo, :index_add_gitlink, ["ship", "abc"])

      assert {:ok, {:error, message}} =
               Egit.run(repo, :index_add_gitlink, ["ship", String.duplicate("z", 40)])

      assert message =~ "Invalid commit id"
      assert {:ok, {:error, _}} = Egit.run(repo, :index_add_gitlink, ["ship", sha <> "0"])
    end
  end

  describe "network operations" do
    @describetag :nif

    setup %{tmp_dir: dir} do
      {:ok, origin} = Egit.init(Path.join(dir, "origin"))
      configure(origin)
      sha = commit_file(origin, "a.txt", "a\n")
      %{origin: origin, url: "file://" <> Path.join(dir, "origin"), sha: sha}
    end

    test "clone reports through the caller's mailbox", %{tmp_dir: dir, url: url, sha: sha} do
      {:ok, repo} = Egit.clone(url, Path.join(dir, "clone"))

      assert_receive {:egit, ^repo, {:clone, :ok}}, 10_000
      assert {:ok, [^sha]} = Egit.run(repo, :rev_list, [["HEAD"], []])
    end

    test "fetch after a new upstream commit", %{tmp_dir: dir, url: url, origin: origin} do
      {:ok, repo} = Egit.clone(url, Path.join(dir, "clone"))
      assert_receive {:egit, ^repo, {:clone, :ok}}, 10_000

      new_sha = commit_file(origin, "b.txt", "b\n")
      :ok = Egit.fetch(repo)

      assert_receive {:egit, ^repo, {:fetch, :ok}}, 10_000
      assert {:ok, {:ok, ^new_sha}} = Egit.run(repo, :rev_parse, ["origin/master"])
    end

    test "a failed clone reports and stops the repository", %{tmp_dir: dir} do
      {:ok, repo} = Egit.clone("file://" <> Path.join(dir, "missing"), Path.join(dir, "clone"))
      ref = Process.monitor(repo)

      assert_receive {:egit, ^repo, {:clone, {:error, {:git, _}}}}, 10_000
      assert_receive {:DOWN, ^ref, :process, ^repo, :normal}
    end
  end

  describe "over HTTP (git http-backend)" do
    @describetag :nif

    # A bare repository with a commit on main, served over HTTP, whose
    # update hook refuses any change to main.
    setup %{tmp_dir: dir} do
      root = Path.join(dir, "srv")
      origin = Path.join(root, "origin.git")
      seed = Path.join(dir, "seed")

      git!(["init", "--quiet", "--bare", "--initial-branch=main", origin])
      git!(["-C", origin, "config", "http.receivepack", "true"])
      git!(["init", "--quiet", "--initial-branch=main", seed])
      File.write!(Path.join(seed, "a.txt"), "a\n")
      git!(["-C", seed, "add", "a.txt"])
      git!(["-C", seed, "commit", "--quiet", "-m", "a"])
      git!(["-C", seed, "push", "--quiet", origin, "main"])

      hook = Path.join([origin, "hooks", "update"])

      File.write!(hook, """
      #!/bin/sh
      if [ "$1" = refs/heads/main ]; then
        echo "main is read-only" >&2
        exit 1
      fi
      """)

      File.chmod!(hook, 0o755)

      port = Egit.Test.GitHttpServer.start(root)
      %{url: "http://127.0.0.1:#{port}/origin.git", origin: origin}
    end

    @headers ["Authorization: Bearer t0ken", "X-Marmoos-Device: test"]

    defp git!(args) do
      env = [
        {"GIT_CONFIG_GLOBAL", "/dev/null"},
        {"GIT_AUTHOR_NAME", "egit test"},
        {"GIT_AUTHOR_EMAIL", "egit@example.invalid"},
        {"GIT_COMMITTER_NAME", "egit test"},
        {"GIT_COMMITTER_EMAIL", "egit@example.invalid"}
      ]

      {out, 0} = System.cmd("git", args, env: env, stderr_to_stdout: true)
      out
    end

    # The headers of every request received so far.
    defp requests(acc \\ []) do
      receive do
        {:git_http, _method, _path, headers} -> requests([headers | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp clone!(dir, url, opts) do
      {:ok, repo} = Egit.clone(url, Path.join(dir, "clone"), opts)
      assert_receive {:egit, ^repo, {:clone, :ok}}, 10_000
      configure(repo)
      repo
    end

    test "clone, fetch and push send the headers", %{tmp_dir: dir, url: url} do
      opts = %{headers: @headers}
      repo = clone!(dir, url, opts)
      assert [_ | _] = clone_requests = requests()

      :ok = Egit.fetch(repo, "origin", opts)
      assert_receive {:egit, ^repo, {:fetch, :ok}}, 10_000
      assert [_ | _] = fetch_requests = requests()

      commit_file(repo, "b.txt", "b\n")
      :ok = Egit.push(repo, "origin", ["refs/heads/main:refs/heads/topic"], opts)
      assert_receive {:egit, ^repo, {:push, :ok}}, 10_000
      assert [_ | _] = push_requests = requests()

      for headers <- clone_requests ++ fetch_requests ++ push_requests do
        assert headers["authorization"] == "Bearer t0ken"
        assert headers["x-marmoos-device"] == "test"
      end
    end

    test "without headers, none is sent", %{tmp_dir: dir, url: url} do
      clone!(dir, url, %{})
      assert Enum.all?(requests(), &(not Map.has_key?(&1, "authorization")))
    end

    test "a push the server refuses per ref: each ref, its reason, the remote lines",
         %{tmp_dir: dir, url: url, origin: origin} do
      repo = clone!(dir, url, %{})
      sha = commit_file(repo, "b.txt", "b\n")

      :ok =
        Egit.push(repo, "origin", [
          "refs/heads/main:refs/heads/main",
          "refs/heads/main:refs/heads/topic"
        ])

      assert_receive {:egit, ^repo, {:push, {:error, {:rejected, refs, messages}}}}, 10_000
      assert refs == [{"refs/heads/main", "hook declined"}]
      assert "main is read-only" in messages

      # The other ref went through: the refusal is per ref.
      assert git!(["-C", origin, "rev-parse", "refs/heads/topic"]) == sha <> "\n"
    end

    test "headers must be a list of non-empty binaries", %{tmp_dir: dir, url: url} do
      for headers <- ["Authorization: Bearer t", [~c"X: y"], [""], [:x]] do
        assert_raise ArgumentError, fn ->
          :git.clone(url, Path.join(dir, "bad"), %{headers: headers})
        end
      end
    end

    test "libgit2 refuses a header it sets itself", %{tmp_dir: dir, url: url} do
      {:ok, repo} = Egit.clone(url, Path.join(dir, "clone"), %{headers: ["Host: elsewhere"]})
      assert_receive {:egit, ^repo, {:clone, {:error, {:git, message}}}}, 10_000
      assert message =~ "Host"
    end
  end

  describe "classify/1" do
    test "unreachable hosts are network errors" do
      assert {:network, _} =
               Egit.classify(
                 "Failed to clone git repo https://github.com/x.git: failed to resolve " <>
                   "address for github.com: No address associated with hostname [git.cpp:204]"
               )

      assert {:network, _} = Egit.classify("failed to connect to example.com: Connection refused")
    end

    test "refused certificates" do
      assert {:certificate, _} =
               Egit.classify(
                 "the SSL certificate is invalid: 0x01 - The certificate validity has expired"
               )
    end

    test "anything else is a git error" do
      assert {:git, "reference 'refs/heads/x' not found"} =
               Egit.classify("reference 'refs/heads/x' not found")
    end
  end
end
