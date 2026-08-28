# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :topics_club_gateway, :scopes,
  user: [
    default: true,
    module: TopicsClub.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: TopicsClub.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :topics_club_core,
  ecto_repos: [TopicsClub.Repo],
  engine_client_adapter: TopicsClub.Engine.LocalAdapter,
  internal_event_adapter: TopicsClubWeb.InternalEvents.Adapter,
  pubsub_pool_size: 1

config :topics_club_gateway,
  generators: [timestamp_type: :utc_datetime],
  discovery_refresh_enabled: config_env() == :dev

config :topics_club_engine,
  irc_bouncer_enabled: true

config :topics_club_engine, TopicsClub.EngineOban,
  name: TopicsClub.EngineOban,
  repo: TopicsClub.Repo,
  queues: [connection_deletions: 2, internal_events: 5],
  plugins: [],
  cron: [
    crontab: [
      {"* * * * *", TopicsClub.Chat.ConnectionDeletionReconcilerWorker}
    ]
  ]

config :topics_club_gateway, TopicsClubWeb.Oban,
  name: TopicsClubWeb.Oban,
  repo: TopicsClub.Repo,
  queues: [notifications: 5],
  plugins: [Oban.Plugins.Pruner]

# Configure the endpoint
config :topics_club_gateway, TopicsClubWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: TopicsClubWeb.ErrorHTML, json: TopicsClubWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: TopicsClub.PubSub,
  live_view: [signing_salt: "i3784qJX"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :topics_club_gateway, TopicsClub.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  topics_club: [
    args:
      ~w(js/app.ts --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/topics_club_gateway/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  topics_club: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/topics_club_gateway", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

oauth_providers =
  [
    google: {Ueberauth.Strategy.Google, [default_scope: "email profile"]}
  ] ++
    if config_env() in [:dev, :test] do
      [
        developer:
          {TopicsClubWeb.Auth.DevStrategy,
           [
             callback_methods: ["GET"],
             ignores_csrf_attack: true
           ]}
      ]
    else
      []
    end

config :ueberauth, Ueberauth, providers: oauth_providers

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
