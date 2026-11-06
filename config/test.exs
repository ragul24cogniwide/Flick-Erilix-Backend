import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :chat_server, ChatServer.Repo,
  username: "postgres",
  password: "postgres",
  hostname: System.get_env("DB_HOST", "localhost"),
  database: "chat_server_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  # Concurrency tests check out several real connections at once.
  pool_size: max(System.schedulers_online() * 2, 20)

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :chat_server, ChatServerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "7O0FkGEG2rQu67VekNqgsE2FB/57EiZ9aC6Lwur2QQGf4GW7Z1tAyAfnl5XsBhGP",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
