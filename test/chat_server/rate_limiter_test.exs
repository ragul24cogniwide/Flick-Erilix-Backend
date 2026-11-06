defmodule ChatServer.RateLimiterTest do
  use ExUnit.Case, async: false

  alias ChatServer.RateLimiter

  setup do
    limits = Application.fetch_env!(:chat_server, :rate_limits)
    Application.put_env(:chat_server, :rate_limits, Keyword.put(limits, :msg_send_user, {2, 60}))
    on_exit(fn -> Application.put_env(:chat_server, :rate_limits, limits) end)
    :ok
  end

  test "allows hits up to the limit, then reports when to retry" do
    key = make_ref()

    assert :ok = RateLimiter.check(:msg_send_user, key)
    assert :ok = RateLimiter.check(:msg_send_user, key)
    assert {:error, retry_after} = RateLimiter.check(:msg_send_user, key)
    assert retry_after in 1..60
  end

  test "counts each key separately" do
    key = make_ref()

    assert :ok = RateLimiter.check(:msg_send_user, key)
    assert :ok = RateLimiter.check(:msg_send_user, key)
    assert :ok = RateLimiter.check(:msg_send_user, make_ref())
  end
end
