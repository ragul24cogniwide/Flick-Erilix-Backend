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

  defp stored_ciphertext(message, session) do
    Repo.one!(
      from d in Delivery,
        where: d.message_id == ^message.id and d.recipient_device_id == ^session.device.id,
        select: d.ciphertext
    )
  end

  defp for_bob(ctx, encoded) do
    %{"ciphertexts" => [%{"device_id" => ctx.bob.device.id, "ciphertext" => encoded}]}
  end

  describe "send_message/3" do
    test "stores one delivery and ciphertext per recipient device", ctx do
      second_bob = session_fixture(phone: ctx.bob.user.phone)

      params =
        send_params(ctx.alice, ctx.conversation, %{
          "ciphertexts" => [
            %{"device_id" => ctx.bob.device.id, "ciphertext" => Base.encode64("one")},
            %{"device_id" => second_bob.device.id, "ciphertext" => Base.encode64("two")}
          ]
        })

      assert {:ok, message, %{duplicate?: false}} = send_as(ctx.alice, params)

      assert stored_ciphertext(message, ctx.bob) == "one"
      assert stored_ciphertext(message, second_bob) == "two"
    end

    test "includes the sender's other devices but not the sending one", ctx do
      alice_tablet = session_fixture(phone: ctx.alice.user.phone)

      {:ok, message, _fan_out} = send_as(ctx.alice, send_params(ctx.alice, ctx.conversation))

      assert alice_tablet.device.id in deliveries(message)
      refute ctx.alice.device.id in deliveries(message)
    end

    test "skips devices that have logged out", ctx do
      :ok = ChatServer.Accounts.logout(ctx.bob.device)

      {:ok, message, %{recipient_device_ids: []}} =
        send_as(ctx.alice, send_params(ctx.alice, ctx.conversation))

      assert deliveries(message) == []
    end

    test "skips devices with no uploaded keys, since they cannot be encrypted for", ctx do
      _no_keys = session_fixture(phone: ctx.bob.user.phone, keys: false)

      {:ok, message, _fan_out} = send_as(ctx.alice, send_params(ctx.alice, ctx.conversation))

      assert deliveries(message) == [ctx.bob.device.id]
    end

    test "rejects a sender who is not a member", ctx do
      outsider = session_fixture()

      assert {:error, :forbidden} =
               send_as(outsider, send_params(outsider, ctx.conversation))

      assert Repo.aggregate(Message, :count) == 0
    end

    test "rejects a conversation that does not exist", ctx do
      params = %{"conversation_id" => Ecto.UUID.generate()}

      assert {:error, :forbidden} =
               send_as(ctx.alice, send_params(ctx.alice, ctx.conversation, params))
    end

    test "accepts exactly 64 KB per device and rejects one byte more", ctx do
      fits = Base.encode64(:binary.copy(<<0>>, 64 * 1024))
      too_big = Base.encode64(:binary.copy(<<0>>, 64 * 1024 + 1))

      assert {:ok, _message, _fan_out} =
               send_as(ctx.alice, send_params(ctx.alice, ctx.conversation, for_bob(ctx, fits)))

      assert {:error, :message_too_large} =
               send_as(ctx.alice, send_params(ctx.alice, ctx.conversation, for_bob(ctx, too_big)))
    end

    test "rejects more than 3 MiB across all devices", ctx do
      copy = Base.encode64(:binary.copy(<<0>>, 64 * 1024))

      ciphertexts =
        for _ <- 1..49, do: %{"device_id" => Ecto.UUID.generate(), "ciphertext" => copy}

      assert {:error, :message_too_large} =
               send_as(
                 ctx.alice,
                 send_params(ctx.alice, ctx.conversation, %{"ciphertexts" => ciphertexts})
               )
    end

    test "stores arbitrary bytes untouched", ctx do
      bytes = :crypto.strong_rand_bytes(256)

      {:ok, message, _fan_out} =
        send_as(
          ctx.alice,
          send_params(ctx.alice, ctx.conversation, %{"ciphertext" => Base.encode64(bytes)})
        )

      assert stored_ciphertext(message, ctx.bob) == bytes
    end

    test "rejects invalid payloads", ctx do
      invalid = [
        %{"ciphertext" => "not base64!"},
        %{"ciphertext" => ""},
        %{"ciphertext" => 123},
        %{"ciphertexts" => "nope"},
        %{"ciphertexts" => ["nope"]},
        %{"ciphertexts" => nil},
        %{"ciphertexts" => [%{"device_id" => "not-a-uuid", "ciphertext" => "AAAA"}]},
        %{"ciphertexts" => [%{"ciphertext" => "AAAA"}]},
        %{"ciphertexts" => [%{"device_id" => ctx.bob.device.id}]},
        %{
          "ciphertexts" => [
            %{"device_id" => ctx.bob.device.id, "ciphertext" => "AAAA"},
            %{"device_id" => ctx.bob.device.id, "ciphertext" => "BBBB"}
          ]
        },
        %{"kind" => "system"},
        %{"kind" => "video"},
        %{"client_msg_id" => ""},
        %{"client_msg_id" => String.duplicate("x", 65)},
        %{"conversation_id" => "not-a-uuid"}
      ]

      for overrides <- invalid do
        assert {:error, %Ecto.Changeset{}} =
                 send_as(ctx.alice, send_params(ctx.alice, ctx.conversation, overrides)),
               "expected #{inspect(overrides)} to be rejected"
      end

      assert Repo.aggregate(Message, :count) == 0
    end

    test "a missing device is reported with its user, and nothing is stored", ctx do
      new_device = session_fixture(phone: ctx.bob.user.phone)

      assert {:error, {:device_mismatch, %{missing: missing, extra: []}}} =
               send_as(ctx.alice, send_params(ctx.alice, ctx.conversation, for_bob(ctx, "AAAA")))

      assert missing == [%{device_id: new_device.device.id, user_id: ctx.bob.user.id}]
      assert Repo.aggregate(Message, :count) == 0
    end

    test "an unknown device is reported as extra, and nothing is stored", ctx do
      unknown = Ecto.UUID.generate()

      ciphertexts = [
        %{"device_id" => ctx.bob.device.id, "ciphertext" => "AAAA"},
        %{"device_id" => unknown, "ciphertext" => "AAAA"}
      ]

      assert {:error, {:device_mismatch, %{missing: [], extra: [^unknown]}}} =
               send_as(
                 ctx.alice,
                 send_params(ctx.alice, ctx.conversation, %{"ciphertexts" => ciphertexts})
               )

      assert Repo.aggregate(Message, :count) == 0
    end

    test "a retried client_msg_id returns the original and adds nothing", ctx do
      params = send_params(ctx.alice, ctx.conversation)

      {:ok, original, %{duplicate?: false}} = send_as(ctx.alice, params)
      {:ok, retried, %{duplicate?: true}} = send_as(ctx.alice, params)

      assert retried.id == original.id
      assert retried.inserted_at == original.inserted_at
      assert Repo.aggregate(Message, :count) == 1
      assert length(deliveries(original)) == 1
    end

    test "different senders may reuse a client_msg_id", ctx do
      id = %{"client_msg_id" => "same-id"}

      {:ok, first, %{duplicate?: false}} =
        send_as(ctx.alice, send_params(ctx.alice, ctx.conversation, id))

      {:ok, second, %{duplicate?: false}} =
        send_as(ctx.bob, send_params(ctx.bob, ctx.conversation, id))

      assert first.id != second.id
    end
  end
end
