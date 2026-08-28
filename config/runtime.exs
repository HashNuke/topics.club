import Config

release_name = System.get_env("RELEASE_NAME")

if config_env() == :prod and release_name not in [nil, "ircpipe", "ircpipe_web", "ircpipe_engine"] do
  raise "unsupported release name: #{inspect(release_name)}"
end

web_capable? = release_name != "ircpipe_engine"

if config_env() == :prod do
  case release_name do
    "ircpipe_web" ->
      config :ircpipe_core,
        engine_client_adapter: Ircpipe.EngineClient.RpcAdapter,
        internal_event_adapter: IrcpipeWeb.InternalEvents.Adapter

    "ircpipe_engine" ->
      config :ircpipe_core,
        engine_client_adapter: Ircpipe.Engine.LocalAdapter,
        internal_event_adapter: nil

    _combined_or_mix ->
      config :ircpipe_core,
        engine_client_adapter: Ircpipe.Engine.LocalAdapter,
        internal_event_adapter: IrcpipeWeb.InternalEvents.Adapter
  end
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/ircpipe start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if web_capable? and System.get_env("PHX_SERVER") do
  config :ircpipe_web, IrcpipeWeb.Endpoint, server: true
end

if web_capable? do
  config :ueberauth, Ueberauth.Strategy.Google.OAuth,
    client_id: System.get_env("GOOGLE_CLIENT_ID"),
    client_secret: System.get_env("GOOGLE_CLIENT_SECRET")

  smtp_relay = System.get_env("SMTP_RELAY")
  smtp_username = System.get_env("SMTP_USERNAME")
  smtp_password = System.get_env("SMTP_PASSWORD")

  smtp_tls =
    case System.get_env("SMTP_TLS") || "if_available" do
      "always" -> :always
      "never" -> :never
      _ -> :if_available
    end

  if smtp_relay && smtp_username && smtp_password do
    config :ircpipe_web, Ircpipe.Mailer,
      adapter: Swoosh.Adapters.SMTP,
      relay: smtp_relay,
      port: String.to_integer(System.get_env("SMTP_PORT") || "587"),
      username: smtp_username,
      password: smtp_password,
      ssl: System.get_env("SMTP_SSL") in ~w(true 1),
      tls: smtp_tls,
      auth: :always
  end

  config :ircpipe_web, :email_from,
    name: System.get_env("EMAIL_FROM_NAME") || "Ircpipe",
    address: System.get_env("EMAIL_FROM_ADDRESS") || "contact@example.com"

  vapid_subject =
    case System.get_env("VAPID_SUBJECT") do
      nil -> nil
      subject when subject == "" -> nil
      subject -> if String.contains?(subject, ":"), do: subject, else: "mailto:#{subject}"
    end

  config :ircpipe_web, Ircpipe.Notifications.WebPush,
    public_key: System.get_env("VAPID_PUBLIC_KEY"),
    private_key: System.get_env("VAPID_PRIVATE_KEY"),
    subject: vapid_subject
end

if config_env() == :prod do
  if web_capable? do
    config :ircpipe_web, :discovery_refresh_enabled, System.get_env("ENABLE_DISCOVERY") == "true"
  end

  credentials_key =
    System.get_env("IRC_CREDENTIALS_KEY") ||
      raise """
      environment variable IRC_CREDENTIALS_KEY is missing.
      Generate one with: mix ircpipe.gen_credentials_key
      """

  credentials_key =
    case Base.decode64(credentials_key) do
      {:ok, key} when byte_size(key) == 32 ->
        key

      _ ->
        raise "IRC_CREDENTIALS_KEY must be a Base64-encoded 32-byte key"
    end

  config :ircpipe_core, Ircpipe.Vault,
    ciphers: [
      default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: credentials_key, iv_length: 12}
    ]

  database_options =
    case System.get_env("DATABASE_URL") do
      nil ->
        fetch_database_env = fn name ->
          System.get_env(name) ||
            raise "environment variable #{name} is missing when DATABASE_URL is not set"
        end

        [
          hostname: fetch_database_env.("DATABASE_HOST"),
          username: fetch_database_env.("DATABASE_USER"),
          password: fetch_database_env.("DATABASE_PASSWORD"),
          database: fetch_database_env.("DATABASE_NAME")
        ]

      database_url ->
        [url: database_url]
    end

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  repo_options =
    Keyword.merge(database_options,
      # ssl: true,
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
      # For machines with several cores, consider starting multiple pools of `pool_size`
      # pool_count: 4,
      socket_options: maybe_ipv6
    )

  config :ircpipe_core, Ircpipe.Repo, repo_options

  if web_capable? do
    # The secret key base is used to sign/encrypt cookies and other secrets.
    # A default value is used in config/dev.exs and config/test.exs but you
    # want to use a different value for prod and you most likely don't want
    # to check this value into version control, so we use an environment
    # variable instead.
    secret_key_base =
      System.get_env("SECRET_KEY_BASE") ||
        raise """
        environment variable SECRET_KEY_BASE is missing.
        You can generate one by calling: mix phx.gen.secret
        """

    host = System.get_env("PHX_HOST") || "example.com"

    config :ircpipe_web, IrcpipeWeb.Endpoint,
      url: [host: host, port: 443, scheme: "https"],
      http: [
        # Enable IPv6 and bind on all interfaces.
        # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
        # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
        # for details about using IPv6 vs IPv4 and loopback vs public addresses.
        ip: {0, 0, 0, 0, 0, 0, 0, 0},
        port: String.to_integer(System.get_env("PORT", "4000"))
      ],
      secret_key_base: secret_key_base
  end

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :ircpipe_web, IrcpipeWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :ircpipe_web, IrcpipeWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :ircpipe_web, Ircpipe.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
