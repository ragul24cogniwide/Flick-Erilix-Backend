defmodule ChatServer.Workers.PushNotification do
  @moduledoc """
  Wakes one offline device. The job holds only a device id. Jobs for a device within
  a short window collapse into one, so a burst of messages sends a single push.
  """

  use Oban.Worker,
    queue: :push,
    max_attempts: 5,
    unique: [period: 30, keys: [:device_id], states: [:available, :scheduled, :retryable]]

  import Ecto.Query

  alias ChatServer.Accounts.Device
  alias ChatServer.{Messaging, PushProvider, Repo}

  @doc "Enqueues a push for each of these devices that has registered a push token."
  def enqueue(device_ids) do
    tokened_ids =
      Repo.all(
        from d in Device,
          where: d.id in ^Enum.to_list(device_ids) and not is_nil(d.push_token),
          select: d.id
      )

    Enum.each(tokened_ids, fn device_id ->
      {:ok, _job} = %{device_id: device_id} |> new() |> Oban.insert()
    end)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"device_id" => device_id}}) do
    with %Device{push_token: token} when is_binary(token) <- Repo.get(Device, device_id),
         # The device may have reconnected, or logged out, since this was enqueued.
         true <- Messaging.device_has_pending?(device_id) do
      PushProvider.notify(token, %{event: "new_message"})
    else
      _nothing_to_do -> :ok
    end
  end
end
