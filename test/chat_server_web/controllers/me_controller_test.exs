defmodule ChatServerWeb.MeControllerTest do
  use ChatServerWeb.ConnCase, async: true

  import ChatServer.Fixtures

  alias ChatServer.Accounts.Device
  alias ChatServer.Repo

  setup %{conn: conn} do
    session = session_fixture()
    conn = put_req_header(conn, "authorization", "Bearer #{session.access_token}")
    %{conn: conn, session: session}
  end

  test "reads and updates the profile", %{conn: conn, session: session} do
    assert %{"phone" => phone} = conn |> get("/api/v1/me") |> json_response(200)
    assert phone == session.user.phone

    body =
      conn
      |> patch("/api/v1/me", %{display_name: "Sam", about: "Hello", phone: "+15550000000"})
      |> json_response(200)

    assert %{"display_name" => "Sam", "about" => "Hello"} = body
    assert body["phone"] == phone, "the phone number cannot be changed through the profile"
  end

  test "rejects an overlong display name", %{conn: conn} do
    assert %{"details" => %{"display_name" => _}} =
             conn
             |> patch("/api/v1/me", %{display_name: String.duplicate("x", 65)})
             |> json_response(422)
  end

  test "registers a push token on the current device", %{conn: conn, session: session} do
    assert conn |> post("/api/v1/devices/push_token", %{push_token: "abc"}) |> response(204)
    assert Repo.get!(Device, session.device.id).push_token == "abc"

    assert conn |> post("/api/v1/devices/push_token", %{}) |> response(422)
  end
end
