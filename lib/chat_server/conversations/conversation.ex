defmodule ChatServer.Conversations.Conversation do
  @moduledoc "A direct (two-person) or group chat."

  use ChatServer.Schema

  schema "conversations" do
    field :kind, Ecto.Enum, values: [:direct, :group]
    field :title, :string
    field :created_by, :binary_id
    field :direct_key, :string

    has_many :members, ChatServer.Conversations.Member

    timestamps()
  end
end
