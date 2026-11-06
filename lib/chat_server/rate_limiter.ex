defmodule ChatServer.RateLimiter do
  @moduledoc """
  A fixed-window rate limiter backed by ETS. Counts are per node.

  Limits are configured as `scope: {max_hits, window_seconds}` under
  `config :chat_server, :rate_limits`.
  """

  use GenServer

  @table __MODULE__
  @sweep_interval :timer.minutes(1)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Records one hit for each `{scope, key}` and returns the first limit that was exceeded."
  @spec check_all([{atom(), term()}]) :: :ok | {:error, retry_after_seconds :: pos_integer()}
  def check_all(checks) do
    Enum.reduce_while(checks, :ok, fn {scope, key}, :ok ->
      case check(scope, key) do
        :ok -> {:cont, :ok}
        {:error, _retry_after} = error -> {:halt, error}
      end
    end)
  end

  @spec check(atom(), term()) :: :ok | {:error, retry_after_seconds :: pos_integer()}
  def check(scope, key) do
    {max_hits, window} =
      Application.fetch_env!(:chat_server, :rate_limits) |> Keyword.fetch!(scope)

    now = System.system_time(:second)
    window_end = (div(now, window) + 1) * window
    counter = {scope, key, window_end}

    hits = :ets.update_counter(@table, counter, {2, 1}, {counter, 0, window_end})

    if hits <= max_hits, do: :ok, else: {:error, window_end - now}
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_sweep()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:second)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)
end
