defmodule ChatServerWeb.AuthControllerTest do
  use ChatServerWeb.ConnCase, async: true

  import ChatServer.Fixtures
  import Ecto.Query

  alias ChatServer.Accounts.{OtpCode, RefreshToken, User}
  alias ChatServer.Repo

  @device %{"platform" => "ios"}

  defp request_code(conn, phone) do
    conn = post(conn, "/api/v1/auth/request_otp", %{phone: phone})
    assert json_response(conn, 202)
    assert_received {:otp_sent, ^phone, code}
    code
  end

  defp verify(conn, phone, code, device \\ @device) do
    post(conn, "/api/v1/auth/verify_otp", %{phone: phone, code: code, device: device})
  end

  defp wrong_code(code), do: if(code == "000000", do: "000001", else: "000000")

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  describe "the full login flow" do
    test "request, verify, use the access token, refresh, logout", %{conn: conn} do
      phone = unique_phone()
      code = request_code(conn, phone)
      assert code =~ ~r/^\d{6}$/

      body = conn |> verify(phone, code) |> json_response(200)
      assert %{"phone" => ^phone, "id" => user_id} = body["user"]
      assert body["expires_in"] == 900
      assert body["device"]["platform"] == "ios"

      assert %{"id" => ^user_id} =
               conn |> bearer(body["access_token"]) |> get("/api/v1/me") |> json_response(200)

      refreshed =
        conn
        |> post("/api/v1/auth/refresh", %{refresh_token: body["refresh_token"]})
        |> json_response(200)

      assert refreshed["refresh_token"] != body["refresh_token"]

      assert conn
             |> bearer(refreshed["access_token"])
             |> post("/api/v1/auth/logout")
             |> response(204)

      assert conn |> bearer(refreshed["access_token"]) |> get("/api/v1/me") |> response(401)

      assert conn
             |> post("/api/v1/auth/refresh", %{refresh_token: refreshed["refresh_token"]})
             |> response(401)
    end

    test "a second sign-in keeps the same user and adds a device", %{conn: conn} do
      phone = unique_phone()
      first = conn |> verify(phone, request_code(conn, phone)) |> json_response(200)
      second = conn |> verify(phone, request_code(conn, phone)) |> json_response(200)

      assert first["user"]["id"] == second["user"]["id"]
      assert first["device"]["id"] != second["device"]["id"]
      assert Repo.aggregate(from(u in User, where: u.phone == ^phone), :count) == 1
    end

    test "stores only hashes of codes and refresh tokens", %{conn: conn} do
      phone = unique_phone()
      code = request_code(conn, phone)
      body = conn |> verify(phone, code) |> json_response(200)

      otp = Repo.one!(from o in OtpCode, where: o.phone == ^phone)
      assert byte_size(otp.code_hash) == 32
      refute otp.code_hash == code

      token = Repo.one!(from r in RefreshToken, where: r.device_id == ^body["device"]["id"])
      refute token.token_hash == body["refresh_token"]
    end
  end

  describe "request_otp" do
    test "rejects a phone not in E.164 format", %{conn: conn} do
      for phone <- ["5551234567", "+0123456789", "+1 555 123 4567", nil, %{"a" => "b"}] do
        assert %{"error" => "invalid_phone"} =
                 conn
                 |> post("/api/v1/auth/request_otp", %{phone: phone})
                 |> json_response(422)
      end
    end

    test "replaces the previous code", %{conn: conn} do
      phone = unique_phone()
      first = request_code(conn, phone)
      second = request_code(conn, phone)

      if first != second do
        assert conn |> verify(phone, first) |> response(401)
      end

      assert conn |> verify(phone, second) |> response(200)
    end
  end

  describe "verify_otp rejects" do
    test "a wrong code", %{conn: conn} do
      phone = unique_phone()
      code = request_code(conn, phone)

      assert %{"error" => "invalid_code"} =
               conn |> verify(phone, wrong_code(code)) |> json_response(401)

      assert Repo.one!(from o in OtpCode, where: o.phone == ^phone).attempts == 1
    end

    test "a non-string code", %{conn: conn} do
      phone = unique_phone()
      request_code(conn, phone)
      assert conn |> verify(phone, %{"a" => "b"}) |> response(401)
    end

    test "a phone with no pending code", %{conn: conn} do
      assert conn |> verify(unique_phone(), "123456") |> response(401)
    end

    test "an expired code, even when correct", %{conn: conn} do
      phone = unique_phone()
      code = request_code(conn, phone)

      past = DateTime.add(DateTime.utc_now(), -1)
      Repo.update_all(from(o in OtpCode, where: o.phone == ^phone), set: [expires_at: past])

      assert %{"error" => "code_expired"} = conn |> verify(phone, code) |> json_response(401)
    end

    test "codes expire five minutes after issue", %{conn: conn} do
      phone = unique_phone()
      request_code(conn, phone)

      otp = Repo.one!(from o in OtpCode, where: o.phone == ^phone)
      assert DateTime.diff(otp.expires_at, otp.inserted_at) in 299..300
    end

    test "a correct code after five wrong attempts", %{conn: conn} do
      phone = unique_phone()
      code = request_code(conn, phone)

      for _attempt <- 1..5 do
        assert conn |> verify(phone, wrong_code(code)) |> response(401)
      end

      assert %{"error" => "too_many_attempts"} =
               conn |> verify(phone, code) |> json_response(429)
    end

    test "reusing a consumed code", %{conn: conn} do
      phone = unique_phone()
      code = request_code(conn, phone)

      assert conn |> verify(phone, code) |> response(200)
      assert conn |> verify(phone, code) |> response(401)
    end

    test "bad device info, without using up the code", %{conn: conn} do
      phone = unique_phone()
      code = request_code(conn, phone)

      assert %{"details" => %{"platform" => _}} =
               conn |> verify(phone, code, %{"platform" => "toaster"}) |> json_response(422)

      assert conn |> verify(phone, code) |> response(200)
    end
  end

  describe "refresh" do
    test "replaying a rotated token revokes the whole session", %{conn: conn} do
      session = session_fixture()

      rotated =
        conn
        |> post("/api/v1/auth/refresh", %{refresh_token: session.refresh_token})
        |> json_response(200)

      assert conn
             |> post("/api/v1/auth/refresh", %{refresh_token: session.refresh_token})
             |> response(401)

      assert conn
             |> post("/api/v1/auth/refresh", %{refresh_token: rotated["refresh_token"]})
             |> response(401)

      assert conn |> bearer(rotated["access_token"]) |> get("/api/v1/me") |> response(401)
    end

    test "rejects an expired token", %{conn: conn} do
      session = session_fixture()
      past = DateTime.add(DateTime.utc_now(), -1)

      Repo.update_all(from(r in RefreshToken, where: r.device_id == ^session.device.id),
        set: [expires_at: past]
      )

      assert conn
             |> post("/api/v1/auth/refresh", %{refresh_token: session.refresh_token})
             |> response(401)
    end

    test "tokens expire after 30 days" do
      session = session_fixture()
      token = Repo.one!(from r in RefreshToken, where: r.device_id == ^session.device.id)

      assert DateTime.diff(token.expires_at, token.inserted_at, :day) in 29..30
    end

    test "rejects an unknown or malformed token", %{conn: conn} do
      for token <- ["nope", nil, %{"a" => "b"}] do
        assert conn |> post("/api/v1/auth/refresh", %{refresh_token: token}) |> response(401)
      end
    end
  end

  describe "access tokens" do
    test "are rejected after 15 minutes", %{conn: conn} do
      %{user: user, device: device} = session_fixture()

      token =
        Phoenix.Token.sign(
          ChatServerWeb.Endpoint,
          "access token",
          %{user_id: user.id, device_id: device.id},
          signed_at: System.system_time(:second) - 901
        )

      assert conn |> bearer(token) |> get("/api/v1/me") |> response(401)
    end

    test "are required, and must be genuine", %{conn: conn} do
      assert conn |> get("/api/v1/me") |> response(401)
      assert conn |> bearer("forged") |> get("/api/v1/me") |> response(401)
    end

    test "logging out one device leaves the others signed in", %{conn: conn} do
      first = session_fixture()
      second = session_fixture(phone: first.user.phone)

      assert conn |> bearer(first.access_token) |> post("/api/v1/auth/logout") |> response(204)
      assert conn |> bearer(first.access_token) |> get("/api/v1/me") |> response(401)
      assert conn |> bearer(second.access_token) |> get("/api/v1/me") |> response(200)
    end
  end
end
