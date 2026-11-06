defmodule ChatServer.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    ChatServer.LogRedaction.install()
    warn_if_otp_exposed()

    children = [
      ChatServerWeb.Telemetry,
      ChatServer.Repo,
      {DNSCluster, query: Application.get_env(:chat_server, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ChatServer.PubSub},
      ChatServerWeb.Presence,
      ChatServer.RateLimiter,
      {Oban, Application.fetch_env!(:chat_server, Oban)},
      # Start to serve requests, typically the last entry
      ChatServerWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ChatServer.Supervisor]
    Supervisor.start_link(children ++ push_children(), opts)
  end

  defp warn_if_otp_exposed do
    if ChatServer.Accounts.expose_otp?() do
      Logger.warning(
        "INSECURE: DEV_MODE_EXPOSE_OTP is on. Anyone can sign in as any phone number. " <>
          "Turn it off before real users."
      )
    end
  end

  defp push_children do
    case Application.get_env(:chat_server, :push_provider) do
      ChatServer.PushProvider.Fcm -> [ChatServer.PushProvider.Fcm.TokenCache]
      _other -> []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ChatServerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
