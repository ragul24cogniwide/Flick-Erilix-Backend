defmodule ChatServer.Messaging do
  @moduledoc "Stores and routes opaque encrypted messages."

  import Ecto.Query

  alias ChatServer.Accounts
  alias ChatServer.Accounts.{Device, User}
  alias ChatServer.Conversations
  alias ChatServer.Conversations.Member
  alias ChatServer.Keys.IdentityKey
  alias ChatServer.Messaging.{Delivery, Message}
  alias ChatServer.{Realtime, Repo}
  alias ChatServer.Workers.PushNotification
  alias ChatServerWeb.MessageJSON
  alias Ecto.Changeset
  alias Ecto.Multi

  @max_ciphertext_bytes 64 * 1024
  # One send carries a copy per device. Together these must fit the socket's frame limit.
  @max_total_ciphertext_bytes 3 * 1024 * 1024
  @max_client_msg_id_length 64
  @default_page_size 50
  @max_page_size 100
  @pending_batch_size 200
  @undelivered_retention_days 30

  ## Sending

  @doc """
  Validates and stores a message, with one delivery row and ciphertext per device.

  The sender must supply a ciphertext for exactly the devices that should receive it:
  every signed-in device with uploaded keys, of every member, except the one sending. If
  the list is out of date this returns `{:error, {:device_mismatch, details}}` and stores
  nothing, so the client can fetch the missing devices' keys, re-encrypt, and retry.

  Retrying a `client_msg_id` returns the original message with `duplicate?: true`, even
  if the conversation's devices have changed since.
  """
  def send_message(%User{} = user, %Device{} = device, params) do
    with {:ok, attrs} <- validate_send(params),
         true <- Conversations.member?(attrs.conversation_id, user.id) || {:error, :forbidden} do
      new = %Message{
        conversation_id: attrs.conversation_id,
        sender_id: user.id,
        sender_device_id: device.id,
        client_msg_id: attrs.client_msg_id,
        kind: String.to_existing_atom(attrs.kind)
      }

      Multi.new()
      |> Multi.one(
        :existing,
        from(m in Message,
          where: m.sender_id == ^user.id and m.client_msg_id == ^attrs.client_msg_id
        )
      )
      |> Multi.run(:recipients, &check_recipients(&1, &2, new, attrs.ciphertexts))
      |> Multi.run(:stored, &store_message(&1, &2, new, attrs.ciphertexts))
      |> Repo.transaction()
      |> case do
        {:ok, %{stored: {message, fan_out}}} ->
          route(message, fan_out, attrs.ciphertexts)
          {:ok, message, fan_out}

        {:error, :recipients, mismatch, _changes} ->
          {:error, {:device_mismatch, mismatch}}
      end
    end
  end

  @doc "The `{device_id, user_id}` of every device a new message must be encrypted for."
  def recipient_devices(repo \\ Repo, conversation_id, sending_device_id) do
    repo.all(
      from d in Device,
        as: :device,
        join: m in Member,
        on: m.user_id == d.user_id,
        # A device with no keys cannot be encrypted for, so it is not a recipient.
        join: k in IdentityKey,
        on: k.device_id == d.id,
        where: m.conversation_id == ^conversation_id,
        where: d.id != ^sending_device_id,
        where: exists(Accounts.active_session_query()),
        select: {d.id, d.user_id}
    )
  end

  defp check_recipients(_repo, %{existing: %Message{}}, _new, _ciphertexts), do: {:ok, []}

  defp check_recipients(repo, _changes, new, ciphertexts) do
    recipients = recipient_devices(repo, new.conversation_id, new.sender_device_id)
    recipient_ids = MapSet.new(recipients, &elem(&1, 0))

    missing =
      for {device_id, user_id} <- recipients, not is_map_key(ciphertexts, device_id) do
        %{device_id: device_id, user_id: user_id}
      end

    extra = for {device_id, _bytes} <- ciphertexts, device_id not in recipient_ids, do: device_id

    if missing == [] and extra == [] do
      {:ok, recipients}
    else
      {:error, %{missing: missing, extra: extra}}
    end
  end

  defp store_message(_repo, %{existing: %Message{} = existing}, _new, _ciphertexts) do
    {:ok, {existing, duplicate_fan_out()}}
  end

  defp store_message(repo, %{recipients: recipients}, new, ciphertexts) do
    {:ok, inserted} =
      repo.insert(new, on_conflict: :nothing, conflict_target: [:sender_id, :client_msg_id])

    stored = repo.get_by!(Message, sender_id: new.sender_id, client_msg_id: new.client_msg_id)

    # When a concurrent retry won the unique index, the row read back is the original,
    # and its id differs from the one generated for this attempt.
    if stored.id == inserted.id do
      {device_ids, user_ids} = Enum.unzip(recipients)

      rows =
        Enum.map(device_ids, fn device_id ->
          %{
            message_id: stored.id,
            recipient_device_id: device_id,
            ciphertext: Map.fetch!(ciphertexts, device_id)
          }
        end)

      repo.insert_all(Delivery, rows)

      {:ok,
       {stored,
        %{
          duplicate?: false,
          recipient_device_ids: device_ids,
          recipient_user_ids: Enum.uniq(user_ids)
        }}}
    else
      {:ok, {stored, duplicate_fan_out()}}
    end
  end

  defp duplicate_fan_out do
    %{duplicate?: true, recipient_device_ids: [], recipient_user_ids: []}
  end

  # Runs after commit, so a receiver can always find what it is told about. A device
  # with no socket has no subscriber: its delivery row stays pending until it returns.
  defp route(_message, %{duplicate?: true}, _ciphertexts), do: :ok

  defp route(message, %{recipient_device_ids: device_ids} = fan_out, ciphertexts) do
    Enum.each(device_ids, fn device_id ->
      payload = MessageJSON.message(%{message | ciphertext: Map.fetch!(ciphertexts, device_id)})
      Realtime.broadcast_to_device(device_id, "msg:new", payload)
    end)

    online = Realtime.online_device_ids(fan_out.recipient_user_ids)
    device_ids |> Enum.reject(&MapSet.member?(online, &1)) |> PushNotification.enqueue()
  end

  defp validate_send(params) do
    types = %{
      conversation_id: Ecto.UUID,
      client_msg_id: :string,
      ciphertexts: {:array, :map},
      kind: :string
    }

    changeset =
      {%{}, types}
      |> Changeset.cast(params, Map.keys(types))
      |> Changeset.validate_required(Map.keys(types))
      |> Changeset.validate_length(:client_msg_id, max: @max_client_msg_id_length)
      # `system` messages are reserved for the server, so clients cannot forge them.
      |> Changeset.validate_inclusion(:kind, ["text", "media_ref"])

    with {:ok, attrs} <- Changeset.apply_action(changeset, :validate) do
      case decode_ciphertexts(attrs.ciphertexts) do
        {:ok, ciphertexts} ->
          {:ok, %{attrs | ciphertexts: ciphertexts}}

        :invalid ->
          changeset
          |> Changeset.add_error(:ciphertexts, "must be device ids with non-empty base64")
          |> Changeset.apply_action(:validate)

        :too_large ->
          {:error, :message_too_large}
      end
    end
  end

  defp decode_ciphertexts(entries) do
    decoded = Enum.map(entries, &decode_ciphertext/1)

    cond do
      Enum.any?(decoded, &(&1 == :invalid)) -> :invalid
      length(Enum.uniq_by(decoded, &elem(&1, 0))) != length(decoded) -> :invalid
      too_large?(decoded) -> :too_large
      true -> {:ok, Map.new(decoded)}
    end
  end

  defp decode_ciphertext(%{"device_id" => device_id, "ciphertext" => encoded})
       when is_binary(encoded) do
    with {:ok, device_id} <- Ecto.UUID.cast(device_id),
         {:ok, bytes} when bytes != "" <- Base.decode64(encoded) do
      {device_id, bytes}
    else
      _invalid -> :invalid
    end
  end

  defp decode_ciphertext(_entry), do: :invalid

  defp too_large?(decoded) do
    sizes = Enum.map(decoded, fn {_device_id, bytes} -> byte_size(bytes) end)

    Enum.any?(sizes, &(&1 > @max_ciphertext_bytes)) or
      Enum.sum(sizes) > @max_total_ciphertext_bytes
  end

  ## Releasing

  @doc """
  With `:delete_row` retention, deletes any of these messages that no device is still
  waiting for. With `:keep_metadata` there is nothing to do, because each device's
  ciphertext was already cleared when it received the message.

  With `:delete_row` the delivery rows go too, so a read receipt can no longer be
  recorded once a message has been fully delivered.
  """
  def release_delivered([]), do: :ok

  def release_delivered(message_ids) do
    case Application.get_env(:chat_server, :delivered_message_retention, :keep_metadata) do
      :keep_metadata ->
        :ok

      :delete_row ->
        Repo.delete_all(
          from m in Message,
            as: :message,
            where: m.id in ^message_ids,
            where: not exists(undelivered_query())
        )

        :ok
    end
  end

  defp undelivered_query do
    from d in Delivery,
      where: d.message_id == parent_as(:message).id and is_nil(d.delivered_at),
      select: 1
  end

  @doc "Drops a logged-out device's queue, so it stops holding messages on the server."
  def forget_device_queue(device_id) do
    drop_pending(from d in Delivery, where: d.recipient_device_id == ^device_id)
  end

  @doc "Drops what is queued for a user removed from a conversation."
  def forget_member_queue(conversation_id, user_id) do
    messages = from m in Message, where: m.conversation_id == ^conversation_id, select: m.id
    devices = from d in Device, where: d.user_id == ^user_id, select: d.id

    drop_pending(
      from d in Delivery,
        where: d.message_id in subquery(messages),
        where: d.recipient_device_id in subquery(devices)
    )
  end

  defp drop_pending(deliveries) do
    {_count, message_ids} =
      Repo.delete_all(from d in deliveries, where: is_nil(d.delivered_at), select: d.message_id)

    release_delivered(message_ids)
  end

  @doc "Drops messages that some device still has not received after 30 days."
  def drop_expired_messages do
    cutoff = DateTime.add(DateTime.utc_now(), -@undelivered_retention_days, :day)

    {count, _rows} =
      Repo.delete_all(
        from m in Message,
          as: :message,
          where: m.inserted_at < ^cutoff,
          where: exists(undelivered_query())
      )

    count
  end

  ## Reading

  def device_has_pending?(device_id) do
    Repo.exists?(
      from d in Delivery, where: d.recipient_device_id == ^device_id and is_nil(d.delivered_at)
    )
  end

  @doc """
  One batch of a device's undelivered messages, oldest first. Pass the returned
  `next_cursor` to get the next batch. It is nil on the last one.
  """
  def pending_batch(device_id, cursor \\ nil) do
    messages =
      from(d in Delivery,
        join: m in assoc(d, :message),
        where: d.recipient_device_id == ^device_id and is_nil(d.delivered_at),
        where: not is_nil(d.ciphertext),
        order_by: [asc: m.inserted_at, asc: m.id],
        limit: @pending_batch_size,
        select: %{m | ciphertext: d.ciphertext}
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
  Pages through what the server still holds for this device, newest first. A device can
  only read its own copies, so someone added to a group later cannot see earlier messages.
  """
  def list_messages(%User{} = user, %Device{} = device, conversation_id, params) do
    with {:ok, conversation_id} <- cast_conversation_id(conversation_id),
         true <- Conversations.member?(conversation_id, user.id) || {:error, :forbidden},
         {:ok, cursor} <- decode_cursor(params["cursor"]) do
      limit = page_size(params["limit"])

      messages =
        from(d in Delivery,
          join: m in assoc(d, :message),
          where: d.recipient_device_id == ^device.id and not is_nil(d.ciphertext),
          where: m.conversation_id == ^conversation_id,
          order_by: [desc: m.inserted_at, desc: m.id],
          limit: ^(limit + 1),
          select: %{m | ciphertext: d.ciphertext}
        )
        |> before_cursor(cursor)
        |> Repo.all()

      {page, rest} = Enum.split(messages, limit)
      next_cursor = if rest != [] and page != [], do: encode_cursor(List.last(page))
      {:ok, page, next_cursor}
    end
  end

  defp before_cursor(query, nil), do: query

  defp before_cursor(query, {inserted_at, id}) do
    from [_d, m] in query,
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
