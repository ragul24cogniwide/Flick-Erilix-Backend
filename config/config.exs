# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :chat_server,
  ecto_repos: [ChatServer.Repo],
  generators: [timestamp_type: :utc_datetime_usec, binary_id: true]

# SQL debug logs include bound parameters such as phone numbers and token hashes.
config :chat_server, ChatServer.Repo, log: false

# Replace with a real provider in production (see ChatServer.SmsProvider).
config :chat_server, :sms_provider, ChatServer.SmsProvider.Unconfigured

# Replace with a real provider in production (see ChatServer.PushProvider).
config :chat_server, :push_provider, ChatServer.PushProvider.Log

config :chat_server, Oban,
  repo: ChatServer.Repo,
  queues: [push: 20, maintenance: 1],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60},
    {Oban.Plugins.Cron, crontab: [{"0 3 * * *", ChatServer.Workers.Cleanup}]}
  ]

# scope: {max_hits, window_seconds}
config :chat_server, :rate_limits,
  request_otp_phone: {5, 3600},
  request_otp_ip: {100, 3600},
  verify_otp_phone: {10, 600},
  verify_otp_ip: {100, 600},
  msg_send_user: {120, 60},
  msg_send_ip: {1200, 60},
  contacts_match_user: {10, 60},
  keys_fetch_user: {30, 60}

# What happens to a message once every recipient device has it:
# :keep_metadata clears the ciphertext only, :delete_row removes the message.
config :chat_server, :delivered_message_retention, :keep_metadata

# Configure the endpoint
config :chat_server, ChatServerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: ChatServerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ChatServer.PubSub,
  live_view: [signing_salt: "PUHn09r3"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Never write secrets or personal data to the logs (SPEC section 8).
config :phoenix, :filter_parameters, [
  "phone",
  "code",
  "token",
  "ciphertext",
  "hashes",
  "public_key",
  "prekey",
  "signature"
]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
