# The Egit tests need the host NIF (priv/git.so): `make -C c_src HAVE_FORMAT=1
# HAVE_SRCLOC=1`, against a system libgit2. Without it they are skipped.
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
