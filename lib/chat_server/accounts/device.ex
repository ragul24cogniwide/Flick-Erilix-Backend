defmodule ChatServer.Accounts.Device do
  @moduledoc "One signed-in client of a user. A user can have several."

  use ChatServer.Schema

  schema "devices" do
    field :platform, Ecto.Enum, values: [:android, :ios, :web]
    field :push_token, :string
    field :last_seen_at, :utc_datetime_usec

    belongs_to :user, ChatServer.Accounts.User
    has_many :refresh_tokens, ChatServer.Accounts.RefreshToken

    timestamps()
  end

  def changeset(device, attrs) do
    device
    |> cast(attrs, [:platform, :push_token])
    |> validate_required([:platform])
    |> validate_length(:push_token, max: 512)
  end

  def push_token_changeset(device, attrs) do
    # Blanking the old value first makes a missing token an error, not a silent no-op.
    %{device | push_token: nil}
    |> cast(attrs, [:push_token])
    |> validate_required([:push_token])
    |> validate_length(:push_token, max: 512)
  end
end
