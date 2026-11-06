defmodule ChatServer.Workers.Cleanup do
  @moduledoc "Runs daily: drops undelivered messages after 30 days and expired credentials."

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias ChatServer.{Accounts, Messaging}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Messaging.drop_expired_messages()
    Accounts.delete_expired_credentials()
    :ok
  end
end
