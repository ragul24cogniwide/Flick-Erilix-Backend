defmodule ChatServerWeb.RouteRateLimitTest do
  # Not async: this temporarily lowers global limits.
  use ChatServerWeb.ConnCase, async: false

  import ChatServer.Fixtures

  setup %{conn: conn} do
    limits = Application.fetch_env!(:chat_server, :rate_limits)
    on_exit(fn -> Application.put_env(:chat_server, :rate_limits, limits) end)

    lowered = Keyword.merge(limits, contacts_match_user: {1, 60}, keys_fetch_user: {1, 60})
    Application.put_env(:chat_server, :rate_limits, lowered)

    session = session_fixture()
    %{conn: put_req_header(conn, "authorization", "Bearer #{session.access_token}")}
  end

  test "key fetches are limited per user, and uploads are not", %{conn: conn} do
    target = session_fixture()

    assert conn |> get("/api/v1/keys/#{target.user.id}") |> response(200)

    limited = get(conn, "/api/v1/keys/#{target.user.id}")
    assert %{"error" => "rate_limited"} = json_response(limited, 429)
    assert [_seconds] = get_resp_header(limited, "retry-after")

    prekeys = [%{key_id: 1, public_key: Base.encode64("k")}]

    for _ <- 1..2 do
      assert conn |> put("/api/v1/keys", %{one_time_prekeys: prekeys}) |> response(200)
    end
  end

  test "contact matching is limited per user", %{conn: conn} do
    assert conn |> post("/api/v1/contacts/match", %{hashes: []}) |> response(200)
    assert conn |> post("/api/v1/contacts/match", %{hashes: []}) |> response(429)
  end

  test "one user hitting the limit does not affect another", %{conn: conn} do
    assert conn |> post("/api/v1/contacts/match", %{hashes: []}) |> response(200)
    assert conn |> post("/api/v1/contacts/match", %{hashes: []}) |> response(429)

    other = session_fixture()

    assert build_conn()
           |> put_req_header("authorization", "Bearer #{other.access_token}")
           |> post("/api/v1/contacts/match", %{hashes: []})
           |> response(200)
  end
end
