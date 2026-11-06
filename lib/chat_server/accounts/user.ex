defmodule ChatServer.Accounts.User do
  @moduledoc "A person, identified by a verified E.164 phone number."

  use ChatServer.Schema

  @e164 ~r/^\+[1-9][0-9]{6,14}$/

  schema "users" do
    field :phone, :string
    field :phone_hash, :string
    field :display_name, :string
    field :about, :string

    has_many :devices, ChatServer.Accounts.Device

    timestamps()
  end

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:phone])
    |> validate_required([:phone])
    |> validate_format(:phone, @e164, message: "must be in E.164 format")
    |> put_phone_hash()
    |> unique_constraint(:phone)
  end

  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:display_name, :about])
    |> validate_length(:display_name, max: 64)
    |> validate_length(:about, max: 256)
  end

  @doc "The contact-matching hash: lowercase hex SHA-256 of the E.164 phone."
  def hash_phone(phone), do: :sha256 |> :crypto.hash(phone) |> Base.encode16(case: :lower)

  def valid_phone?(phone), do: is_binary(phone) and Regex.match?(@e164, phone)

  defp put_phone_hash(%{valid?: true} = changeset) do
    put_change(changeset, :phone_hash, hash_phone(get_field(changeset, :phone)))
  end

  defp put_phone_hash(changeset), do: changeset
end
