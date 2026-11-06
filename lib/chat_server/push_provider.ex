defmodule ChatServer.PushProvider do
  @moduledoc """
  Sends push notifications that wake an offline device so it can reconnect and fetch
  its queue. A notification never contains message content.

  Setting `FIREBASE_CREDENTIALS_BASE64` selects `ChatServer.PushProvider.Fcm`. To use
  another provider, implement this behaviour and set it in `config/runtime.exs`:

      config :chat_server, :push_provider, ChatServer.PushProvider.MyProvider
  """

  @type notification :: %{event: String.t()}

  @doc """
  Sends one notification. Return `{:error, :invalid_token}` when the provider says the
  token is dead: the token is then removed from the device and the job is not retried.
  Any other error is retried.
  """
  @callback notify(push_token :: String.t(), notification()) :: :ok | {:error, term()}

  def notify(push_token, notification), do: impl().notify(push_token, notification)

  defp impl, do: Application.fetch_env!(:chat_server, :push_provider)
end
