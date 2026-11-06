defmodule ChatServer.MessagingTest do
  use ChatServer.DataCase, async: true

  import ChatServer.Fixtures

  alias ChatServer.Messaging
  alias ChatServer.Messaging.{Delivery, Message}

  setup do
    alice = session_fixture()
    bob = session_fixture()
    %{alice: alice, bob: bob, conversation: direct_fixture(alice, bob)}
  end

  defp send_as(session, params), do: Messaging.send_message(session.user, session.device, params)

  defp deliveries(message) do
    Repo.all(
      from d in Delivery, where: d.message_id == ^message.id, select: d.recipient_device_id
    )
  end

  describe "send_message/3" do
    test "stores the message and one delivery per recipient device", ctx do
      bob_phone_device = session_fixture(phone: ctx.bob.user.phone)

      assert {:ok, message, %{duplicate?: false}} =
               send_as(ctx.alice, send_params(ctx.conversation))

      assert message.ciphertext == "opaque bytes"

      assert Enum.sort(deliveries(message)) ==
               Enum.sort([ctx.bob.device.id, bob_phone_device.device.id])
    end

    test "includes the sender's other devices but not the sending one", ctx do
      alice_tablet = session_fixture(phone: ctx.alice.user.phone)

      {:ok, message, _fan_out} = send_as(ctx.alice, send_params(ctx.conversation))

      assert alice_tablet.device.id in deliveries(message)
      refute ctx.alice.device.id in deliveries(message)
    end

    test "skips devices that have logged out", ctx do
      :ok = ChatServer.Accounts.logout(ctx.bob.device)

      {:ok, message, %{recipient_device_ids: []}} =
        send_as(ctx.alice, send_params(ctx.conversation))

      assert deliveries(message) == []
    end

    test "rejects a sender who is not a member", ctx do
      outsider = session_fixture()

      assert {:error, :forbidden} = send_as(outsider, send_params(ctx.conversation))
      assert Repo.aggregate(Message, :count) == 0
    end

    test "rejects a conversation that does not exist", ctx do
      params = %{"conversation_id" => Ecto.UUID.generate()}

      assert {:error, :forbidden} =
               send_as(ctx.alice, send_params(ctx.conversation, params))
    end

    test "accepts exactly 64 KB and rejects one byte more", ctx do
      fits = Base.encode64(:binary.copy(<<0>>, 64 * 1024))
      too_big = Base.encode64(:binary.copy(<<0>>, 64 * 1024 + 1))

      assert {:ok, _message, _fan_out} =
               send_as(ctx.alice, send_params(ctx.conversation, %{"ciphertext" => fits}))

      assert {:error, :message_too_large} =
               send_as(ctx.alice, send_params(ctx.conversation, %{"ciphertext" => too_big}))
    end

    test "stores arbitrary bytes untouched", ctx do
      bytes = :crypto.strong_rand_bytes(256)

      {:ok, message, _fan_out} =
        send_as(ctx.alice, send_params(ctx.conversation, %{"ciphertext" => Base.encode64(bytes)}))

      assert Repo.get!(Message, message.id).ciphertext == bytes
    end

    test "rejects invalid payloads", ctx do
      invalid = [
        %{"ciphertext" => "not base64!"},
        %{"ciphertext" => ""},
        %{"ciphertext" => 123},
        %{"kind" => "system"},
        %{"kind" => "video"},
        %{"client_msg_id" => ""},
        %{"client_msg_id" => String.duplicate("x", 65)},
        %{"conversation_id" => "not-a-uuid"}
      ]

      for overrides <- invalid do
        assert {:error, %Ecto.Changeset{}} =
                 send_as(ctx.alice, send_params(ctx.conversation, overrides)),
               "expected #{inspect(overrides)} to be rejected"
      end
    end

    test "a retried client_msg_id returns the original and adds nothing", ctx do
      params = send_params(ctx.conversation)

      {:ok, original, %{duplicate?: false}} = send_as(ctx.alice, params)
      {:ok, retried, %{duplicate?: true}} = send_as(ctx.alice, params)

      assert retried.id == original.id
      assert retried.inserted_at == original.inserted_at
      assert Repo.aggregate(Message, :count) == 1
      assert length(deliveries(original)) == 1
    end

    test "different senders may reuse a client_msg_id", ctx do
      id = %{"client_msg_id" => "same-id"}

      {:ok, first, %{duplicate?: false}} = send_as(ctx.alice, send_params(ctx.conversation, id))
      {:ok, second, %{duplicate?: false}} = send_as(ctx.bob, send_params(ctx.conversation, id))

      assert first.id != second.id
    end
  end
end
