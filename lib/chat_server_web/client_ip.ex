defmodule ChatServerWeb.ClientIp do
  @moduledoc """
  Works out the caller's IP for rate limiting.

  Behind a TLS proxy every connection comes from the proxy, so with `TRUST_PROXY=true`
  the address comes from `x-forwarded-for`. Its rightmost entry is the one our proxy
  added. Entries further left are supplied by the client and can be forged.
  """

  def from_conn(%Plug.Conn{} = conn) do
    resolve(conn.remote_ip, Plug.Conn.get_req_header(conn, "x-forwarded-for"))
  end

  def from_connect_info(connect_info) do
    address = get_in(connect_info, [:peer_data, :address]) || {0, 0, 0, 0}

    forwarded =
      for {"x-forwarded-for", value} <- Map.get(connect_info, :x_headers, []), do: value

    resolve(address, forwarded)
  end

  defp resolve(peer_address, forwarded) do
    if Application.get_env(:chat_server, :trust_proxy, false) and forwarded != [] do
      forwarded |> List.last() |> String.split(",") |> List.last() |> String.trim()
    else
      peer_address |> :inet.ntoa() |> to_string()
    end
  end
end
