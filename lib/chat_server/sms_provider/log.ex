defmodule ChatServer.SmsProvider.Log do
  @moduledoc "Development provider: prints the code to the log. Never configure this in production."

  @behaviour ChatServer.SmsProvider

  require Logger

  @impl true
  def send_otp(phone, code) do
    Logger.info(
      "[dev sms] sign-in code #{code} for phone ending #{String.slice(phone, -4..-1//1)}"
    )

    :ok
  end
end
