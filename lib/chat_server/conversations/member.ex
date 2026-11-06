defmodule ChatServer.Conversations.Member do
  @moduledoc "A user's membership of a conversation."

  use ChatServer.Schema

  @primary_key false
  schema "conversation_members" do
    belongs_to :conversation, ChatServer.Conversations.Conversation, primary_key: true
    belongs_to :user, ChatServer.Accounts.User, primary_key: true

    field :role, Ecto.Enum, values: [:member, :admin]
    field :joined_at, :utc_datetime_usec
  end
end
