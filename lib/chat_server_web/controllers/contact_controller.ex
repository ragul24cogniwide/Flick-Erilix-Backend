defmodule ChatServerWeb.ContactController do
  use ChatServerWeb, :controller

  alias ChatServer.Accounts

  action_fallback ChatServerWeb.FallbackController

  plug ChatServerWeb.Plugs.RateLimit, :contacts_match_user

  def match(conn, params) do
    with {:ok, users} <- Accounts.match_contacts(params["hashes"]) do
      json(conn, %{
        matches:
          Enum.map(users, fn user ->
            %{hash: user.phone_hash, user_id: user.id, display_name: user.display_name}
          end)
      })
    end
  end
end
