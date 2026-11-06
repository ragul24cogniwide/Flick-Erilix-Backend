defmodule ChatServer.Keys.OneTimePrekey do
  @moduledoc "A public one-time prekey, handed out to one requester at most."

  use ChatServer.Schema

  schema "one_time_prekeys" do
    field :key_id, :integer
    field :public_key, :binary
    field :claimed_at, :utc_datetime_usec

    belongs_to :device, ChatServer.Accounts.Device

    timestamps(updated_at: false)
  end
end
