defmodule ChatServerWeb.DeviceController do
  use ChatServerWeb, :controller

  alias ChatServer.Accounts

  action_fallback ChatServerWeb.FallbackController

  def push_token(conn, params) do
    with {:ok, _device} <- Accounts.update_push_token(conn.assigns.current_device, params) do
      send_resp(conn, :no_content, "")
    end
  end
end
