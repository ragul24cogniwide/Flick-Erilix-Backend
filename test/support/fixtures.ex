defmodule ChatServer.Fixtures do
  @moduledoc "Test data builders."

  alias ChatServer.Accounts
  alias ChatServer.Accounts.Device
  alias ChatServer.{Conversations, Keys, Messaging}

  def unique_phone, do: "+1555#{System.unique_integer([:positive]) |> rem(10_000_000) |> pad()}"

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(7, "0")

  @doc """
  Signs in a new device and uploads its keys, which makes it a message recipient. Pass
  `phone:` to add a device to an existing user, or `keys: false` to skip the upload.
  """
  def session_fixture(opts \\ []) do
    phone = Keyword.get_lazy(opts, :phone, &unique_phone/0)
    device_changeset = Device.changeset(%Device{}, %{platform: :android})
    {:ok, session} = Accounts.start_session(phone, device_changeset)

    if Keyword.get(opts, :keys, true) do
      {:ok, _available} =
        Keys.upload_keys(session.device, %{
          "identity_public_key" => Base.encode64("identity"),
          "signed_prekey" => Base.encode64("signed"),
          "signed_prekey_signature" => Base.encode64("signature")
        })
    end

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

  @doc """
  Builds a valid `msg:send` for this sender, with a ciphertext per recipient device.
  Override `"ciphertext"` to use those bytes for every device.
  """
  def send_params(session, conversation, overrides \\ %{}) do
    {ciphertext, overrides} = Map.pop(overrides, "ciphertext", Base.encode64("opaque bytes"))

    ciphertexts =
      for {device_id, _user_id} <-
            Messaging.recipient_devices(conversation.id, session.device.id) do
        %{"device_id" => device_id, "ciphertext" => ciphertext}
      end

    Map.merge(
      %{
        "conversation_id" => conversation.id,
        "client_msg_id" => Ecto.UUID.generate(),
        "ciphertexts" => ciphertexts,
        "kind" => "text"
      },
      overrides
    )
  end

  def message_fixture(%{user: user, device: device} = session, conversation, overrides \\ %{}) do
    {:ok, message, _fan_out} =
      Messaging.send_message(user, device, send_params(session, conversation, overrides))

    message
  end
end
