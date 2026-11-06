defmodule ChatServer.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :phone, :string, null: false
      # SHA-256 hex of the E.164 phone, used by POST /contacts/match.
      add :phone_hash, :string, null: false
      add :display_name, :string
      add :about, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:phone])
    create unique_index(:users, [:phone_hash])

    create table(:devices, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :platform, :string, null: false
      add :push_token, :string, size: 512
      add :last_seen_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:devices, [:user_id])

    create table(:otp_codes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :phone, :string, null: false
      add :code_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :attempts, :integer, null: false, default: 0
      add :consumed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:otp_codes, [:phone, :inserted_at])
    create index(:otp_codes, [:expires_at])

    create table(:refresh_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :device_id, references(:devices, type: :binary_id, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:refresh_tokens, [:token_hash])
    create index(:refresh_tokens, [:device_id])
    create index(:refresh_tokens, [:expires_at])
  end
end
