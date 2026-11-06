defmodule ChatServer.Repo.Migrations.CreateKeys do
  use Ecto.Migration

  def change do
    create table(:identity_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :device_id, references(:devices, type: :binary_id, on_delete: :delete_all), null: false
      add :identity_public_key, :binary, null: false
      add :signed_prekey, :binary, null: false
      add :signed_prekey_signature, :binary, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:identity_keys, [:device_id])

    create table(:one_time_prekeys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :device_id, references(:devices, type: :binary_id, on_delete: :delete_all), null: false
      add :key_id, :bigint, null: false
      add :public_key, :binary, null: false
      add :claimed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:one_time_prekeys, [:device_id, :key_id])

    create index(:one_time_prekeys, [:device_id, :key_id],
             where: "claimed_at IS NULL",
             name: :one_time_prekeys_unclaimed_index
           )
  end
end
