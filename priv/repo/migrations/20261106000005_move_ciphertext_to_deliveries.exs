defmodule ChatServer.Repo.Migrations.MoveCiphertextToDeliveries do
  @moduledoc """
  Each recipient device now gets its own ciphertext, so that standard pairwise Signal
  encryption works. The column moves from messages to deliveries.
  """

  use Ecto.Migration

  def up do
    alter table(:deliveries) do
      add :ciphertext, :binary
    end

    flush()

    execute """
    UPDATE deliveries d SET ciphertext = m.ciphertext
    FROM messages m
    WHERE d.message_id = m.id AND d.delivered_at IS NULL
    """

    drop index(:messages, [:inserted_at], where: "ciphertext IS NOT NULL")

    alter table(:messages) do
      remove :ciphertext
    end

    create index(:messages, [:inserted_at])
  end

  def down do
    drop index(:messages, [:inserted_at])

    alter table(:messages) do
      add :ciphertext, :binary
    end

    flush()

    execute """
    UPDATE messages m SET ciphertext = d.ciphertext
    FROM deliveries d
    WHERE d.message_id = m.id AND d.ciphertext IS NOT NULL
    """

    create index(:messages, [:inserted_at], where: "ciphertext IS NOT NULL")

    alter table(:deliveries) do
      remove :ciphertext
    end
  end
end
