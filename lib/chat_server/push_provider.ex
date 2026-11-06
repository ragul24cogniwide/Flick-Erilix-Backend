defmodule ChatServer.PushProvider do
  @moduledoc """
  Sends push notifications that wake an offline device so it can reconnect and fetch
  its queue. A notification never contains message content.

  To plug in a real provider (APNs, FCM), implement this behaviour and set it in
  `config/runtime.exs`:

      config :chat_server, :push_provider, ChatServer.PushProvider.MyProvider
  """

  @type notification :: %{event: String.t()}

  @callback notify(push_token :: String.t(), notification()) :: :ok | {:error, term()}

  def notify(push_token, notification), do: impl().notify(push_token, notification)

  defp impl, do: Application.fetch_env!(:chat_server, :push_provider)
end
