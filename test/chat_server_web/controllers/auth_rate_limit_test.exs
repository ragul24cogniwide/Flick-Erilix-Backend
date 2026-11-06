defmodule ChatServerWeb.AuthRateLimitTest do
  # Not async: this temporarily lowers global limits.
  use ChatServerWeb.ConnCase, async: false

  import ChatServer.Fixtures

  setup do
    limits = Application.fetch_env!(:chat_server, :rate_limits)
    on_exit(fn -> Application.put_env(:chat_server, :rate_limits, limits) end)
    %{limits: limits}
  end

  defp lower(limits, overrides) do
    Application.put_env(:chat_server, :rate_limits, Keyword.merge(limits, overrides))
  end

  test "request_otp is limited per phone", %{conn: conn, limits: limits} do
    lower(limits, request_otp_phone: {2, 3600})
    phone = unique_phone()

    for _ <- 1..2 do
      assert conn |> post("/api/v1/auth/request_otp", %{phone: phone}) |> response(202)
    end

    limited = post(conn, "/api/v1/auth/request_otp", %{phone: phone})
    assert %{"error" => "rate_limited"} = json_response(limited, 429)
    assert [_seconds] = get_resp_header(limited, "retry-after")

    assert conn |> post("/api/v1/auth/request_otp", %{phone: unique_phone()}) |> response(202)
  end

  test "request_otp is limited per IP", %{conn: conn, limits: limits} do
    lower(limits, request_otp_ip: {1, 3600})
    conn = %{conn | remote_ip: {203, 0, 113, 7}}

    assert conn |> post("/api/v1/auth/request_otp", %{phone: unique_phone()}) |> response(202)
    assert conn |> post("/api/v1/auth/request_otp", %{phone: unique_phone()}) |> response(429)
  end

  test "verify_otp is limited per phone", %{conn: conn, limits: limits} do
    lower(limits, verify_otp_phone: {1, 600})
    phone = unique_phone()
    params = %{phone: phone, code: "123456", device: %{platform: "web"}}

    assert conn |> post("/api/v1/auth/verify_otp", params) |> response(401)
    assert conn |> post("/api/v1/auth/verify_otp", params) |> response(429)
  end

  test "verify_otp is limited per IP", %{conn: conn, limits: limits} do
    lower(limits, verify_otp_ip: {1, 600})
    conn = %{conn | remote_ip: {203, 0, 113, 8}}
    params = fn -> %{phone: unique_phone(), code: "123456", device: %{platform: "web"}} end

    assert conn |> post("/api/v1/auth/verify_otp", params.()) |> response(401)
    assert conn |> post("/api/v1/auth/verify_otp", params.()) |> response(429)
  end

  describe "behind a trusted proxy" do
    setup do
      Application.put_env(:chat_server, :trust_proxy, true)
      on_exit(fn -> Application.delete_env(:chat_server, :trust_proxy) end)
    end

    test "limits by the address the proxy saw, ignoring forged entries", %{
      conn: conn,
      limits: limits
    } do
      lower(limits, request_otp_ip: {1, 3600})

      from = fn header ->
        put_req_header(conn, "x-forwarded-for", header)
        |> post("/api/v1/auth/request_otp", %{phone: unique_phone()})
      end

      assert from.("198.51.100.1") |> response(202)
      # Same client, forging a different leftmost entry.
      assert from.("10.9.8.7, 198.51.100.1") |> response(429)
      # A different client.
      assert from.("198.51.100.2") |> response(202)
    end
  end
end
