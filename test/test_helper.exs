# The Egit tests need the host NIF, which `mix test` builds against the system
# libgit2 (see mix.exs). Without it they are skipped.
nif? =
  try do
    :git.open(System.tmp_dir!())
    true
  rescue
    ErlangError -> true
  catch
    :error, {:not_loaded, _} -> false
  end

ExUnit.start(exclude: if(nif?, do: [], else: [:nif]))
