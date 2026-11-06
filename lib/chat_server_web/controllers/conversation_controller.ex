defmodule ChatServerWeb.ConversationController do
  use ChatServerWeb, :controller

  alias ChatServer.{Conversations, Messaging}
  alias ChatServerWeb.MessageJSON

  action_fallback ChatServerWeb.FallbackController

  def create(conn, params) do
    with {:ok, conversation, status} <-
           Conversations.create_conversation(conn.assigns.current_user, params) do
      conn
      |> put_status(if status == :created, do: :created, else: :ok)
      |> json(conversation_json(conversation))
    end
  end

  def index(conn, _params) do
    summaries =
      Conversations.list_conversations(conn.assigns.current_user, conn.assigns.current_device)

    json(conn, %{
      conversations:
        Enum.map(summaries, fn summary ->
          summary.conversation
          |> conversation_json()
          |> Map.put(:last_message, last_message_json(summary.last_message))
          |> Map.put(:unread_count, summary.unread_count)
        end)
    })
  end

  def add_member(conn, %{"id" => id} = params) do
    with {:ok, conversation} <- Conversations.add_member(conn.assigns.current_user, id, params) do
      json(conn, conversation_json(conversation))
    end
  end

  def remove_member(conn, %{"id" => id, "user_id" => user_id}) do
    with {:ok, _conversation} <-
           Conversations.remove_member(conn.assigns.current_user, id, user_id) do
      send_resp(conn, :no_content, "")
    end
  end

  def messages(conn, %{"id" => id} = params) do
    with {:ok, messages, next_cursor} <-
           Messaging.list_messages(conn.assigns.current_user, id, params) do
      json(conn, %{
        messages: Enum.map(messages, &MessageJSON.message/1),
        next_cursor: next_cursor
      })
    end
  end

  defp conversation_json(conversation) do
    %{
      id: conversation.id,
      kind: conversation.kind,
      title: conversation.title,
      created_by: conversation.created_by,
      inserted_at: conversation.inserted_at,
      members:
        Enum.map(conversation.members, fn member ->
          %{
            user_id: member.user_id,
            display_name: member.user.display_name,
            role: member.role,
            joined_at: member.joined_at
          }
        end)
    }
  end

  defp last_message_json(nil), do: nil

  defp last_message_json(message) do
    %{
      message_id: message.id,
      sender_id: message.sender_id,
      kind: message.kind,
      server_ts: message.inserted_at
    }
  end
end
