defmodule ChatServer.Keys.IdentityKey do
  @moduledoc "A device's public identity key and signed prekey. Public parts only."

  use ChatServer.Schema

  schema "identity_keys" do
    field :identity_public_key, :binary
    field :signed_prekey, :binary
    field :signed_prekey_signature, :binary

    belongs_to :device, ChatServer.Accounts.Device

    timestamps()
  end
end
