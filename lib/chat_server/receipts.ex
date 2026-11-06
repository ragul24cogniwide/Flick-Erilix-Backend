defmodule ChatServer.Receipts do
  @moduledoc "Delivery and read acknowledgements: the ticks."

  import Ecto.Query

  alias ChatServer.Accounts.{Device, User}
  alias ChatServer.Conversations
  alias ChatServer.Messaging
  alias ChatServer.Messaging.{Delivery, Message}
  alias ChatServer.{Realtime, Repo}
  alias Ecto.Changeset

  @max_ack_batch 500

  @doc """
  Marks messages delivered to this device, clears its ciphertext, and tells the senders.
  Only the device's own rows can change, so acking someone else's message does nothing.
  """
  def mark_delivered(%User{} = user, %Device{} = device, params) do
    with {:ok, %{message_ids: message_ids}} <- validate_delivered(params) do
      now = DateTime.utc_now()

      {_count, acked_ids} =
        Repo.update_all(
          from(d in Delivery,
            where: d.recipient_device_id == ^device.id,
            where: d.message_id in ^message_ids and is_nil(d.delivered_at),
            select: d.message_id
          ),
          set: [delivered_at: now, ciphertext: nil]
        )

      senders =
        Repo.all(from m in Message, where: m.id in ^acked_ids, select: {m.id, m.sender_id})

      notify_senders("receipt:delivered", senders, user.id)

      # Runs after the update commits, never inside one transaction with it. Two devices
      # acking at once would each miss the other's uncommitted row, and neither would
      # release the message.
      Messaging.release_delivered(acked_ids)

      {:ok, acked_ids}
    end
  end

  @doc """
  Marks everything up to and including a message as read on this device. Reading
  implies delivery, so any row not yet delivered is marked delivered too.
  """
  def mark_read(%User{} = user, %Device{} = device, params) do
    with {:ok, attrs} <- validate_read(params),
         true <- Conversations.member?(attrs.conversation_id, user.id) || {:error, :forbidden},
         {:ok, up_to} <- fetch_up_to(attrs) do
      now = DateTime.utc_now()

      {_count, read} =
        Repo.update_all(
          from(d in Delivery,
            join: m in Message,
            on: m.id == d.message_id,
            where: d.recipient_device_id == ^device.id and is_nil(d.read_at),
            where: m.conversation_id == ^attrs.conversation_id,
            where:
              fragment(
                "(?, ?) <= (?, ?)",
                m.inserted_at,
                m.id,
                type(^up_to.inserted_at, :utc_datetime_usec),
                type(^up_to.id, :binary_id)
              ),
            update: [
              set: [
                read_at: ^now,
                delivered_at: fragment("COALESCE(?, ?)", d.delivered_at, ^now),
                ciphertext: nil
              ]
            ],
            select: {m.id, m.sender_id}
          ),
          []
        )

      notify_senders("receipt:read", read, user.id)

      message_ids = Enum.map(read, &elem(&1, 0))
      Messaging.release_delivered(message_ids)

      {:ok, message_ids}
    end
  end

  defp fetch_up_to(%{conversation_id: conversation_id, up_to_message_id: id}) do
    query = from m in Message, where: m.id == ^id and m.conversation_id == ^conversation_id

    case Repo.one(query) do
      nil -> {:error, :not_found}
      message -> {:ok, message}
    end
  end

  # A user's own devices do not generate ticks for that user.
  defp notify_senders(event, senders, by_user_id) do
    for {message_id, sender_id} <- senders, sender_id != by_user_id do
      Realtime.broadcast_to_user(sender_id, event, %{
        message_id: message_id,
        by_user_id: by_user_id
      })
    end

    :ok
  end

  defp validate_delivered(params) do
    types = %{message_ids: {:array, Ecto.UUID}}

    {%{}, types}
    |> Changeset.cast(params, [:message_ids])
    |> Changeset.validate_required([:message_ids])
    |> Changeset.validate_length(:message_ids, max: @max_ack_batch)
    |> Changeset.apply_action(:validate)
  end

  defp validate_read(params) do
    types = %{conversation_id: Ecto.UUID, up_to_message_id: Ecto.UUID}

    {%{}, types}
    |> Changeset.cast(params, Map.keys(types))
    |> Changeset.validate_required(Map.keys(types))
    |> Changeset.apply_action(:validate)
  end
end
