defmodule ChatServerWeb.AuthController do
  use ChatServerWeb, :controller

  alias ChatServer.{Accounts, RateLimiter}
  alias ChatServerWeb.{ClientIp, UserJSON}
  alias ChatServerWeb.Plugs.RateLimit

  action_fallback ChatServerWeb.FallbackController

  plug :rate_limit when action in [:request_otp, :verify_otp]

  def request_otp(conn, params) do
    with {:ok, delivery} <- Accounts.request_otp(params["phone"]) do
      conn |> put_status(:accepted) |> json(Map.put(delivery, :status, "code_sent"))
    end
  end

  def verify_otp(conn, params) do
    device_attrs = if is_map(params["device"]), do: params["device"], else: %{}

    with {:ok, session} <- Accounts.verify_otp(params["phone"], params["code"], device_attrs) do
      json(conn, session_json(session))
    end
  end

  def refresh(conn, params) do
    with {:ok, session} <- Accounts.refresh_session(params["refresh_token"]) do
      json(conn, session_json(session))
    end
  end

  def logout(conn, _params) do
    :ok = Accounts.logout(conn.assigns.current_device)
    send_resp(conn, :no_content, "")
  end

  defp session_json(session) do
    %{
      access_token: session.access_token,
      refresh_token: session.refresh_token,
      expires_in: Accounts.access_token_ttl_seconds(),
      user: UserJSON.user(session.user),
      device: %{id: session.device.id, platform: session.device.platform}
    }
  end

  defp rate_limit(conn, _opts) do
    {ip_scope, phone_scope} =
      case action_name(conn) do
        :request_otp -> {:request_otp_ip, :request_otp_phone}
        :verify_otp -> {:verify_otp_ip, :verify_otp_phone}
      end

    checks = [{ip_scope, ClientIp.from_conn(conn)}, {phone_scope, conn.params["phone"]}]

    case RateLimiter.check_all(checks) do
      :ok ->
        conn

      {:error, retry_after} ->
        RateLimit.deny(conn, retry_after)
    end
  end
end
