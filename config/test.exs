import Config

config :topics_club_core, TopicsClub.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1",
       key: Base.decode64!("cLVEdS1Q2lCOQjU+YqgNwPjP9xsNwbpnXknH3P80MlU="),
       iv_length: 12}
  ]

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :topics_club_core, TopicsClub.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "topics_club_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :topics_club_gateway, TopicsClubWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "0b9bBqpbhnwgHDcBUh2E0VAxbRR6WmpBIV6oXXkFqEb4vx/LzOUfAmWBwaJRs0VQ",
  server: false

config :topics_club_engine,
  irc_bouncer_enabled: false,
  ingestion_claim_release_interval: :disabled

config :topics_club_engine, TopicsClub.EngineOban, testing: :manual, queues: false, plugins: false
config :topics_club_gateway, TopicsClubWeb.Oban, testing: :manual, queues: false, plugins: false

# In test we don't send emails
config :topics_club_gateway, TopicsClub.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
