defmodule ChatServer.Accounts.RefreshToken do
  @moduledoc "A hashed, rotating refresh token. It marks a device's session as active."

  use ChatServer.Schema

  schema "refresh_tokens" do
    field :token_hash, :binary
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :device, ChatServer.Accounts.Device

    timestamps(updated_at: false)
  end
end
