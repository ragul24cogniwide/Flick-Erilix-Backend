defmodule ChatServerWeb.ReceiptsTest do
  use ChatServerWeb.ChannelCase

  import Ecto.Query

  alias ChatServer.Accounts
  alias ChatServer.Messaging.{Delivery, Message}

  setup do
    alice = session_fixture()
    bob = session_fixture()
    %{alice: alice, bob: bob, conversation: direct_fixture(alice, bob)}
  end

  defp delivery(message, session) do
    Repo.one!(
      from d in Delivery,
        where: d.message_id == ^message.id and d.recipient_device_id == ^session.device.id
    )
  end

  defp ack_delivered(channel, ids) do
    ref = push(channel, "msg:ack_delivered", %{"message_ids" => ids})
    assert_reply ref, :ok, %{count: count}
    count
  end

  defp ack_read(channel, conversation, message) do
    params = %{"conversation_id" => conversation.id, "up_to_message_id" => message.id}
    ref = push(channel, "msg:ack_read", params)
    assert_reply ref, :ok, %{count: count}
    count
  end

  defp stored_ciphertext(message), do: Repo.get!(Message, message.id).ciphertext

  describe "msg:ack_delivered" do
    test "sets delivered_at and sends the sender receipt:delivered", ctx do
      _alice = join_device(ctx.alice)
      bob = join_device(ctx.bob)
      message = message_fixture(ctx.alice, ctx.conversation)
      message_id = message.id
      bob_id = ctx.bob.user.id

      assert ack_delivered(bob, [message.id]) == 1

      assert_push "receipt:delivered", %{message_id: ^message_id, by_user_id: ^bob_id}
      assert delivery(message, ctx.bob).delivered_at
    end

    test "an acked message is not delivered again on reconnect", ctx do
      bob = join_device(ctx.bob)
      acked = message_fixture(ctx.alice, ctx.conversation)
      unacked = message_fixture(ctx.alice, ctx.conversation)
      acked_id = acked.id
      unacked_id = unacked.id

      assert_push "msg:new", %{message_id: ^acked_id}
      assert_push "msg:new", %{message_id: ^unacked_id}
      ack_delivered(bob, [acked.id])

      disconnect(bob)
      _bob = join_device(ctx.bob)

      assert_push "msg:new", %{message_id: ^unacked_id}
      refute_push "msg:new", %{message_id: ^acked_id}
    end

    test "a repeated ack sends no second receipt", ctx do
      _alice = join_device(ctx.alice)
      bob = join_device(ctx.bob)
      message = message_fixture(ctx.alice, ctx.conversation)
      message_id = message.id

      assert ack_delivered(bob, [message.id]) == 1
      assert_push "receipt:delivered", %{message_id: ^message_id}

      assert ack_delivered(bob, [message.id]) == 0
      refute_push "receipt:delivered", %{message_id: ^message_id}
    end

    test "acking another device's message changes nothing", ctx do
      outsider = session_fixture()
      _alice = join_device(ctx.alice)
      channel = join_device(outsider)
      message = message_fixture(ctx.alice, ctx.conversation)

      assert ack_delivered(channel, [message.id]) == 0

      refute delivery(message, ctx.bob).delivered_at
      refute_push "receipt:delivered", _payload
      assert stored_ciphertext(message)
    end

    test "acking from the sender's other device sends no tick", ctx do
      tablet = session_fixture(phone: ctx.alice.user.phone)
      _alice = join_device(ctx.alice)
      tablet_channel = join_device(tablet)
      message = message_fixture(ctx.alice, ctx.conversation)

      assert ack_delivered(tablet_channel, [message.id]) == 1

      refute_push "receipt:delivered", _payload
    end

    test "rejects malformed input", ctx do
      bob = join_device(ctx.bob)

      for params <- [%{}, %{"message_ids" => "x"}, %{"message_ids" => ["not-a-uuid"]}] do
        ref = push(bob, "msg:ack_delivered", params)
        assert_reply ref, :error, %{reason: "invalid_payload", fields: [:message_ids]}
      end

      too_many = List.duplicate(Ecto.UUID.generate(), 501)
      ref = push(bob, "msg:ack_delivered", %{"message_ids" => too_many})
      assert_reply ref, :error, %{reason: "invalid_payload"}
    end
  end

  describe "clearing ciphertext" do
    test "happens only once every recipient device has the message", ctx do
      phone = session_fixture(phone: ctx.bob.user.phone)
      tablet = join_device(phone)
      bob = join_device(ctx.bob)
      message = message_fixture(ctx.alice, ctx.conversation)

      ack_delivered(bob, [message.id])
      assert stored_ciphertext(message)

      ack_delivered(tablet, [message.id])
      refute stored_ciphertext(message)
    end

    test "keeps the metadata by default", ctx do
      bob = join_device(ctx.bob)
      message = message_fixture(ctx.alice, ctx.conversation)

      ack_delivered(bob, [message.id])

      stored = Repo.get!(Message, message.id)
      assert stored.sender_id == ctx.alice.user.id
      assert delivery(message, ctx.bob).delivered_at
    end

    test "deletes the whole row when configured to", ctx do
      Application.put_env(:chat_server, :delivered_message_retention, :delete_row)
      on_exit(fn -> Application.delete_env(:chat_server, :delivered_message_retention) end)

      bob = join_device(ctx.bob)
      message = message_fixture(ctx.alice, ctx.conversation)

      ack_delivered(bob, [message.id])

      refute Repo.get(Message, message.id)
      assert Repo.aggregate(Delivery, :count) == 0
    end

    test "a device logging out stops holding up the message and drops its queue", ctx do
      phone = session_fixture(phone: ctx.bob.user.phone)
      bob = join_device(ctx.bob)
      message = message_fixture(ctx.alice, ctx.conversation)
      ack_delivered(bob, [message.id])
      assert stored_ciphertext(message)

      :ok = Accounts.logout(phone.device)

      refute stored_ciphertext(message)
    end

    test "removing a member drops their queue, so nothing reaches them afterwards", ctx do
      group = group_fixture(ctx.alice, [ctx.bob])
      message = message_fixture(ctx.alice, group)
      message_id = message.id

      {:ok, _} =
        ChatServer.Conversations.remove_member(ctx.alice.user, group.id, ctx.bob.user.id)

      _bob = join_device(ctx.bob)

      refute_push "msg:new", %{message_id: ^message_id}
      refute stored_ciphertext(message)
    end
  end

  describe "msg:ack_read" do
    test "sets read_at up to the message and sends receipt:read", ctx do
      _alice = join_device(ctx.alice)
      bob = join_device(ctx.bob)
      first = message_fixture(ctx.alice, ctx.conversation)
      second = message_fixture(ctx.alice, ctx.conversation)
      third = message_fixture(ctx.alice, ctx.conversation)
      first_id = first.id
      second_id = second.id
      third_id = third.id
      bob_id = ctx.bob.user.id

      assert ack_read(bob, ctx.conversation, second) == 2

      assert_push "receipt:read", %{message_id: ^first_id, by_user_id: ^bob_id}
      assert_push "receipt:read", %{message_id: ^second_id, by_user_id: ^bob_id}
      refute_push "receipt:read", %{message_id: ^third_id}

      assert delivery(first, ctx.bob).read_at
      assert delivery(second, ctx.bob).read_at
      refute delivery(third, ctx.bob).read_at
    end

    test "implies delivery, so it also clears ciphertext", ctx do
      bob = join_device(ctx.bob)
      message = message_fixture(ctx.alice, ctx.conversation)

      ack_read(bob, ctx.conversation, message)

      assert delivery(message, ctx.bob).delivered_at
      refute stored_ciphertext(message)
    end

    test "still works after delivery cleared the ciphertext", ctx do
      _alice = join_device(ctx.alice)
      bob = join_device(ctx.bob)
      message = message_fixture(ctx.alice, ctx.conversation)
      message_id = message.id

      ack_delivered(bob, [message.id])
      assert ack_read(bob, ctx.conversation, message) == 1

      assert_push "receipt:read", %{message_id: ^message_id}
    end

    test "does not repeat a receipt", ctx do
      _alice = join_device(ctx.alice)
      bob = join_device(ctx.bob)
      message = message_fixture(ctx.alice, ctx.conversation)
      message_id = message.id

      assert ack_read(bob, ctx.conversation, message) == 1
      assert_push "receipt:read", %{message_id: ^message_id}

      assert ack_read(bob, ctx.conversation, message) == 0
      refute_push "receipt:read", %{message_id: ^message_id}
    end

    test "a non-member is refused", ctx do
      outsider = join_device(session_fixture())
      message = message_fixture(ctx.alice, ctx.conversation)

      ref =
        push(outsider, "msg:ack_read", %{
          "conversation_id" => ctx.conversation.id,
          "up_to_message_id" => message.id
        })

      assert_reply ref, :error, %{reason: :forbidden}
    end

    test "a message from another conversation is not found", ctx do
      carol = session_fixture()
      other = direct_fixture(ctx.alice, carol)
      elsewhere = message_fixture(ctx.alice, other)
      bob = join_device(ctx.bob)

      ref =
        push(bob, "msg:ack_read", %{
          "conversation_id" => ctx.conversation.id,
          "up_to_message_id" => elsewhere.id
        })

      assert_reply ref, :error, %{reason: :not_found}
    end

    test "rejects malformed input", ctx do
      bob = join_device(ctx.bob)

      ref = push(bob, "msg:ack_read", %{"conversation_id" => "x"})

      assert_reply ref, :error, %{reason: "invalid_payload"}
    end
  end
end
