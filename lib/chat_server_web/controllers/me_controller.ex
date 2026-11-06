defmodule ChatServerWeb.MeController do
  use ChatServerWeb, :controller

  alias ChatServer.Accounts
  alias ChatServerWeb.UserJSON

  action_fallback ChatServerWeb.FallbackController

  def show(conn, _params), do: json(conn, UserJSON.user(conn.assigns.current_user))

  def update(conn, params) do
    with {:ok, user} <- Accounts.update_profile(conn.assigns.current_user, params) do
      json(conn, UserJSON.user(user))
    end
  end
end
