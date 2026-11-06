defmodule ChatServer.SmsProvider.TestDouble do
  @moduledoc "Hands codes to the calling test process so a test can complete a sign-in."

  @behaviour ChatServer.SmsProvider

  @impl true
  def send_otp(phone, code) do
    send(self(), {:otp_sent, phone, code})
    :ok
  end
end
