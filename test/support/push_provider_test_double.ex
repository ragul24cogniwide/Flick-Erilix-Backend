defmodule ChatServer.PushProvider.TestDouble do
  @moduledoc "Hands notifications to the calling test process. A token of \"fail\" errors."

  @behaviour ChatServer.PushProvider

  @impl true
  def notify("fail", _notification), do: {:error, :provider_down}

  def notify(push_token, notification) do
    send(self(), {:push_sent, push_token, notification})
    :ok
  end
end
