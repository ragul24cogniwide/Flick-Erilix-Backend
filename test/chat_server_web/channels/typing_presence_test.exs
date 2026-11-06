defmodule ChatServerWeb.TypingPresenceTest do
  use ChatServerWeb.ChannelCase

  alias ChatServer.Conversations

  setup do
    alice = session_fixture()
    bob = session_fixture()
    %{alice: alice, bob: bob, conversation: direct_fixture(alice, bob)}
  end

  # Reports every database query from any process to the test.
  defp watch_queries do
    test_pid = self()
    handler = "watch-queries-#{inspect(make_ref())}"

    :telemetry.attach(
      handler,
      [:chat_server, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:db_query, metadata.query})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp typing_params(conversation), do: %{"conversation_id" => conversation.id}

  # A round trip through the channel, proving it has handled everything sent before.
  defp sync(channel) do
    ref = push(channel, "presence:update", %{"status" => "online"})
    assert_reply ref, :ok, _reply
  end

  describe "typing" do
    test "reaches the other members with the state", ctx do
      alice = join_device(ctx.alice)
      _bob = join_device(ctx.bob)
      conversation_id = ctx.conversation.id
      alice_id = ctx.alice.user.id

      push(alice, "typing:start", typing_params(ctx.conversation))

      assert_push "typing", %{
        conversation_id: ^conversation_id,
        user_id: ^alice_id,
        state: "start"
      }

      push(alice, "typing:stop", typing_params(ctx.conversation))

      assert_push "typing", %{conversation_id: ^conversation_id, state: "stop"}
    end

    test "is not sent to the typist's own devices", ctx do
      tablet = session_fixture(phone: ctx.alice.user.phone)
      alice = join_device(ctx.alice)
      _tablet = join_device(tablet)

      push(alice, "typing:start", typing_params(ctx.conversation))

      refute_push "typing", _payload
    end

    test "does not reach people outside the conversation", ctx do
      alice = join_device(ctx.alice)
      _outsider = join_device(session_fixture())

      push(alice, "typing:start", typing_params(ctx.conversation))

      refute_push "typing", _payload
    end

    test "is refused for a non-member", ctx do
      outsider = join_device(session_fixture())
      _bob = join_device(ctx.bob)

      ref = push(outsider, "typing:start", typing_params(ctx.conversation))

      assert_reply ref, :error, %{reason: :forbidden}
      refute_push "typing", _payload
    end

    test "is refused as soon as a member is removed, without reconnecting", ctx do
      group = group_fixture(ctx.alice, [ctx.bob])
      bob = join_device(ctx.bob)

      {:ok, _} = Conversations.remove_member(ctx.alice.user, group.id, ctx.bob.user.id)
      sync(bob)

      ref = push(bob, "typing:start", typing_params(group))
      assert_reply ref, :error, %{reason: :forbidden}
    end

    test "works in a conversation created after joining", ctx do
      carol = session_fixture()
      alice = join_device(ctx.alice)
      carol_channel = join_device(carol)
      conversation = direct_fixture(ctx.alice, carol)
      conversation_id = conversation.id
      sync(alice)
      sync(carol_channel)

      push(alice, "typing:start", typing_params(conversation))

      assert_push "typing", %{conversation_id: ^conversation_id}
    end

    test "rejects malformed input", ctx do
      alice = join_device(ctx.alice)

      for params <- [%{}, %{"conversation_id" => %{"a" => "b"}}] do
        ref = push(alice, "typing:start", params)
        assert_reply ref, :error, _reason
      end
    end

    test "never touches the database", ctx do
      alice = join_device(ctx.alice)
      bob = join_device(ctx.bob)
      # Both channels finish their post-join queue read before queries are watched.
      sync(alice)
      sync(bob)

      watch_queries()

      push(alice, "typing:start", typing_params(ctx.conversation))
      push(alice, "typing:stop", typing_params(ctx.conversation))
      ref = push(alice, "typing:start", typing_params(session_conversation()))
      assert_reply ref, :error, %{reason: :forbidden}

      assert_push "typing", %{state: "start"}
      assert_push "typing", %{state: "stop"}

      refute_received {:db_query, _query}
    end
  end

  # An id the user is not a member of, without creating anything while queries are watched.
  defp session_conversation, do: %{id: Ecto.UUID.generate()}

  describe "presence" do
    test "joining lists online peers", ctx do
      _bob = join_device(ctx.bob)
      assert_push "presence_state", _bob_view

      _alice = join_device(ctx.alice)
      bob_id = ctx.bob.user.id
      bob_device = ctx.bob.device.id

      assert_push "presence_state", %{^bob_id => %{metas: [meta]}}
      assert %{device_id: ^bob_device, status: "online"} = meta
    end

    test "a peer coming online and going offline produces diffs", ctx do
      _alice = join_device(ctx.alice)
      assert_push "presence_state", _

      bob = join_device(ctx.bob)
      bob_id = ctx.bob.user.id

      assert_push "presence_diff", %{joins: %{^bob_id => _}, leaves: leaves}
      assert leaves == %{}

      disconnect(bob)

      assert_push "presence_diff", %{leaves: %{^bob_id => _}}
    end

    test "presence:update tells peers the new status", ctx do
      _alice = join_device(ctx.alice)
      bob = join_device(ctx.bob)
      bob_id = ctx.bob.user.id
      assert_push "presence_diff", %{joins: %{^bob_id => _}}

      ref = push(bob, "presence:update", %{"status" => "away"})
      assert_reply ref, :ok, %{status: "away"}

      assert_push "presence_diff", %{joins: %{^bob_id => %{metas: [%{status: "away"}]}}}
    end

    test "presence:update rejects an unknown status", ctx do
      alice = join_device(ctx.alice)

      ref = push(alice, "presence:update", %{"status" => "invisible"})

      assert_reply ref, :error, %{reason: "invalid_status"}
    end

    test "people with no shared conversation see nothing", ctx do
      _outsider = join_device(session_fixture())
      assert_push "presence_state", state
      assert state == %{}

      _alice = join_device(ctx.alice)

      refute_push "presence_diff", _payload
    end

    test "a new conversation partner appears, and a removed one disappears", ctx do
      carol = session_fixture()
      carol_id = carol.user.id
      _carol = join_device(carol)
      alice = join_device(ctx.alice)

      group = group_fixture(ctx.alice, [carol])
      assert_push "presence_diff", %{joins: %{^carol_id => _}}

      {:ok, _} = Conversations.remove_member(ctx.alice.user, group.id, carol_id)
      assert_push "presence_diff", %{leaves: %{^carol_id => _}}

      sync(alice)
    end

    test "status changes never touch the database", ctx do
      alice = join_device(ctx.alice)
      bob = join_device(ctx.bob)
      sync(alice)
      sync(bob)
      assert_push "presence_diff", %{joins: _}

      watch_queries()

      ref = push(alice, "presence:update", %{"status" => "away"})
      assert_reply ref, :ok, _reply
      assert_push "presence_diff", %{joins: _}

      refute_received {:db_query, _query}
    end
  end
end
