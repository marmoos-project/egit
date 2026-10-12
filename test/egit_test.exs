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
