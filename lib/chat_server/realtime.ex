defmodule ChatServer.Realtime do
  @moduledoc "PubSub topics and live presence, so contexts need not know about channels."

  alias ChatServerWeb.{Endpoint, Presence}

  def device_topic(device_id), do: "device:#{device_id}"
  def user_channel_topic(user_id), do: "user:#{user_id}"
  def presence_topic(user_id), do: "presence:#{user_id}"
  def conversation_topic(conversation_id), do: "conversation:#{conversation_id}"

  defp membership_topic(user_id), do: "membership:#{user_id}"

  def subscribe_to_membership_changes(user_id) do
    Phoenix.PubSub.subscribe(ChatServer.PubSub, membership_topic(user_id))
  end

  @doc "Tells these users' open channels to reload their conversations and peers."
  def notify_membership_changed(user_ids) do
    Enum.each(user_ids, fn user_id ->
      Phoenix.PubSub.broadcast(ChatServer.PubSub, membership_topic(user_id), :membership_changed)
    end)
  end

  def broadcast_to_device(device_id, event, payload) do
    Endpoint.broadcast(device_topic(device_id), event, payload)
  end

  @doc "Sends an event to all of a user's connected devices."
  def broadcast_to_user(user_id, event, payload) do
    Endpoint.broadcast(user_channel_topic(user_id), event, payload)
  end

  @doc "Which of these users' devices have a socket open right now."
  def online_device_ids(user_ids) do
    for user_id <- user_ids,
        %{metas: metas} <- [Presence.get_by_key(presence_topic(user_id), user_id)],
        meta <- metas,
        into: MapSet.new() do
      meta.device_id
    end
  end
end
