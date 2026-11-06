defmodule ChatServer.PushProvider.Fcm.TokenCache do
  @moduledoc """
  Holds the Google access token, so push jobs share one instead of signing in each time.
  Callers wait in turn, so an expired token is only ever refreshed once.
  """

  use GenServer

  alias ChatServer.PushProvider.Fcm

  # Refresh a little early, so a token cannot expire while a request is in flight.
  @refresh_margin_seconds 60

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def fetch, do: GenServer.call(__MODULE__, :fetch, 30_000)

  def invalidate, do: GenServer.cast(__MODULE__, :invalidate)

  @impl true
  def init(nil), do: {:ok, nil}

  @impl true
  def handle_call(:fetch, _from, state) do
    now = System.system_time(:second)

    case state do
      %{token: token, refresh_at: refresh_at} when refresh_at > now ->
        {:reply, {:ok, token}, state}

      _missing_or_stale ->
        case Fcm.request_access_token() do
          {:ok, token, expires_in} ->
            refresh_at = now + expires_in - @refresh_margin_seconds
            {:reply, {:ok, token}, %{token: token, refresh_at: refresh_at}}

          {:error, _reason} = error ->
            {:reply, error, nil}
        end
    end
  end

  @impl true
  def handle_cast(:invalidate, _state), do: {:noreply, nil}
end
