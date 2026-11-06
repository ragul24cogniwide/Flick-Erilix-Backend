defmodule ChatServerWeb.UserSocketTest do
  use ChatServerWeb.ChannelCase

  alias ChatServer.Accounts
  alias ChatServer.Accounts.Device

  test "connects with a valid token and records the device as seen" do
    session = session_fixture()
    Repo.update!(Ecto.Changeset.change(session.device, last_seen_at: nil))

    assert {:ok, socket} = connect_device(session)
    assert socket.assigns.user.id == session.user.id
    assert socket.assigns.device.id == session.device.id
    assert Repo.get!(Device, session.device.id).last_seen_at
  end

  test "refuses a missing, forged, or expired token" do
    %{user: user, device: device} = session_fixture()

    expired =
      Phoenix.Token.sign(
        @endpoint,
        "access token",
        %{user_id: user.id, device_id: device.id},
        signed_at: System.system_time(:second) - 901
      )

    for params <- [%{}, %{"token" => "forged"}, %{"token" => expired}] do
      assert :error = connect(UserSocket, params)
    end
  end

  test "refuses a logged-out device, and logging out closes its open sockets" do
    session = session_fixture()
    {:ok, socket} = connect_device(session)

    @endpoint.subscribe(UserSocket.id(socket))
    :ok = Accounts.logout(session.device)

    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    assert :error = connect_device(session)
  end

  test "cannot join another user's channel" do
    session = session_fixture()
    other = session_fixture()
    {:ok, socket} = connect_device(session)

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, UserChannel, "user:#{other.user.id}")
  end
end
