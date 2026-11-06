defmodule ChatServer.Workers.CleanupTest do
  use ChatServer.DataCase, async: true
  use Oban.Testing, repo: ChatServer.Repo

  import ChatServer.Fixtures

  alias ChatServer.Accounts
  alias ChatServer.Accounts.{OtpCode, RefreshToken}
  alias ChatServer.Messaging.{Delivery, Message}
  alias ChatServer.Receipts
  alias ChatServer.Workers.Cleanup

  setup do
    alice = session_fixture()
    bob = session_fixture()
    %{alice: alice, bob: bob, conversation: direct_fixture(alice, bob)}
  end

  defp age_message(message, days) do
    aged = DateTime.add(DateTime.utc_now(), -days, :day)
    Repo.update_all(from(m in Message, where: m.id == ^message.id), set: [inserted_at: aged])
  end

  test "drops undelivered messages older than 30 days, with their deliveries", ctx do
    old = message_fixture(ctx.alice, ctx.conversation)
    age_message(old, 31)

    assert :ok = perform_job(Cleanup, %{})

    refute Repo.get(Message, old.id)
    assert Repo.aggregate(Delivery, :count) == 0
  end

  test "keeps undelivered messages younger than 30 days", ctx do
    recent = message_fixture(ctx.alice, ctx.conversation)
    age_message(recent, 29)

    assert :ok = perform_job(Cleanup, %{})

    assert Repo.get(Message, recent.id).ciphertext
  end

  test "keeps the metadata of old messages that were delivered", ctx do
    delivered = message_fixture(ctx.alice, ctx.conversation)

    {:ok, _ids} =
      Receipts.mark_delivered(ctx.bob.user, ctx.bob.device, %{"message_ids" => [delivered.id]})

    age_message(delivered, 31)

    assert :ok = perform_job(Cleanup, %{})

    assert Repo.get(Message, delivered.id)
  end

  test "drops a partly delivered message once it expires", ctx do
    second_bob = session_fixture(phone: ctx.bob.user.phone)
    partial = message_fixture(ctx.alice, ctx.conversation)

    {:ok, _ids} =
      Receipts.mark_delivered(ctx.bob.user, second_bob.device, %{"message_ids" => [partial.id]})

    age_message(partial, 31)

    assert :ok = perform_job(Cleanup, %{})

    refute Repo.get(Message, partial.id)
  end

  test "removes expired OTP codes and keeps live ones" do
    expired = unique_phone()
    live = unique_phone()
    :ok = Accounts.request_otp(expired)
    :ok = Accounts.request_otp(live)
    past = DateTime.add(DateTime.utc_now(), -1)
    Repo.update_all(from(o in OtpCode, where: o.phone == ^expired), set: [expires_at: past])

    assert :ok = perform_job(Cleanup, %{})

    assert Repo.all(from o in OtpCode, select: o.phone) == [live]
  end

  test "removes expired refresh tokens and keeps live ones", ctx do
    past = DateTime.add(DateTime.utc_now(), -1)

    Repo.update_all(from(r in RefreshToken, where: r.device_id == ^ctx.alice.device.id),
      set: [expires_at: past]
    )

    assert :ok = perform_job(Cleanup, %{})

    assert Repo.all(from r in RefreshToken, select: r.device_id) == [ctx.bob.device.id]
  end

  test "is scheduled daily" do
    plugins = Application.fetch_env!(:chat_server, Oban)[:plugins] || []

    assert {"0 3 * * *", Cleanup} =
             Enum.find_value(plugins, fn
               {Oban.Plugins.Cron, opts} -> List.first(opts[:crontab])
               _other -> nil
             end)
  end
end
