defmodule Egit.Test.GitHttpServer do
  @moduledoc """
  A git smart HTTP server for the tests: `git http-backend` run as a CGI
  for each request, behind a minimal HTTP/1.1 listener on 127.0.0.1. Each
  request's headers are sent to the process that started it, as
  `{:git_http, method, path, headers}` (header names lowercase), before
  the request is served.

  Serves the repositories under `root` as `/<name>`. One request per
  connection (`Connection: close`). The request body, read whole (by
  `Content-Length` or chunked), is written to a file that is the CGI's
  stdin: an Erlang port cannot close its stdin while reading its stdout.
  """

  @doc "Starts serving `root`; returns the port."
  def start(root) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    owner = self()
    spawn_link(fn -> accept(listen, root, owner) end)
    port
  end

  defp accept(listen, root, owner) do
    {:ok, socket} = :gen_tcp.accept(listen)
    pid = spawn(fn -> serve(socket, root, owner) end)
    :ok = :gen_tcp.controlling_process(socket, pid)
    send(pid, :go)
    accept(listen, root, owner)
  end

  defp serve(socket, root, owner) do
    receive do
      :go -> :ok
    end

    :ok = :inet.setopts(socket, packet: :http_bin)
    {:ok, {:http_request, method, {:abs_path, target}, _version}} = :gen_tcp.recv(socket, 0)
    headers = read_headers(socket, %{})
    send(owner, {:git_http, method, target, headers})

    :ok = :inet.setopts(socket, packet: :raw)
    body = read_body(socket, headers)
    {status, response_headers, response} = cgi(root, method, target, headers, body)

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status}\r\n",
      Enum.map(response_headers, fn {k, v} -> [k, ": ", v, "\r\n"] end),
      "Content-Length: #{byte_size(response)}\r\nConnection: close\r\n\r\n",
      response
    ])

    :gen_tcp.close(socket)
  end

  defp read_headers(socket, acc) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, {:http_header, _, name, _, value}} ->
        read_headers(socket, Map.put(acc, String.downcase(to_string(name)), value))

      {:ok, :http_eoh} ->
        acc
    end
  end

  defp read_body(socket, %{"content-length" => length}) do
    case String.to_integer(length) do
      0 ->
        ""

      length ->
        {:ok, body} = :gen_tcp.recv(socket, length)
        body
    end
  end

  defp read_body(socket, %{"transfer-encoding" => "chunked"}), do: chunks(socket, "", [])
  defp read_body(_socket, _headers), do: ""

  # `<hex size>\r\n<data>\r\n`..., ending with a zero size.
  defp chunks(socket, buffer, acc) do
    case :binary.split(buffer, "\r\n") do
      [size_line, rest] ->
        {size, _ext} = size_line |> String.split(";") |> hd() |> Integer.parse(16)

        if size == 0 do
          IO.iodata_to_binary(Enum.reverse(acc))
        else
          rest = fill(socket, rest, size + 2)
          <<data::binary-size(^size), "\r\n", rest::binary>> = rest
          chunks(socket, rest, [data | acc])
        end

      [_incomplete] ->
        {:ok, more} = :gen_tcp.recv(socket, 0)
        chunks(socket, buffer <> more, acc)
    end
  end

  defp fill(_socket, buffer, size) when byte_size(buffer) >= size, do: buffer

  defp fill(socket, buffer, size) do
    {:ok, more} = :gen_tcp.recv(socket, 0)
    fill(socket, buffer <> more, size)
  end

  defp cgi(root, method, target, headers, body) do
    {path, query} =
      case String.split(target, "?", parts: 2) do
        [path, query] -> {path, query}
        [path] -> {path, ""}
      end

    stdin = Path.join(root, "request-#{System.unique_integer([:positive])}")
    File.write!(stdin, body)

    env =
      [
        {"GIT_PROJECT_ROOT", root},
        {"GIT_HTTP_EXPORT_ALL", "1"},
        {"REQUEST_METHOD", to_string(method)},
        {"PATH_INFO", path},
        {"QUERY_STRING", query},
        {"CONTENT_TYPE", headers["content-type"] || ""},
        {"CONTENT_LENGTH", Integer.to_string(byte_size(body))},
        {"GIT_PROTOCOL", headers["git-protocol"] || ""},
        {"REMOTE_ADDR", "127.0.0.1"}
      ]

    {output, 0} = System.cmd("sh", ["-c", ~s(exec git http-backend < "$0"), stdin], env: env)
    File.rm!(stdin)

    [head, response] = :binary.split(output, ["\r\n\r\n", "\n\n"])

    headers =
      for line <- String.split(head, ["\r\n", "\n"], trim: true),
          [k, v] = String.split(line, ": ", parts: 2),
          do: {k, v}

    {status, headers} =
      case List.keytake(headers, "Status", 0) do
        {{"Status", status}, headers} -> {status, headers}
        nil -> {"200 OK", headers}
      end

    {status, headers, response}
  end
end
