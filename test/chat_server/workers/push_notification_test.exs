defmodule ChatServer.Workers.PushNotificationTest do
  use ChatServerWeb.ChannelCase
  use Oban.Testing, repo: ChatServer.Repo

  import ExUnit.CaptureLog

  alias ChatServer.Accounts
  alias ChatServer.PushProvider
  alias ChatServer.Workers.PushNotification

  setup do
    alice = session_fixture()
    bob = session_fixture()
    {:ok, _device} = Accounts.update_push_token(bob.device, %{"push_token" => "bob-token"})
    %{alice: alice, bob: bob, conversation: direct_fixture(alice, bob)}
  end

  defp enqueued, do: all_enqueued(worker: PushNotification)

  describe "sending to an offline device" do
    test "enqueues a push holding only the device id", ctx do
      message_fixture(ctx.alice, ctx.conversation, %{"ciphertext" => Base.encode64("secret")})

      assert [job] = enqueued()
      assert job.args == %{"device_id" => ctx.bob.device.id}
    end

    test "the delivery stays pending for when the device returns", ctx do
      message = message_fixture(ctx.alice, ctx.conversation)
      message_id = message.id

      _bob = join_device(ctx.bob)

      assert_push "msg:new", %{message_id: ^message_id}
    end

    test "collapses a burst into one push", ctx do
      for _ <- 1..5, do: message_fixture(ctx.alice, ctx.conversation)

      assert [_one] = enqueued()
    end

    test "a retried send adds no push beyond the first", ctx do
      params = send_params(ctx.alice, ctx.conversation)

      {:ok, _, _} = ChatServer.Messaging.send_message(ctx.alice.user, ctx.alice.device, params)
      Repo.delete_all(Oban.Job)
      {:ok, _, _} = ChatServer.Messaging.send_message(ctx.alice.user, ctx.alice.device, params)

      assert enqueued() == []
    end
  end

  describe "sending to other devices" do
    test "an online device gets no push", ctx do
      _bob = join_device(ctx.bob)

      message_fixture(ctx.alice, ctx.conversation)

      assert enqueued() == []
    end

    test "a device gets a push again once it has gone offline", ctx do
      bob = join_device(ctx.bob)
      disconnect(bob)

      message_fixture(ctx.alice, ctx.conversation)

      assert [_job] = enqueued()
    end

    test "with two devices, only the offline one gets a push", ctx do
      tablet = session_fixture(phone: ctx.bob.user.phone)
      {:ok, _} = Accounts.update_push_token(tablet.device, %{"push_token" => "tablet-token"})
      _bob = join_device(ctx.bob)

      message_fixture(ctx.alice, ctx.conversation)

      assert [job] = enqueued()
      assert job.args == %{"device_id" => tablet.device.id}
    end

    test "a device with no push token gets no push", ctx do
      message_fixture(ctx.bob, ctx.conversation)

      assert enqueued() == []
    end
  end

  describe "perform/1" do
    test "sends a notification with no message content", ctx do
      message_fixture(ctx.alice, ctx.conversation, %{"ciphertext" => Base.encode64("secret")})

      assert :ok = perform_job(PushNotification, %{device_id: ctx.bob.device.id})

      assert_received {:push_sent, "bob-token", notification}
      assert notification == %{event: "new_message"}
    end

    test "sends nothing if the device has already caught up", ctx do
      bob = join_device(ctx.bob)
      message = message_fixture(ctx.alice, ctx.conversation)
      ref = push(bob, "msg:ack_delivered", %{"message_ids" => [message.id]})
      assert_reply ref, :ok, _reply

      assert :ok = perform_job(PushNotification, %{device_id: ctx.bob.device.id})

      refute_received {:push_sent, _token, _notification}
    end

    test "sends nothing if the device has logged out", ctx do
      message_fixture(ctx.alice, ctx.conversation)
      :ok = Accounts.logout(ctx.bob.device)

      assert :ok = perform_job(PushNotification, %{device_id: ctx.bob.device.id})

      refute_received {:push_sent, _token, _notification}
    end

    test "does nothing for a device that no longer exists" do
      assert :ok = perform_job(PushNotification, %{device_id: Ecto.UUID.generate()})
    end

    test "removes a dead token and does not retry", ctx do
      {:ok, _} = Accounts.update_push_token(ctx.bob.device, %{"push_token" => "dead"})
      message_fixture(ctx.alice, ctx.conversation)

      assert :ok = perform_job(PushNotification, %{device_id: ctx.bob.device.id})

      assert Repo.get!(Accounts.Device, ctx.bob.device.id).push_token == nil
    end

    test "reports provider failures so the job retries", ctx do
      {:ok, _} = Accounts.update_push_token(ctx.bob.device, %{"push_token" => "fail"})
      message_fixture(ctx.alice, ctx.conversation)

      assert {:error, :provider_down} =
               perform_job(PushNotification, %{device_id: ctx.bob.device.id})
    end
  end

  test "the logging provider does not log the token" do
    Logger.put_module_level(PushProvider.Log, :info)
    on_exit(fn -> Logger.delete_module_level(PushProvider.Log) end)

    log =
      capture_log([level: :info], fn ->
        assert :ok = PushProvider.Log.notify("secret-token", %{event: "new_message"})
      end)

    assert log =~ "new_message"
    refute log =~ "secret-token"
  end
end
