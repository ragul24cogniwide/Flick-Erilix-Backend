defmodule ChatServer.Fixtures do
  @moduledoc "Test data builders."

  alias ChatServer.Accounts
  alias ChatServer.Accounts.Device
  alias ChatServer.{Conversations, Messaging}

  def unique_phone, do: "+1555#{System.unique_integer([:positive]) |> rem(10_000_000) |> pad()}"

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(7, "0")

  @doc "Signs in a new device. Pass `phone:` to add a device to an existing user."
  def session_fixture(opts \\ []) do
    phone = Keyword.get_lazy(opts, :phone, &unique_phone/0)
    device_changeset = Device.changeset(%Device{}, %{platform: :android})
    {:ok, session} = Accounts.start_session(phone, device_changeset)
    session
  end

  def direct_fixture(%{user: user}, %{user: peer}) do
    {:ok, conversation, _status} =
      Conversations.create_conversation(user, %{"kind" => "direct", "user_id" => peer.id})

    conversation
  end

  def group_fixture(%{user: admin}, others) do
    {:ok, conversation, _status} =
      Conversations.create_conversation(admin, %{
        "kind" => "group",
        "title" => "Group",
        "member_ids" => Enum.map(others, & &1.user.id)
      })

    conversation
  end

  def send_params(conversation, overrides \\ %{}) do
    Map.merge(
      %{
        "conversation_id" => conversation.id,
        "client_msg_id" => Ecto.UUID.generate(),
        "ciphertext" => Base.encode64("opaque bytes"),
        "kind" => "text"
      },
      overrides
    )
  end

  def message_fixture(%{user: user, device: device}, conversation, overrides \\ %{}) do
    {:ok, message, _fan_out} =
      Messaging.send_message(user, device, send_params(conversation, overrides))

    message
  end
end
