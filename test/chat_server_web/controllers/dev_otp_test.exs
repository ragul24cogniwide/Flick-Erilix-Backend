defmodule ChatServerWeb.DevOtpTest do
  # Not async: this changes global config.
  use ChatServerWeb.ConnCase, async: false

  import ChatServer.Fixtures

  defp request_otp(conn, phone) do
    conn |> post("/api/v1/auth/request_otp", %{phone: phone}) |> json_response(202)
  end

  describe "with DEV_MODE_EXPOSE_OTP on" do
    setup do
      Application.put_env(:chat_server, :dev_mode_expose_otp, true)
      on_exit(fn -> Application.delete_env(:chat_server, :dev_mode_expose_otp) end)
    end

    test "returns the code as dev_otp and sends no SMS", %{conn: conn} do
      assert %{"status" => "code_sent", "dev_otp" => code} = request_otp(conn, unique_phone())

      assert code =~ ~r/^\d{6}$/
      refute_received {:otp_sent, _phone, _code}
    end

    test "the returned code completes sign-in, once", %{conn: conn} do
      phone = unique_phone()
      %{"dev_otp" => code} = request_otp(conn, phone)
      params = %{phone: phone, code: code, device: %{platform: "android"}}

      assert %{"user" => %{"phone" => ^phone}} =
               conn |> post("/api/v1/auth/verify_otp", params) |> json_response(200)

      assert conn |> post("/api/v1/auth/verify_otp", params) |> response(401)
    end

    test "still rejects wrong codes and invalid phones", %{conn: conn} do
      phone = unique_phone()
      %{"dev_otp" => code} = request_otp(conn, phone)
      wrong = if code == "000000", do: "000001", else: "000000"

      assert conn
             |> post("/api/v1/auth/verify_otp", %{
               phone: phone,
               code: wrong,
               device: %{platform: "android"}
             })
             |> response(401)

      assert conn |> post("/api/v1/auth/request_otp", %{phone: "123"}) |> response(422)
    end
  end

  test "with it off, the code is sent by SMS and never returned", %{conn: conn} do
    phone = unique_phone()

    body = request_otp(conn, phone)

    refute Map.has_key?(body, "dev_otp")
    assert_received {:otp_sent, ^phone, _code}
  end
end
