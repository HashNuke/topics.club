defmodule Ircpipe.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        IrcpipeWeb.Telemetry,
        Ircpipe.Vault,
        Ircpipe.Repo,
        {DNSCluster, query: Application.get_env(:ircpipe, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Ircpipe.PubSub},
        {Registry, keys: :unique, name: Ircpipe.Irc.SessionRegistry},
        {Ircpipe.Irc.SessionSupervisor, []},
        {Ircpipe.Irc.Bouncer, []}
      ] ++
        discovery_children() ++
        [
          # Start to serve requests, typically the last entry
          IrcpipeWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Ircpipe.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc false
  def discovery_children(
        enabled? \\ Application.get_env(:ircpipe, :discovery_refresh_enabled, false)
      )

  def discovery_children(true), do: [{Ircpipe.Discovery.Refresher, []}]
  def discovery_children(false), do: []

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    IrcpipeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
