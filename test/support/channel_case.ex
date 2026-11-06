defmodule ChatServerWeb.ChannelCase do
  @moduledoc "Test case for channels, with a helper to connect a device and join its channel."

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import ChatServerWeb.ChannelCase
      import ChatServer.Fixtures

      alias ChatServer.Repo
      alias ChatServerWeb.{UserChannel, UserSocket}

      @endpoint ChatServerWeb.Endpoint

      defp connect_device(session, ip \\ {127, 0, 0, 1}) do
        connect(UserSocket, %{"token" => session.access_token},
          connect_info: %{peer_data: %{address: ip, port: 1234}, x_headers: []}
        )
      end

      defp join_device(session, ip \\ {127, 0, 0, 1}) do
        {:ok, socket} = connect_device(session, ip)

        {:ok, _reply, channel} =
          subscribe_and_join(socket, UserChannel, "user:#{session.user.id}")

        channel
      end
    end
  end

  setup tags do
    ChatServer.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc "Closes a channel as a dropped connection would, and waits for it to go offline."
  def disconnect(channel) do
    ref = Process.monitor(channel.channel_pid)
    Process.unlink(channel.channel_pid)
    Process.exit(channel.channel_pid, :shutdown)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      1_000 -> raise "channel did not stop"
    end

    wait_until_offline(channel.assigns.user.id, channel.assigns.device.id, 100)
  end

  defp wait_until_offline(_user_id, _device_id, 0), do: raise("device still shown as online")

  defp wait_until_offline(user_id, device_id, tries) do
    if device_id in ChatServer.Realtime.online_device_ids([user_id]) do
      Process.sleep(10)
      wait_until_offline(user_id, device_id, tries - 1)
    else
      :ok
    end
  end
end
