defmodule ChatServer.Messaging.Message do
  @moduledoc """
  An encrypted message. `ciphertext` is opaque: the server never inspects it, and
  clears it once every recipient device has received the message.
  """

  use ChatServer.Schema

  schema "messages" do
    field :client_msg_id, :string
    field :ciphertext, :binary
    field :kind, Ecto.Enum, values: [:text, :media_ref, :system]

    belongs_to :conversation, ChatServer.Conversations.Conversation
    belongs_to :sender, ChatServer.Accounts.User
    belongs_to :sender_device, ChatServer.Accounts.Device

    timestamps(updated_at: false)
  end
end
