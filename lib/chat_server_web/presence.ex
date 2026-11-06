defmodule ChatServerWeb.Presence do
  @moduledoc "Tracks connected devices in memory, across the cluster. Never touches the database."

  use Phoenix.Presence,
    otp_app: :chat_server,
    pubsub_server: ChatServer.PubSub
end
