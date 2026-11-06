defmodule ChatServer.Messaging do
  @moduledoc "Stores and routes opaque encrypted messages."

  import Ecto.Query

  alias ChatServer.Accounts
  alias ChatServer.Accounts.{Device, User}
  alias ChatServer.Conversations
  alias ChatServer.Conversations.Member
  alias ChatServer.Messaging.{Delivery, Message}
  alias ChatServer.{Realtime, Repo}
  alias ChatServerWeb.MessageJSON
  alias Ecto.Changeset
  alias Ecto.Multi

  @max_ciphertext_bytes 64 * 1024
  @max_client_msg_id_length 64
  @default_page_size 50
  @max_page_size 100
  @pending_batch_size 200

  def max_ciphertext_bytes, do: @max_ciphertext_bytes

  ## Sending

  @doc """
  Validates and stores a message with one delivery row per recipient device.

  A recipient device is any signed-in device of any member except the one sending,
  so the sender's other devices stay in sync. Retrying a `client_msg_id` returns the
  original message with `duplicate?: true` and creates nothing.
  """
  def send_message(%User{} = user, %Device{} = device, params) do
    with {:ok, attrs} <- validate_send(params),
         true <- Conversations.member?(attrs.conversation_id, user.id) || {:error, :forbidden} do
      new = %Message{
        conversation_id: attrs.conversation_id,
        sender_id: user.id,
        sender_device_id: device.id,
        client_msg_id: attrs.client_msg_id,
        ciphertext: attrs.ciphertext,
        kind: String.to_existing_atom(attrs.kind)
      }

      {:ok, %{message: message, fan_out: fan_out}} =
        Multi.new()
        |> Multi.insert(:inserted, new,
          on_conflict: :nothing,
          conflict_target: [:sender_id, :client_msg_id]
        )
        |> Multi.run(:message, fn repo, _changes ->
          {:ok, repo.get_by!(Message, sender_id: user.id, client_msg_id: attrs.client_msg_id)}
        end)
        |> Multi.run(:fan_out, &fan_out(&1, &2, device.id))
        |> Repo.transaction()

      route(message, fan_out)
      {:ok, message, fan_out}
    end
  end

  # Broadcasts happen after commit, so a receiver can always find what it is told about.
  # A device with no socket simply has no subscriber: its delivery row stays pending.
  defp route(message, %{recipient_device_ids: device_ids}) do
    payload = MessageJSON.message(message)
    Enum.each(device_ids, &Realtime.broadcast_to_device(&1, "msg:new", payload))
  end

  # When the insert hit the unique index, the row we read back is the original and
  # its id differs from the one generated for this attempt.
  defp fan_out(_repo, %{inserted: %{id: id}, message: %{id: original_id}}, _device_id)
       when id != original_id do
    {:ok, %{duplicate?: true, recipient_device_ids: []}}
  end

  defp fan_out(repo, %{message: message}, sending_device_id) do
    recipient_device_ids =
      repo.all(
        from d in Device,
          as: :device,
          join: m in Member,
          on: m.user_id == d.user_id,
          where: m.conversation_id == ^message.conversation_id,
          where: d.id != ^sending_device_id,
          where: exists(Accounts.active_session_query()),
          select: d.id
      )

    rows = Enum.map(recipient_device_ids, &%{message_id: message.id, recipient_device_id: &1})
    repo.insert_all(Delivery, rows)

    {:ok, %{duplicate?: false, recipient_device_ids: recipient_device_ids}}
  end

  defp validate_send(params) do
    types = %{
      conversation_id: Ecto.UUID,
      client_msg_id: :string,
      ciphertext: :string,
      kind: :string
    }

    changeset =
      {%{}, types}
      |> Changeset.cast(params, Map.keys(types))
      |> Changeset.validate_required(Map.keys(types))
      |> Changeset.validate_length(:client_msg_id, max: @max_client_msg_id_length)
      # `system` messages are reserved for the server, so clients cannot forge them.
      |> Changeset.validate_inclusion(:kind, ["text", "media_ref"])
      |> decode_ciphertext()

    with {:ok, attrs} <- Changeset.apply_action(changeset, :validate),
         true <- byte_size(attrs.ciphertext) <= @max_ciphertext_bytes || :too_large do
      {:ok, attrs}
    else
      :too_large -> {:error, :message_too_large}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp decode_ciphertext(changeset) do
    Changeset.update_change(changeset, :ciphertext, fn encoded ->
      case Base.decode64(encoded) do
        {:ok, decoded} -> decoded
        :error -> nil
      end
    end)
    |> Changeset.validate_required([:ciphertext], message: "must be non-empty base64")
  end

  ## Reading

  @doc """
  One batch of a device's undelivered messages, oldest first. Pass the returned
  `next_cursor` to get the next batch. It is nil on the last one.
  """
  def pending_batch(device_id, cursor \\ nil) do
    messages =
      from(d in Delivery,
        join: m in assoc(d, :message),
        where: d.recipient_device_id == ^device_id and is_nil(d.delivered_at),
        where: not is_nil(m.ciphertext),
        order_by: [asc: m.inserted_at, asc: m.id],
        limit: @pending_batch_size,
        select: m
      )
      |> after_cursor(cursor)
      |> Repo.all()

    last = List.last(messages)

    %{
      messages: messages,
      next_cursor: if(length(messages) == @pending_batch_size, do: {last.inserted_at, last.id})
    }
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {inserted_at, id}) do
    from [_d, m] in query,
      where:
        fragment(
          "(?, ?) > (?, ?)",
          m.inserted_at,
          m.id,
          type(^inserted_at, :utc_datetime_usec),
          type(^id, :binary_id)
        )
  end

  @doc """
  Pages through messages the server still holds, newest first.

  Only messages the user sent or was a recipient of are visible, so someone added to
  a group later cannot read what was sent before they joined.
  """
  def list_messages(%User{} = user, conversation_id, params) do
    with {:ok, conversation_id} <- cast_conversation_id(conversation_id),
         true <- Conversations.member?(conversation_id, user.id) || {:error, :forbidden},
         {:ok, cursor} <- decode_cursor(params["cursor"]) do
      limit = page_size(params["limit"])

      messages =
        from(m in Message,
          as: :message,
          where: m.conversation_id == ^conversation_id and not is_nil(m.ciphertext),
          where: m.sender_id == ^user.id or exists(visible_delivery_query(user.id)),
          order_by: [desc: m.inserted_at, desc: m.id],
          limit: ^(limit + 1)
        )
        |> before_cursor(cursor)
        |> Repo.all()

      {page, rest} = Enum.split(messages, limit)
      next_cursor = if rest != [] and page != [], do: encode_cursor(List.last(page))
      {:ok, page, next_cursor}
    end
  end

  defp visible_delivery_query(user_id) do
    from d in Delivery,
      join: device in Device,
      on: device.id == d.recipient_device_id,
      where: d.message_id == parent_as(:message).id and device.user_id == ^user_id,
      select: 1
  end

  defp before_cursor(query, nil), do: query

  defp before_cursor(query, {inserted_at, id}) do
    from m in query,
      where:
        fragment(
          "(?, ?) < (?, ?)",
          m.inserted_at,
          m.id,
          type(^inserted_at, :utc_datetime_usec),
          type(^id, :binary_id)
        )
  end

  defp cast_conversation_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp page_size(value) when is_binary(value) do
    case Integer.parse(value) do
      {size, ""} when size > 0 -> min(size, @max_page_size)
      _other -> @default_page_size
    end
  end

  defp page_size(_value), do: @default_page_size

  defp encode_cursor(%Message{} = message) do
    Base.url_encode64("#{DateTime.to_iso8601(message.inserted_at)}|#{message.id}", padding: false)
  end

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [timestamp, id] <- String.split(decoded, "|"),
         {:ok, inserted_at, 0} <- DateTime.from_iso8601(timestamp),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {inserted_at, id}}
    else
      _invalid -> {:error, :invalid_cursor}
    end
  end

  defp decode_cursor(_cursor), do: {:error, :invalid_cursor}
end
