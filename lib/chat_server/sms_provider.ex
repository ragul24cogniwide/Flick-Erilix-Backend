defmodule ChatServer.SmsProvider do
  @moduledoc """
  Sends one-time codes by SMS.

  Setting `FAST2SMS_API_KEY` selects `ChatServer.SmsProvider.Fast2Sms`. To use another
  provider, implement this behaviour and set it in `config/runtime.exs`:

      config :chat_server, :sms_provider, ChatServer.SmsProvider.MyProvider
  """

  @callback send_otp(phone :: String.t(), code :: String.t()) :: :ok | {:error, term()}

  def send_otp(phone, code), do: impl().send_otp(phone, code)

  defp impl, do: Application.fetch_env!(:chat_server, :sms_provider)
end
