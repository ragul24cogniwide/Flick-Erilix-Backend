defmodule ChatServer.LogRedactionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  defmodule Crasher do
    use GenServer

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_cast(payload, state), do: raise(ArgumentError, "bad: #{payload} #{state}")
  end

  test "a crash report names the error but not the state, message, or exception text" do
    log =
      capture_log(fn ->
        {:ok, pid} = GenServer.start(Crasher, "secret-state")
        ref = Process.monitor(pid)
        GenServer.cast(pid, "secret-message")
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
        Process.sleep(50)
      end)

    assert log =~ "terminating"
    assert log =~ "ArgumentError"
    refute log =~ "secret-state"
    refute log =~ "secret-message"
  end
end
