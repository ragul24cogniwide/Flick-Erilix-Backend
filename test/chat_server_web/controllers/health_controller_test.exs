defmodule ChatServerWeb.HealthControllerTest do
  use ChatServerWeb.ConnCase, async: true

  test "GET /health returns 200", %{conn: conn} do
    assert %{"status" => "ok"} = conn |> get("/health") |> json_response(200)
  end
end
