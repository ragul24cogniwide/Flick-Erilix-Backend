defmodule ChatServer.PushProvider.FcmTest do
  # Not async: this changes global config and uses the named token cache.
  use ExUnit.Case, async: false

  alias ChatServer.PushProvider.Fcm
  alias ChatServer.PushProvider.Fcm.TokenCache

  # Stands in for Google over real HTTP, and reports what it receives to the test.
  defmodule FakeGoogle do
    import Plug.Conn

    def init(test_pid), do: test_pid

    def call(%{request_path: "/token"} = conn, test_pid) do
      {:ok, body, conn} = read_body(conn)
      send(test_pid, {:token_request, URI.decode_query(body)})

      reply(conn, 200, %{
        access_token: "access-#{System.unique_integer([:positive])}",
        expires_in: 3600
      })
    end

    def call(conn, test_pid) do
      {:ok, body, conn} = read_body(conn)
      payload = Jason.decode!(body)

      send(test_pid, {
        :fcm_request,
        conn.request_path,
        get_req_header(conn, "authorization"),
        payload
      })

      case payload["message"]["token"] do
        "dead" -> reply(conn, 404, %{error: %{status: "NOT_FOUND"}})
        "malformed" -> reply(conn, 400, %{error: %{status: "INVALID_ARGUMENT"}})
        "credentials-check" -> reply(conn, 400, %{error: %{status: "INVALID_ARGUMENT"}})
        "expired" -> reply(conn, 401, %{error: %{status: "UNAUTHENTICATED"}})
        "down" -> reply(conn, 503, %{})
        _token -> reply(conn, 200, %{name: "projects/test/messages/1"})
      end
    end

    defp reply(conn, status, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end

  @notification %{event: "new_message"}

  setup do
    server =
      start_supervised!(
        {Bandit, plug: {FakeGoogle, self()}, port: 0, ip: :loopback, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    base_url = "http://127.0.0.1:#{port}"

    rsa_key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, rsa_key)])

    credentials =
      Jason.encode!(%{
        project_id: "test-project",
        client_email: "push@test-project.iam.gserviceaccount.com",
        private_key: pem,
        token_uri: "#{base_url}/token"
      })

    Application.put_env(:chat_server, :fcm_credentials_base64, Base.encode64(credentials))
    Application.put_env(:chat_server, :fcm_base_url, base_url)

    on_exit(fn ->
      Application.delete_env(:chat_server, :fcm_credentials_base64)
      Application.delete_env(:chat_server, :fcm_base_url)
    end)

    start_supervised!(TokenCache)

    %{rsa_key: rsa_key}
  end

  test "signs in as the service account with a valid signature", %{rsa_key: rsa_key} do
    assert :ok = Fcm.notify("good", @notification)

    assert_received {:token_request, %{"assertion" => jwt, "grant_type" => grant_type}}
    assert grant_type == "urn:ietf:params:oauth:grant-type:jwt-bearer"

    [header, claims, signature] = String.split(jwt, ".")
    public_key = {:RSAPublicKey, elem(rsa_key, 2), elem(rsa_key, 3)}

    assert :public_key.verify(
             header <> "." <> claims,
             :sha256,
             Base.url_decode64!(signature, padding: false),
             public_key
           )

    assert %{"alg" => "RS256"} = decode_segment(header)

    assert %{
             "iss" => "push@test-project.iam.gserviceaccount.com",
             "scope" => "https://www.googleapis.com/auth/firebase.messaging",
             "iat" => iat,
             "exp" => exp
           } = decode_segment(claims)

    assert exp - iat == 3600
  end

  test "sends to the project with the access token and no message content" do
    assert :ok = Fcm.notify("good", @notification)

    assert_received {:fcm_request, "/v1/projects/test-project/messages:send",
                     ["Bearer access-" <> _], payload}

    assert payload["validate_only"] == false
    assert payload["message"]["token"] == "good"
    assert payload["message"]["notification"] == %{"title" => "New message"}
    assert payload["message"]["data"] == %{"event" => "new_message"}
    assert payload["message"]["android"]["priority"] == "HIGH"
  end

  test "reuses one access token across pushes" do
    assert :ok = Fcm.notify("good", @notification)
    assert :ok = Fcm.notify("good", @notification)

    assert_received {:token_request, _first}
    refute_received {:token_request, _second}
  end

  test "reports a token FCM rejects as invalid" do
    assert {:error, :invalid_token} = Fcm.notify("dead", @notification)
    assert {:error, :invalid_token} = Fcm.notify("malformed", @notification)
  end

  test "reports a provider outage so the job retries" do
    assert {:error, {:fcm_status, 503}} = Fcm.notify("down", @notification)
  end

  test "signs in again after Google rejects the access token" do
    assert {:error, {:fcm_status, 401}} = Fcm.notify("expired", @notification)
    assert_received {:token_request, _first}

    assert :ok = Fcm.notify("good", @notification)
    assert_received {:token_request, _second}
  end

  test "reports an unreachable server without quoting the request" do
    assert :ok = Fcm.notify("good", @notification)
    Application.put_env(:chat_server, :fcm_base_url, "http://127.0.0.1:1")

    assert {:error, :fcm_unreachable} = Fcm.notify("good", @notification)
  end

  test "check_credentials validates only, and treats the made-up token as success" do
    assert :ok = Fcm.check_credentials()

    assert_received {:fcm_request, _path, _auth, payload}
    assert payload["validate_only"] == true
  end

  defp decode_segment(segment) do
    segment |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end
end
