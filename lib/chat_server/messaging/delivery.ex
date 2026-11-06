defmodule ChatServer.Messaging.Delivery do
  @moduledoc "Tracks one message's progress to one recipient device."

  use ChatServer.Schema

  @primary_key false
  schema "deliveries" do
    belongs_to :message, ChatServer.Messaging.Message, primary_key: true
    belongs_to :recipient_device, ChatServer.Accounts.Device, primary_key: true

    field :delivered_at, :utc_datetime_usec
    field :read_at, :utc_datetime_usec
  end
end
