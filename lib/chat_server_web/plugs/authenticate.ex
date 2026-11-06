defmodule ChatServerWeb.Plugs.Authenticate do
  @moduledoc "Requires `Authorization: Bearer <access_token>`."

  import Plug.Conn

  alias ChatServer.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, user, device} <- Accounts.authenticate(token) do
      conn |> assign(:current_user, user) |> assign(:current_device, device)
    else
      _unauthorized ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "unauthorized"})
        |> halt()
    end
  end
end
