defmodule ChatServer.SmsProvider.Unconfigured do
  @moduledoc """
  The default provider. It sends nothing and returns an error, so a production
  deployment without a real provider fails loudly instead of leaking codes to the log.
  """

  @behaviour ChatServer.SmsProvider

  @impl true
  def send_otp(_phone, _code), do: {:error, :sms_provider_not_configured}
end
