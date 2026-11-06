defmodule ChatServerWeb.MessagingFlowTest do
  use ChatServerWeb.ChannelCase

  alias ChatServer.Messaging.Message
  alias Phoenix.Socket.Broadcast

  setup do
    alice = session_fixture()
    bob = session_fixture()
    %{alice: alice, bob: bob, conversation: direct_fixture(alice, bob)}
  end

  defp new_messages_received(acc \\ []) do
    receive do
      %Phoenix.Socket.Message{event: "msg:new", payload: payload} ->
        new_messages_received([payload.message_id | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  describe "online delivery" do
    test "the sender gets a single-tick reply and the recipient gets the message", ctx do
      alice = join_device(ctx.alice)
      _bob = join_device(ctx.bob)
      bob_id = "user:#{ctx.bob.user.id}"
      ciphertext = Base.encode64("sealed")

      params = send_params(ctx.alice, ctx.conversation, %{"ciphertext" => ciphertext})
      ref = push(alice, "msg:send", params)

      assert_reply ref, :ok, %{message_id: message_id, server_ts: %DateTime{}}

      assert_receive %Phoenix.Socket.Message{
        event: "msg:new",
        topic: ^bob_id,
        payload: %{
          message_id: ^message_id,
          ciphertext: ^ciphertext,
          conversation_id: conversation_id,
          sender_id: sender_id,
          kind: :text
        }
      }

      assert conversation_id == ctx.conversation.id
      assert sender_id == ctx.alice.user.id
    end

    test "every device of the recipient gets it, and the sending device does not", ctx do
      second_bob = session_fixture(phone: ctx.bob.user.phone)
      alice = join_device(ctx.alice)
      _bob = join_device(ctx.bob)
      _second_bob = join_device(second_bob)

      ref = push(alice, "msg:send", send_params(ctx.alice, ctx.conversation))
      assert_reply ref, :ok, %{message_id: message_id}

      assert new_messages_received() == [message_id, message_id]
    end

    test "the sender's other device stays in sync", ctx do
      tablet = session_fixture(phone: ctx.alice.user.phone)
      alice = join_device(ctx.alice)
      _tablet = join_device(tablet)

      ref = push(alice, "msg:send", send_params(ctx.alice, ctx.conversation))
      assert_reply ref, :ok, %{message_id: message_id}

      assert new_messages_received() == [message_id]
    end

    test "group messages reach every member", ctx do
      carol = session_fixture()
      group = group_fixture(ctx.alice, [ctx.bob, carol])
      alice = join_device(ctx.alice)
      _bob = join_device(ctx.bob)
      _carol = join_device(carol)

      ref = push(alice, "msg:send", send_params(ctx.alice, group))
      assert_reply ref, :ok, %{message_id: message_id}

      assert new_messages_received() == [message_id, message_id]
    end
  end

  describe "per-device encryption" do
    test "each device receives only its own ciphertext", ctx do
      second_bob = session_fixture(phone: ctx.bob.user.phone)
      alice = join_device(ctx.alice)
      _bob = join_device(ctx.bob)
      _second_bob = join_device(second_bob)

      for_first = Base.encode64("for first device")
      for_second = Base.encode64("for second device")

      ref =
        push(
          alice,
          "msg:send",
          send_params(ctx.alice, ctx.conversation, %{
            "ciphertexts" => [
              %{"device_id" => ctx.bob.device.id, "ciphertext" => for_first},
              %{"device_id" => second_bob.device.id, "ciphertext" => for_second}
            ]
          })
        )

      assert_reply ref, :ok, _reply

      assert_push "msg:new", %{ciphertext: first}
      assert_push "msg:new", %{ciphertext: second}
      assert Enum.sort([first, second]) == Enum.sort([for_first, for_second])
    end

    test "an offline device gets its own ciphertext from the queue", ctx do
      alice = join_device(ctx.alice)
      mine = Base.encode64("for bob")

      ref =
        push(alice, "msg:send", send_params(ctx.alice, ctx.conversation, %{"ciphertext" => mine}))

      assert_reply ref, :ok, _reply

      _bob = join_device(ctx.bob)

      assert_push "msg:new", %{ciphertext: ^mine}
    end

    test "a stale device list is refused, naming what to fix, and stores nothing", ctx do
      alice = join_device(ctx.alice)
      params = send_params(ctx.alice, ctx.conversation)
      new_device = session_fixture(phone: ctx.bob.user.phone)

      ref = push(alice, "msg:send", params)

      assert_reply ref, :error, %{reason: "device_mismatch", missing: missing, extra: []}
      assert missing == [%{device_id: new_device.device.id, user_id: ctx.bob.user.id}]
      assert Repo.aggregate(Message, :count) == 0

      retry = push(alice, "msg:send", send_params(ctx.alice, ctx.conversation))
      assert_reply retry, :ok, _reply
    end

    test "a ciphertext for a device that left is refused as extra", ctx do
      alice = join_device(ctx.alice)
      params = send_params(ctx.alice, ctx.conversation)
      gone = ctx.bob.device.id
      :ok = ChatServer.Accounts.logout(ctx.bob.device)

      ref = push(alice, "msg:send", params)

      assert_reply ref, :error, %{reason: "device_mismatch", missing: [], extra: [^gone]}
    end

    test "retrying a sent message returns the original even if devices changed", ctx do
      alice = join_device(ctx.alice)
      params = send_params(ctx.alice, ctx.conversation)

      first = push(alice, "msg:send", params)
      assert_reply first, :ok, %{message_id: message_id}

      _new_device = session_fixture(phone: ctx.bob.user.phone)

      retry = push(alice, "msg:send", params)
      assert_reply retry, :ok, %{message_id: ^message_id}
    end
  end

  describe "offline queue" do
    test "messages wait for an offline device and arrive oldest first on reconnect", ctx do
      alice = join_device(ctx.alice)

      sent =
        for _ <- 1..5 do
          ref = push(alice, "msg:send", send_params(ctx.alice, ctx.conversation))
          assert_reply ref, :ok, %{message_id: message_id}
          message_id
        end

      assert new_messages_received() == []

      _bob = join_device(ctx.bob)

      assert new_messages_received() == sent
    end

    test "a device that drops offline receives what it missed", ctx do
      alice = join_device(ctx.alice)
      bob = join_device(ctx.bob)

      first = push(alice, "msg:send", send_params(ctx.alice, ctx.conversation))
      assert_reply first, :ok, %{message_id: first_id}
      assert new_messages_received() == [first_id]

      disconnect(bob)

      second = push(alice, "msg:send", send_params(ctx.alice, ctx.conversation))
      assert_reply second, :ok, %{message_id: second_id}
      assert new_messages_received() == []

      _bob = join_device(ctx.bob)

      # The first was never acked, so it comes again: delivery is at-least-once.
      assert new_messages_received() == [first_id, second_id]
    end

    test "the queue holds more than one batch", ctx do
      for _ <- 1..205, do: message_fixture(ctx.alice, ctx.conversation)

      _bob = join_device(ctx.bob)

      assert length(new_messages_received()) == 205
    end

    test "one device's queue does not affect another's", ctx do
      other = session_fixture()
      message_fixture(ctx.alice, ctx.conversation)

      _other = join_device(other)

      assert new_messages_received() == []
    end

    test "a live copy of a message already sent from the queue is not pushed again", ctx do
      message = message_fixture(ctx.alice, ctx.conversation)
      bob = join_device(ctx.bob)
      assert new_messages_received() == [message.id]

      send(bob.channel_pid, %Broadcast{
        event: "msg:new",
        payload: %{message_id: message.id},
        topic: "device:#{ctx.bob.device.id}"
      })

      assert new_messages_received() == []
    end
  end

  describe "retries" do
    test "a retried send returns the original result and delivers once", ctx do
      alice = join_device(ctx.alice)
      _bob = join_device(ctx.bob)
      params = send_params(ctx.alice, ctx.conversation)

      first = push(alice, "msg:send", params)
      assert_reply first, :ok, %{message_id: message_id, server_ts: server_ts}

      retry = push(alice, "msg:send", params)
      assert_reply retry, :ok, %{message_id: ^message_id, server_ts: ^server_ts}

      assert new_messages_received() == [message_id]
      assert Repo.aggregate(Message, :count) == 1
    end

    test "a retry while the recipient is offline queues one copy", ctx do
      alice = join_device(ctx.alice)
      params = send_params(ctx.alice, ctx.conversation)

      first = push(alice, "msg:send", params)
      assert_reply first, :ok, %{message_id: message_id}
      retry = push(alice, "msg:send", params)
      assert_reply retry, :ok, %{message_id: ^message_id}

      _bob = join_device(ctx.bob)

      assert new_messages_received() == [message_id]
    end

    test "concurrent retries create one message", ctx do
      params = send_params(ctx.alice, ctx.conversation)

      results =
        1..8
        |> Enum.map(fn _ ->
          Task.async(fn ->
            ChatServer.Messaging.send_message(ctx.alice.user, ctx.alice.device, params)
          end)
        end)
        |> Task.await_many()

      assert [message_id] =
               results |> Enum.map(fn {:ok, message, _} -> message.id end) |> Enum.uniq()

      assert Enum.count(results, fn {:ok, _, fan_out} -> not fan_out.duplicate? end) == 1
      assert Repo.get!(Message, message_id)
    end
  end

  describe "authorization on every event" do
    test "a non-member's send is refused", ctx do
      outsider = join_device(session_fixture())
      _bob = join_device(ctx.bob)

      ref = push(outsider, "msg:send", send_params(ctx.alice, ctx.conversation))

      assert_reply ref, :error, %{reason: :forbidden}
      assert new_messages_received() == []
      assert Repo.aggregate(Message, :count) == 0
    end

    test "a member removed while connected can no longer send", ctx do
      group = group_fixture(ctx.alice, [ctx.bob])
      bob = join_device(ctx.bob)

      first = push(bob, "msg:send", send_params(ctx.bob, group))
      assert_reply first, :ok, _reply

      {:ok, _} = ChatServer.Conversations.remove_member(ctx.alice.user, group.id, ctx.bob.user.id)

      second = push(bob, "msg:send", send_params(ctx.bob, group))
      assert_reply second, :error, %{reason: :forbidden}
    end
  end

  describe "payload validation" do
    test "a message over 64 KB is rejected", ctx do
      alice = join_device(ctx.alice)
      too_big = Base.encode64(:binary.copy(<<1>>, 64 * 1024 + 1))

      ref =
        push(
          alice,
          "msg:send",
          send_params(ctx.alice, ctx.conversation, %{"ciphertext" => too_big})
        )

      assert_reply ref, :error, %{reason: :message_too_large}
    end

    test "errors name the bad fields without echoing their values", ctx do
      alice = join_device(ctx.alice)

      ref =
        push(
          alice,
          "msg:send",
          send_params(ctx.alice, ctx.conversation, %{"ciphertext" => "not base64!"})
        )

      assert_reply ref, :error, %{reason: "invalid_payload", fields: [:ciphertexts]}
    end

    test "an unknown event gets an error, not a crash", ctx do
      alice = join_device(ctx.alice)

      ref = push(alice, "msg:delete", %{})

      assert_reply ref, :error, %{reason: "unknown_event"}
      assert Process.alive?(alice.channel_pid)
    end
  end

  describe "rate limits" do
    setup do
      limits = Application.fetch_env!(:chat_server, :rate_limits)
      on_exit(fn -> Application.put_env(:chat_server, :rate_limits, limits) end)
      %{limits: limits}
    end

    test "msg:send is limited per user", ctx do
      Application.put_env(
        :chat_server,
        :rate_limits,
        Keyword.put(ctx.limits, :msg_send_user, {1, 60})
      )

      alice = join_device(ctx.alice)

      first = push(alice, "msg:send", send_params(ctx.alice, ctx.conversation))
      assert_reply first, :ok, _reply

      second = push(alice, "msg:send", send_params(ctx.alice, ctx.conversation))
      assert_reply second, :error, %{reason: "rate_limited", retry_after: retry_after}
      assert retry_after in 1..60
    end

    test "msg:send is limited per IP", ctx do
      Application.put_env(
        :chat_server,
        :rate_limits,
        Keyword.put(ctx.limits, :msg_send_ip, {1, 60})
      )

      shared_ip = {203, 0, 113, 50}
      alice = join_device(ctx.alice, shared_ip)
      bob = join_device(ctx.bob, shared_ip)

      first = push(alice, "msg:send", send_params(ctx.alice, ctx.conversation))
      assert_reply first, :ok, _reply

      second = push(bob, "msg:send", send_params(ctx.bob, ctx.conversation))
      assert_reply second, :error, %{reason: "rate_limited"}
    end
  end
end
