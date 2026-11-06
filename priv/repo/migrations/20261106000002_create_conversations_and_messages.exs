defmodule ChatServer.Repo.Migrations.CreateConversationsAndMessages do
  use Ecto.Migration

  def change do
    create table(:conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false
      add :title, :string
      add :created_by, references(:users, type: :binary_id, on_delete: :nilify_all)
      # The sorted user pair of a direct chat. NULL for groups, and Postgres treats
      # NULLs as distinct, so the unique index only constrains direct chats.
      add :direct_key, :string
      timestamps(type: :utc_datetime_usec)
    end

    create index(:conversations, [:created_by])
    create unique_index(:conversations, [:direct_key])

    create table(:conversation_members, primary_key: false) do
      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all),
          primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :role, :string, null: false
      add :joined_at, :utc_datetime_usec, null: false
    end

    create index(:conversation_members, [:user_id])

    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :sender_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :sender_device_id, references(:devices, type: :binary_id, on_delete: :nilify_all)
      add :client_msg_id, :string, null: false
      # NULL once every recipient device has received the message.
      add :ciphertext, :binary
      add :kind, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:messages, [:sender_id, :client_msg_id])
    create index(:messages, [:conversation_id, :inserted_at])
    create index(:messages, [:sender_device_id])
    create index(:messages, [:inserted_at], where: "ciphertext IS NOT NULL")

    create table(:deliveries, primary_key: false) do
      add :message_id, references(:messages, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :recipient_device_id, references(:devices, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :delivered_at, :utc_datetime_usec
      add :read_at, :utc_datetime_usec
    end

    create index(:deliveries, [:recipient_device_id, :delivered_at],
             where: "delivered_at IS NULL",
             name: :deliveries_pending_index
           )

    create index(:deliveries, [:recipient_device_id])
  end
end
