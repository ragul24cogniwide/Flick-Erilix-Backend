defmodule ChatServer.PushProvider.Fcm do
  @moduledoc """
  Sends push notifications through the Firebase Cloud Messaging HTTP v1 API.

  Uses only what ships with Erlang: `:public_key` signs the Google sign-in request as
  the service account, and `:httpc` makes the calls. Nothing here touches messages,
  which stay opaque to the server.
  """

  @behaviour ChatServer.PushProvider

  alias ChatServer.PushProvider.Fcm.TokenCache

  @scope "https://www.googleapis.com/auth/firebase.messaging"
  @token_lifetime_seconds 3600
  @http_timeout 10_000

  @impl true
  def notify(push_token, notification), do: send_message(push_token, notification, false)

  @doc """
  Checks that Google accepts the credentials, without notifying anyone. It asks FCM to
  validate a message to a made-up token, so `:ok` means sign-in worked and FCM looked at
  the request.
  """
  def check_credentials do
    case send_message("credentials-check", %{event: "new_message"}, true) do
      {:error, :invalid_token} -> :ok
      other -> other
    end
  end

  defp send_message(push_token, notification, validate_only) do
    with {:ok, access_token} <- TokenCache.fetch(),
         {:ok, status, _body} <-
           post_message(access_token, push_token, notification, validate_only) do
      handle_status(status)
    end
  end

  defp post_message(access_token, push_token, notification, validate_only) do
    %{"project_id" => project_id} = credentials()

    post(
      "#{base_url()}/v1/projects/#{project_id}/messages:send",
      [{"authorization", "Bearer #{access_token}"}],
      "application/json",
      Jason.encode!(%{
        validate_only: validate_only,
        message: message(push_token, notification)
      })
    )
  end

  # The text is fixed and generic, so a push can never reveal message content.
  defp message(push_token, notification) do
    %{
      token: push_token,
      notification: %{title: "New message"},
      data: %{event: notification.event},
      android: %{priority: "HIGH"},
      apns: %{headers: %{"apns-priority": "10", "apns-push-type": "alert"}}
    }
  end

  defp handle_status(status) when status in 200..299, do: :ok

  # The request body is fixed, so FCM rejecting it means the token is the problem.
  defp handle_status(status) when status in [400, 404], do: {:error, :invalid_token}

  defp handle_status(401) do
    TokenCache.invalidate()
    {:error, {:fcm_status, 401}}
  end

  defp handle_status(status), do: {:error, {:fcm_status, status}}

  @doc false
  # Called by TokenCache. Returns the token and how many seconds it lasts.
  def request_access_token do
    %{"token_uri" => token_uri} = credentials = credentials()

    body =
      URI.encode_query(%{
        "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion" => signed_assertion(credentials)
      })

    case post(token_uri, [], "application/x-www-form-urlencoded", body) do
      {:ok, 200, response} ->
        %{"access_token" => token, "expires_in" => expires_in} = Jason.decode!(response)
        {:ok, token, expires_in}

      {:ok, status, _response} ->
        {:error, {:fcm_auth_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp signed_assertion(credentials) do
    now = System.system_time(:second)

    claims = %{
      iss: credentials["client_email"],
      scope: @scope,
      aud: credentials["token_uri"],
      iat: now,
      exp: now + @token_lifetime_seconds
    }

    input = encode_segment(%{alg: "RS256", typ: "JWT"}) <> "." <> encode_segment(claims)

    private_key =
      credentials["private_key"]
      |> :public_key.pem_decode()
      |> hd()
      |> :public_key.pem_entry_decode()

    signature = :public_key.sign(input, :sha256, private_key)

    input <> "." <> Base.url_encode64(signature, padding: false)
  end

  defp encode_segment(map), do: map |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp post(url, headers, content_type, body) do
    request =
      {String.to_charlist(url),
       Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end),
       String.to_charlist(content_type), body}

    http_options = [timeout: @http_timeout, connect_timeout: @http_timeout, ssl: ssl_options()]

    case :httpc.request(:post, request, http_options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, response}} -> {:ok, status, response}
      # The reason is dropped because it can quote the request, which holds credentials.
      {:error, _reason} -> {:error, :fcm_unreachable}
    end
  end

  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp credentials do
    :chat_server
    |> Application.fetch_env!(:fcm_credentials_base64)
    |> Base.decode64!()
    |> Jason.decode!()
  end

  defp base_url,
    do: Application.get_env(:chat_server, :fcm_base_url, "https://fcm.googleapis.com")
end
