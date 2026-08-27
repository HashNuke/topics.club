defmodule IrcpipeWeb.Router do
  use IrcpipeWeb, :router

  import IrcpipeWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {IrcpipeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
    plug :track_user_activity
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :authenticated_api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :fetch_flash
    plug :protect_from_forgery
    plug :fetch_current_scope_for_user
    plug :require_authenticated_user
    plug :track_user_activity
  end

  pipeline :notification_account_api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user_without_reissue
  end

  scope "/", IrcpipeWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/", IrcpipeWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/chat", AppController, :index
  end

  scope "/api", IrcpipeWeb.Api do
    pipe_through :api

    get "/topics", TopicController, :index
  end

  scope "/api", IrcpipeWeb.Api do
    pipe_through :notification_account_api

    get "/notification-account", NotificationAccountController, :show
    get "/notifications/:id/eligibility", NotificationEligibilityController, :show
  end

  scope "/api", IrcpipeWeb.Api do
    pipe_through :authenticated_api

    get "/bootstrap", BootstrapController, :show
    get "/discovery/server_channels", DiscoveryController, :index
    post "/discovery/server_channels/:id/join", DiscoveryController, :join
    post "/topics/:id/join", TopicController, :join
    get "/connections", ConnectionController, :index
    post "/connections", ConnectionController, :create
    put "/connections/:id", ConnectionController, :update
    post "/connections/:id/connect", ConnectionController, :connect
    post "/connections/:id/disconnect", ConnectionController, :disconnect
    delete "/connections/:id", ConnectionController, :delete

    post "/connections/:connection_id/channels", ChannelController, :create
    post "/channel_memberships/:id/leave", ChannelController, :leave

    get "/buffer_messages", MessageController, :buffer_index

    put "/settings", SettingsController, :update
    post "/push_subscriptions", PushSubscriptionController, :create
    delete "/push_subscriptions/:installation_id", PushSubscriptionController, :delete

    put "/connections/:id/notification_preferences",
        NotificationPreferenceController,
        :update_server

    put "/channel_memberships/:id/notification_preferences",
        NotificationPreferenceController,
        :update_channel

    post "/activity", ActivityController, :create
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:ircpipe, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: IrcpipeWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", IrcpipeWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    get "/users/register", UserRegistrationController, :new
    post "/users/register", UserRegistrationController, :create
  end

  scope "/", IrcpipeWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/users/settings", UserSettingsController, :edit
    put "/users/settings", UserSettingsController, :update
    get "/users/settings/confirm-email/:token", UserSettingsController, :confirm_email
  end

  scope "/", IrcpipeWeb do
    pipe_through [:browser]

    get "/users/log-in", UserSessionController, :new
    get "/users/log-in/:token", UserSessionController, :confirm
    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  scope "/auth", IrcpipeWeb do
    pipe_through :browser

    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback
    post "/:provider/callback", AuthController, :callback
  end
end
