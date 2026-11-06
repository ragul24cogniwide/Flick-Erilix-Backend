defmodule ChatServerWeb.UserSocket do
  @moduledoc "The authenticated WebSocket. Logging is off because connect params hold the token."

  use Phoenix.Socket, log: false

  alias ChatServer.Accounts
  alias ChatServerWeb.ClientIp

  channel "user:*", ChatServerWeb.UserChannel

  @impl true
  def connect(%{"token" => token}, socket, connect_info) do
    case Accounts.authenticate(token) do
      {:ok, user, device} ->
        Accounts.touch_device(device)

        {:ok,
         socket
         |> assign(:user, user)
         |> assign(:device, device)
         |> assign(:client_ip, ClientIp.from_connect_info(connect_info))}

      {:error, :unauthorized} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: Accounts.socket_id(socket.assigns.device.id)
end
