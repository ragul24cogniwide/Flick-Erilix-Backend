defmodule ChatServer.Fixtures do
  @moduledoc "Test data builders."

  alias ChatServer.Accounts
  alias ChatServer.Accounts.Device

  def unique_phone, do: "+1555#{System.unique_integer([:positive]) |> rem(10_000_000) |> pad()}"

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(7, "0")

  @doc "Signs in a new device. Pass `phone:` to add a device to an existing user."
  def session_fixture(opts \\ []) do
    phone = Keyword.get_lazy(opts, :phone, &unique_phone/0)
    device_changeset = Device.changeset(%Device{}, %{platform: :android})
    {:ok, session} = Accounts.start_session(phone, device_changeset)
    session
  end
end
