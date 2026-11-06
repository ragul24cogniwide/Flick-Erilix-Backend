defmodule ChatServer.SmsProvider.Fast2SmsTest do
  # Not async: this changes global config.
  use ChatServerWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias ChatServer.SmsProvider.{Fast2Sms, TestDouble}

  # Stands in for Fast2SMS over real HTTP, replying as the real API was observed to.
  defmodule FakeFast2Sms do
    import Plug.Conn

    def init(test_pid), do: test_pid

    def call(%{request_path: "/dev/wallet"} = conn, _test_pid) do
      case get_req_header(conn, "authorization") do
        ["test-key"] -> reply(conn, 200, %{return: true, wallet: "50.0000", sms_count: 200})
        _other -> reply(conn, 401, %{return: false, status_code: 412, message: "Invalid"})
      end
    end

    def call(conn, test_pid) do
      {:ok, body, conn} = read_body(conn)
      payload = Jason.decode!(body)

      send(
        test_pid,
        {:sms_request, conn.request_path, get_req_header(conn, "authorization"), payload}
      )

      case payload["numbers"] do
        "9000000412" ->
          reply(conn, 401, %{return: false, status_code: 412, message: "Invalid"})

        "9000000999" ->
          reply(conn, 400, %{return: false, status_code: 999, message: "bad 9000000999"})

        "9000000500" ->
          conn |> put_resp_content_type("text/html") |> send_resp(500, "<html>oops</html>")

        _number ->
          reply(conn, 200, %{return: true, request_id: "abc", message: ["SMS sent successfully."]})
      end
    end

    defp reply(conn, status, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end

  setup do
    server =
      start_supervised!(
        {Bandit, plug: {FakeFast2Sms, self()}, port: 0, ip: :loopback, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    Application.put_env(:chat_server, :fast2sms_base_url, "http://127.0.0.1:#{port}")
    Application.put_env(:chat_server, :fast2sms_api_key, "test-key")

    on_exit(fn ->
      Application.delete_env(:chat_server, :fast2sms_base_url)
      Application.delete_env(:chat_server, :fast2sms_api_key)
    end)

    :ok
  end

  test "sends the code on the Quick route, with a 10-digit number and the key" do
    assert :ok = Fast2Sms.send_otp("+919876543210", "012345")

    assert_received {:sms_request, "/dev/bulkV2", ["test-key"], payload}

    assert payload["route"] == "q"
    assert payload["numbers"] == "9876543210"
    assert payload["message"] =~ "012345"
  end

  test "refuses numbers it cannot reach, without calling Fast2SMS" do
    for phone <- ["+14155552671", "+915876543210", "+9198765432", "+9198765432101"] do
      assert {:error, :phone_country_not_supported} = Fast2Sms.send_otp(phone, "123456")
    end

    refute_received {:sms_request, _path, _auth, _payload}
  end

  test "reports an invalid key" do
    log =
      capture_log(fn ->
        assert {:error, :sms_provider_not_ready} = Fast2Sms.send_otp("+919000000412", "123456")
      end)

    assert log =~ "FAST2SMS_API_KEY"
  end

  test "reports other refusals without logging the phone, code, or key" do
    log =
      capture_log(fn ->
        assert {:error, :sms_delivery_failed} = Fast2Sms.send_otp("+919000000999", "654321")
      end)

    assert log =~ "status_code=999"
    refute log =~ "9000000999"
    refute log =~ "654321"
    refute log =~ "test-key"
  end

  test "handles a response that is not JSON" do
    capture_log(fn ->
      assert {:error, :sms_delivery_failed} = Fast2Sms.send_otp("+919000000500", "123456")
    end)
  end

  test "handles Fast2SMS being unreachable" do
    Application.put_env(:chat_server, :fast2sms_base_url, "http://127.0.0.1:1")

    capture_log(fn ->
      assert {:error, :sms_delivery_failed} = Fast2Sms.send_otp("+919876543210", "123456")
    end)
  end

  test "wallet_balance checks the key without sending anything" do
    assert {:ok, "50.0000"} = Fast2Sms.wallet_balance()
    refute_received {:sms_request, _path, _auth, _payload}

    Application.put_env(:chat_server, :fast2sms_api_key, "wrong")
    assert {:error, :sms_delivery_failed} = Fast2Sms.wallet_balance()
  end

  describe "POST /auth/request_otp using Fast2SMS" do
    setup do
      Application.put_env(:chat_server, :sms_provider, Fast2Sms)
      on_exit(fn -> Application.put_env(:chat_server, :sms_provider, TestDouble) end)
    end

    defp request_otp(conn, phone), do: post(conn, "/api/v1/auth/request_otp", %{phone: phone})

    test "returns 202 when the code is sent", %{conn: conn} do
      assert conn |> request_otp("+919876543210") |> response(202)
    end

    test "returns 503 when the key is invalid", %{conn: conn} do
      capture_log(fn ->
        assert %{"error" => "sms_provider_not_ready"} =
                 conn |> request_otp("+919000000412") |> json_response(503)
      end)
    end

    test "returns 422 for a country it cannot reach", %{conn: conn} do
      assert %{"error" => "phone_country_not_supported"} =
               conn |> request_otp("+14155552671") |> json_response(422)
    end

    test "returns 502 when sending fails", %{conn: conn} do
      capture_log(fn ->
        assert %{"error" => "sms_delivery_failed"} =
                 conn |> request_otp("+919000000999") |> json_response(502)
      end)
    end

    test "a code sent this way can complete sign-in", %{conn: conn} do
      assert conn |> request_otp("+919876543210") |> response(202)
      assert_received {:sms_request, _path, _auth, %{"message" => message}}
      [code] = Regex.run(~r/\d{6}/, message)

      body =
        conn
        |> post("/api/v1/auth/verify_otp", %{
          phone: "+919876543210",
          code: code,
          device: %{platform: "android"}
        })
        |> json_response(200)

      assert body["user"]["phone"] == "+919876543210"
    end
  end
end
