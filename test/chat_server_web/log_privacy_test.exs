defmodule ChatServerWeb.LogPrivacyTest do
  # Not async: this changes the global log level.
  use ChatServerWeb.ChannelCase

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  setup do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)
    :ok
  end

  test "the HTTP sign-in flow logs no phone, code, or token, even at debug level" do
    phone = unique_phone()

    {body, log} =
      with_log([level: :debug], fn ->
        build_conn()
        |> post("/api/v1/auth/request_otp", %{phone: phone})
        |> response(202)

        assert_received {:otp_sent, ^phone, code}

        body =
          build_conn()
          |> post("/api/v1/auth/verify_otp", %{
            phone: phone,
            code: code,
            device: %{platform: "web"}
          })
          |> json_response(200)

        build_conn()
        |> put_req_header("authorization", "Bearer #{body["access_token"]}")
        |> get("/api/v1/me")
        |> response(200)

        build_conn()
        |> post("/api/v1/auth/refresh", %{refresh_token: body["refresh_token"]})
        |> response(200)

        Map.put(body, "code", code)
      end)

    assert log =~ "verify_otp", "expected the request itself to be logged"
    refute log =~ phone
    refute log =~ body["access_token"]
    refute log =~ body["refresh_token"]
    refute log =~ ~s("code" => "#{body["code"]}")
  end

  test "the socket logs no token or ciphertext, even at debug level" do
    alice = session_fixture()
    bob = session_fixture()
    conversation = direct_fixture(alice, bob)
    ciphertext = Base.encode64("very-secret-ciphertext")

    log =
      capture_log([level: :debug], fn ->
        channel = join_device(alice)
        _bob = join_device(bob)

        ref =
          push(
            channel,
            "msg:send",
            send_params(alice, conversation, %{"ciphertext" => ciphertext})
          )

        assert_reply ref, :ok, %{message_id: message_id}

        assert_push "msg:new", %{message_id: ^message_id}
      end)

    refute log =~ alice.access_token
    refute log =~ bob.access_token
    refute log =~ ciphertext
    refute log =~ alice.user.phone
  end
end
