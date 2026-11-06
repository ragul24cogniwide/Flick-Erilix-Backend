defmodule ChatServer.PushProvider.Log do
  @moduledoc "Default provider: logs that a push would be sent. It does not log the token."

  @behaviour ChatServer.PushProvider

  require Logger

  @impl true
  def notify(_push_token, %{event: event}) do
    Logger.info("[push stub] would send #{event}")
    :ok
  end
end
