defmodule ChatServerWeb.MessageJSON do
  @moduledoc "The wire format of a message, shared by REST and the socket."

  def message(message) do
    %{
      message_id: message.id,
      conversation_id: message.conversation_id,
      sender_id: message.sender_id,
      sender_device_id: message.sender_device_id,
      client_msg_id: message.client_msg_id,
      ciphertext: Base.encode64(message.ciphertext),
      kind: message.kind,
      server_ts: message.inserted_at
    }
  end
end
