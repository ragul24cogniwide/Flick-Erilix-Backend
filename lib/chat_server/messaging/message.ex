defmodule ChatServer.Messaging.Message do
  @moduledoc """
  A message's metadata. The encrypted bytes live on each `Delivery`, because every
  recipient device gets its own ciphertext. The virtual `ciphertext` field carries one
  device's copy when a message is loaded or routed for that device.
  """

  use ChatServer.Schema

  schema "messages" do
    field :client_msg_id, :string
    field :ciphertext, :binary, virtual: true
    field :kind, Ecto.Enum, values: [:text, :media_ref, :system]

    belongs_to :conversation, ChatServer.Conversations.Conversation
    belongs_to :sender, ChatServer.Accounts.User
    belongs_to :sender_device, ChatServer.Accounts.Device

    timestamps(updated_at: false)
  end
end
