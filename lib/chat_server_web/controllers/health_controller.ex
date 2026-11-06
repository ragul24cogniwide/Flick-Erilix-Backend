defmodule ChatServerWeb.HealthController do
  use ChatServerWeb, :controller

  alias ChatServer.Repo

  def show(conn, _params) do
    case Repo.query("SELECT 1", [], timeout: 2_000) do
      {:ok, _result} ->
        json(conn, %{status: "ok"})

      {:error, _reason} ->
        conn |> put_status(:service_unavailable) |> json(%{status: "database_unavailable"})
    end
  end
end
