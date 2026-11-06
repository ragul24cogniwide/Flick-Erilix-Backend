defmodule ChatServerWeb.Plugs.RateLimit do
  @moduledoc "Limits an authenticated route per user. The argument is the rate limit scope."

  import Plug.Conn

  alias ChatServer.RateLimiter

  def init(scope), do: scope

  def call(conn, scope) do
    case RateLimiter.check(scope, conn.assigns.current_user.id) do
      :ok -> conn
      {:error, retry_after} -> deny(conn, retry_after)
    end
  end

  def deny(conn, retry_after) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_status(:too_many_requests)
    |> Phoenix.Controller.json(%{error: "rate_limited"})
    |> halt()
  end
end
