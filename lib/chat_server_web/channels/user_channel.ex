defmodule ChatServerWeb.UserChannel do
  @moduledoc """
  One per connected device. Messages travel on a per-device PubSub topic so each
  device tracks its own delivery state, and receipts go on the shared `user:<id>` topic.
  """

  use Phoenix.Channel, log_join: false, log_handle_in: false

  alias ChatServer.{Messaging, RateLimiter, Realtime}
  alias ChatServerWeb.{Endpoint, MessageJSON, Presence}
  alias Phoenix.Socket.Broadcast

  @impl true
  def join("user:" <> user_id, _params, %{assigns: %{user: %{id: user_id}}} = socket) do
    # Subscribe before reading the queue, so no message can fall between the two.
    Endpoint.subscribe(Realtime.device_topic(socket.assigns.device.id))
    send(self(), :after_join)
    {:ok, assign(socket, :flushed_ids, MapSet.new())}
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

  def handle_in(_event, _params, socket) do
    {:reply, {:error, %{reason: "unknown_event"}}, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    {:ok, _ref} =
      Presence.track(
        self(),
        Realtime.presence_topic(socket.assigns.user.id),
        socket.assigns.user.id,
        %{device_id: socket.assigns.device.id, status: "online"}
      )

    {:noreply, flush_pending(socket)}
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

  defp flush_pending(socket, cursor \\ nil) do
    batch = Messaging.pending_batch(socket.assigns.device.id, cursor)

    Enum.each(batch.messages, &push(socket, "msg:new", MessageJSON.message(&1)))

    socket =
      update_in(socket.assigns.flushed_ids, fn flushed_ids ->
        Enum.reduce(batch.messages, flushed_ids, &MapSet.put(&2, &1.id))
      end)

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
