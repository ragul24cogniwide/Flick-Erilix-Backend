defmodule ChatServer.Messaging.Delivery do
  @moduledoc """
  One message's progress to one recipient device, holding that device's ciphertext.
  The ciphertext is opaque: the server never inspects it, and clears it as soon as the
  device has the message.
  """

  use ChatServer.Schema

  @primary_key false
  schema "deliveries" do
    belongs_to :message, ChatServer.Messaging.Message, primary_key: true
    belongs_to :recipient_device, ChatServer.Accounts.Device, primary_key: true

    field :ciphertext, :binary
    field :delivered_at, :utc_datetime_usec
    field :read_at, :utc_datetime_usec
  end
end
