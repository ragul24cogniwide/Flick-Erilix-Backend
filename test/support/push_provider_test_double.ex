defmodule ChatServer.PushProvider.TestDouble do
  @moduledoc ~s(Hands notifications to the test process. Tokens "fail" and "dead" return errors.)

  @behaviour ChatServer.PushProvider

  @impl true
  def notify("fail", _notification), do: {:error, :provider_down}
  def notify("dead", _notification), do: {:error, :invalid_token}

  def notify(push_token, notification) do
    send(self(), {:push_sent, push_token, notification})
    :ok
  end
end
