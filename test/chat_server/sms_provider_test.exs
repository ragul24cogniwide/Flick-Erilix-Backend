defmodule ChatServer.SmsProviderTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ChatServer.SmsProvider.{Log, Unconfigured}

  test "the dev provider logs the code but not the full phone" do
    Logger.put_module_level(Log, :info)
    on_exit(fn -> Logger.delete_module_level(Log) end)

    log =
      capture_log([level: :info], fn -> assert :ok = Log.send_otp("+15551234567", "123456") end)

    assert log =~ "123456"
    assert log =~ "4567"
    refute log =~ "+15551234567"
  end

  test "the default provider refuses to send instead of leaking the code" do
    log =
      capture_log(fn ->
        assert {:error, :sms_provider_not_configured} = Unconfigured.send_otp("+15551234567", "1")
      end)

    assert log == ""
  end
end
