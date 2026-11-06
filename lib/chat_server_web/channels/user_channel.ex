defmodule ChatServerWeb.UserChannel do
  @moduledoc """
  One per connected device.

  Messages travel on a per-device topic so each device tracks its own delivery state.
  Receipts go on the shared `user:<id>` topic to reach all of a user's devices.

  Typing and presence must never touch the database, so the conversations and peers
  they need are held in memory here. They are loaded on join and reloaded when
  membership changes, which also keeps the per-event authorization check current.
  """

  use Phoenix.Channel, log_join: false, log_handle_in: false

  alias ChatServer.{Conversations, Messaging, RateLimiter, Realtime, Receipts}
  alias ChatServerWeb.{Endpoint, MessageJSON, Presence}
  alias Phoenix.Socket.Broadcast

  @presence_statuses ["online", "away"]

  @impl true
  def join("user:" <> user_id, _params, %{assigns: %{user: %{id: user_id}}} = socket) do
    # Subscribe before reading the queue, so no message can fall between the two.
    Endpoint.subscribe(Realtime.device_topic(socket.assigns.device.id))
    Realtime.subscribe_to_membership_changes(user_id)
    send(self(), :after_join)

    socket =
      socket
      |> assign(:flushed_ids, MapSet.new())
      |> assign(:conversation_ids, MapSet.new())
      |> assign(:peer_ids, MapSet.new())
      |> sync_membership()

    {:ok, socket}
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "unauthorized"}}

  @impl true
  def handle_in("msg:send", params, socket) do
    %{user: user, device: device, client_ip: client_ip} = socket.assigns

    with :ok <- RateLimiter.check_all([{:msg_send_user, user.id}, {:msg_send_ip, client_ip}]),
         {:ok, message, _fan_out} <- Messaging.send_message(user, device, params) do
      {:reply, {:ok, %{message_id: message.id, server_ts: message.inserted_at}}, socket}
    else
      {:error, reason} -> {:reply, {:error, error_payload(reason)}, socket}
    end
  end

  def handle_in("msg:ack_delivered", params, socket) do
    case Receipts.mark_delivered(socket.assigns.user, socket.assigns.device, params) do
      {:ok, acked_ids} ->
        flushed_ids = MapSet.difference(socket.assigns.flushed_ids, MapSet.new(acked_ids))
        {:reply, {:ok, %{count: length(acked_ids)}}, assign(socket, :flushed_ids, flushed_ids)}

      {:error, reason} ->
        {:reply, {:error, error_payload(reason)}, socket}
    end
  end

  def handle_in("msg:ack_read", params, socket) do
    case Receipts.mark_read(socket.assigns.user, socket.assigns.device, params) do
      {:ok, read_ids} -> {:reply, {:ok, %{count: length(read_ids)}}, socket}
      {:error, reason} -> {:reply, {:error, error_payload(reason)}, socket}
    end
  end

  def handle_in("typing:start", params, socket), do: handle_typing("start", params, socket)
  def handle_in("typing:stop", params, socket), do: handle_typing("stop", params, socket)

  def handle_in("presence:update", %{"status" => status}, socket)
      when status in @presence_statuses do
    user_id = socket.assigns.user.id

    {:ok, _ref} =
      Presence.update(
        self(),
        Realtime.presence_topic(user_id),
        user_id,
        &Map.put(&1, :status, status)
      )

    {:reply, {:ok, %{status: status}}, socket}
  end

  def handle_in("presence:update", _params, socket) do
    {:reply, {:error, %{reason: "invalid_status"}}, socket}
  end

  def handle_in(_event, _params, socket) do
    {:reply, {:error, %{reason: "unknown_event"}}, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    user_id = socket.assigns.user.id

    {:ok, _ref} =
      Presence.track(self(), Realtime.presence_topic(user_id), user_id, %{
        device_id: socket.assigns.device.id,
        status: "online"
      })

    push(socket, "presence_state", presences_of(socket.assigns.peer_ids))

    {:noreply, flush_pending(socket)}
  end

  def handle_info(:membership_changed, socket) do
    previous_peer_ids = socket.assigns.peer_ids
    socket = sync_membership(socket)

    joined = MapSet.difference(socket.assigns.peer_ids, previous_peer_ids)
    left = MapSet.difference(previous_peer_ids, socket.assigns.peer_ids)

    if MapSet.size(joined) > 0 or MapSet.size(left) > 0 do
      push(socket, "presence_diff", %{joins: presences_of(joined), leaves: presences_of(left)})
    end

    {:noreply, socket}
  end

  def handle_info(%Broadcast{event: "msg:new", payload: payload}, socket) do
    flushed_ids = socket.assigns.flushed_ids

    # A message committed just before the queue read arrives twice: from the queue
    # and from this broadcast. Clients still dedupe, but this avoids the common case.
    if MapSet.member?(flushed_ids, payload.message_id) do
      {:noreply, assign(socket, :flushed_ids, MapSet.delete(flushed_ids, payload.message_id))}
    else
      push(socket, "msg:new", payload)
      {:noreply, socket}
    end
  end

  def handle_info(%Broadcast{event: "typing", payload: payload}, socket) do
    if payload.user_id != socket.assigns.user.id do
      push(socket, "typing", payload)
    end

    {:noreply, socket}
  end

  def handle_info(%Broadcast{event: "presence_diff", payload: payload}, socket) do
    push(socket, "presence_diff", payload)
    {:noreply, socket}
  end

  defp handle_typing(state, %{"conversation_id" => conversation_id}, socket) do
    if MapSet.member?(socket.assigns.conversation_ids, conversation_id) do
      Endpoint.broadcast_from(self(), Realtime.conversation_topic(conversation_id), "typing", %{
        conversation_id: conversation_id,
        user_id: socket.assigns.user.id,
        state: state
      })

      {:noreply, socket}
    else
      {:reply, {:error, %{reason: :forbidden}}, socket}
    end
  end

  defp handle_typing(_state, _params, socket) do
    {:reply, {:error, %{reason: "invalid_payload"}}, socket}
  end

  defp sync_membership(socket) do
    %{conversation_ids: conversation_ids, peer_ids: peer_ids} =
      Conversations.membership_snapshot(socket.assigns.user.id)

    resubscribe(socket.assigns.conversation_ids, conversation_ids, &Realtime.conversation_topic/1)
    resubscribe(socket.assigns.peer_ids, peer_ids, &Realtime.presence_topic/1)

    socket
    |> assign(:conversation_ids, conversation_ids)
    |> assign(:peer_ids, peer_ids)
  end

  defp resubscribe(previous, current, topic_for) do
    for id <- MapSet.difference(previous, current), do: Endpoint.unsubscribe(topic_for.(id))
    for id <- MapSet.difference(current, previous), do: Endpoint.subscribe(topic_for.(id))
  end

  # In the shape Phoenix.Presence clients expect: %{user_id => %{metas: [...]}}.
  defp presences_of(user_ids) do
    for user_id <- user_ids,
        %{metas: _metas} = presence <- [
          Presence.get_by_key(Realtime.presence_topic(user_id), user_id)
        ],
        into: %{} do
      {user_id, presence}
    end
  end

  defp flush_pending(socket, cursor \\ nil) do
    batch = Messaging.pending_batch(socket.assigns.device.id, cursor)

    Enum.each(batch.messages, &push(socket, "msg:new", MessageJSON.message(&1)))

    flushed_ids = Enum.reduce(batch.messages, socket.assigns.flushed_ids, &MapSet.put(&2, &1.id))
    socket = assign(socket, :flushed_ids, flushed_ids)

    if batch.next_cursor, do: flush_pending(socket, batch.next_cursor), else: socket
  end

  defp error_payload(%Ecto.Changeset{} = changeset) do
    fields = changeset.errors |> Keyword.keys() |> Enum.uniq()
    %{reason: "invalid_payload", fields: fields}
  end

  defp error_payload(retry_after) when is_integer(retry_after) do
    %{reason: "rate_limited", retry_after: retry_after}
  end

  defp error_payload(reason) when is_atom(reason), do: %{reason: reason}
end
