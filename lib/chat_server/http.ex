defmodule ChatServer.Http do
  @moduledoc "A small HTTPS client over Erlang's :httpc, with certificates verified."

  @timeout 10_000

  @doc """
  Sends a request. Failure reasons are dropped because they can quote the request,
  which may hold credentials.
  """
  def request(method, url, headers, body \\ nil) do
    charlist_headers =
      Enum.map(headers, fn {key, value} ->
        {String.to_charlist(key), String.to_charlist(value)}
      end)

    request =
      case body do
        nil ->
          {String.to_charlist(url), charlist_headers}

        {content_type, data} ->
          {String.to_charlist(url), charlist_headers, String.to_charlist(content_type), data}
      end

    http_options = [timeout: @timeout, connect_timeout: @timeout, ssl: ssl_options()]

    case :httpc.request(method, request, http_options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, response}} -> {:ok, status, response}
      {:error, _reason} -> {:error, :unreachable}
    end
  end

  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end
end
