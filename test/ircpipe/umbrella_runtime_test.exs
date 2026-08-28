defmodule Ircpipe.UmbrellaRuntimeTest do
  use ExUnit.Case, async: true

  alias Ircpipe.Discovery.Refresher

  test "the combined runtime starts each extracted application once" do
    assert is_pid(Process.whereis(Ircpipe.CoreSupervisor))
    assert is_pid(Process.whereis(Ircpipe.EngineSupervisor))
    assert is_pid(Process.whereis(IrcpipeWeb.Supervisor))
    assert Process.whereis(Ircpipe.Supervisor) == nil

    started_apps = Application.started_applications() |> Enum.map(&elem(&1, 0))

    assert :ircpipe_core in started_apps
    assert :ircpipe_engine in started_apps
    assert :ircpipe_web in started_apps
    refute :ircpipe in started_apps
  end

  test "shared infrastructure starts once under the core branch" do
    assert direct_child_pid(Ircpipe.CoreSupervisor, Ircpipe.Vault) ==
             Process.whereis(Ircpipe.Vault)

    assert direct_child_pid(Ircpipe.CoreSupervisor, Ircpipe.Repo) ==
             Process.whereis(Ircpipe.Repo)

    assert is_pid(direct_child_pid(Ircpipe.CoreSupervisor, Phoenix.PubSub.Supervisor))
    assert is_pid(Process.whereis(Ircpipe.PubSub))
  end

  test "core owns the Ecto repository configuration" do
    assert Application.fetch_env!(:ircpipe_core, :ecto_repos) == [Ircpipe.Repo]
    assert Application.get_env(:ircpipe, :ecto_repos) == nil
  end

  test "engine owns its runtime configuration" do
    assert Application.fetch_env!(:ircpipe_engine, :irc_bouncer_enabled) == false

    assert Application.fetch_env!(:ircpipe_engine, Ircpipe.EngineOban)[:name] ==
             Ircpipe.EngineOban

    assert Application.get_env(:ircpipe, :irc_bouncer_enabled) == nil
    assert Application.get_env(:ircpipe, Ircpipe.EngineOban) == nil
  end

  test "engine runtime and its Oban instance are direct engine children" do
    assert direct_child_pid(Ircpipe.EngineSupervisor, Ircpipe.Engine.Marker) ==
             elem(Ircpipe.EngineClient.Discovery.whereis(), 1)

    assert direct_child_pid(Ircpipe.EngineSupervisor, Ircpipe.Engine.OperationLock) ==
             Process.whereis(Ircpipe.Engine.OperationLock)

    assert direct_child_pid(Ircpipe.EngineSupervisor, Ircpipe.Engine.RequestTaskSupervisor) ==
             Process.whereis(Ircpipe.Engine.RequestTaskSupervisor)

    assert direct_child_pid(Ircpipe.EngineSupervisor, Ircpipe.EngineOban) ==
             Oban.whereis(Ircpipe.EngineOban)

    assert direct_child_pid(Ircpipe.EngineSupervisor, Ircpipe.Irc.SessionSystemSupervisor) ==
             Process.whereis(Ircpipe.Irc.SessionSystemSupervisor)

    assert direct_child_pid(Ircpipe.EngineSupervisor, Ircpipe.Irc.HostedServerSupervisor) ==
             Process.whereis(Ircpipe.Irc.HostedServerSupervisor)
  end

  test "web runtime and its Oban instance are direct web children" do
    assert direct_child_pid(IrcpipeWeb.Supervisor, IrcpipeWeb.Telemetry) ==
             Process.whereis(IrcpipeWeb.Telemetry)

    assert direct_child_pid(IrcpipeWeb.Supervisor, IrcpipeWeb.EngineRestoreTaskSupervisor) ==
             Process.whereis(IrcpipeWeb.EngineRestoreTaskSupervisor)

    assert direct_child_pid(IrcpipeWeb.Supervisor, IrcpipeWeb.EngineRestorer) ==
             Process.whereis(IrcpipeWeb.EngineRestorer)

    assert direct_child_pid(IrcpipeWeb.Supervisor, IrcpipeWeb.Oban) ==
             Oban.whereis(IrcpipeWeb.Oban)

    assert direct_child_pid(IrcpipeWeb.Supervisor, IrcpipeWeb.Endpoint) ==
             Process.whereis(IrcpipeWeb.Endpoint)
  end

  test "the web branch controls discovery and keeps Endpoint last" do
    assert IrcpipeWeb.Supervisor.discovery_children(true) == [{Refresher, []}]
    assert IrcpipeWeb.Supervisor.discovery_children(false) == []

    assert List.last(IrcpipeWeb.Supervisor.children(discovery_enabled?: true)) ==
             IrcpipeWeb.Endpoint
  end

  test "the combined tree uses named role-specific Oban instances" do
    runtime_engine_config = Application.fetch_env!(:ircpipe_engine, Ircpipe.EngineOban)
    runtime_web_config = Application.fetch_env!(:ircpipe_web, IrcpipeWeb.Oban)
    {engine_config, web_config} = production_oban_configs()
    engine_queues = engine_config |> Keyword.fetch!(:queues) |> Keyword.keys() |> MapSet.new()
    web_queues = web_config |> Keyword.fetch!(:queues) |> Keyword.keys() |> MapSet.new()

    assert runtime_engine_config[:name] == Ircpipe.EngineOban
    assert runtime_web_config[:name] == IrcpipeWeb.Oban
    assert engine_config[:plugins] == []

    assert get_in(engine_config, [:cron, :crontab]) == [
             {"* * * * *", Ircpipe.Chat.ConnectionDeletionReconcilerWorker}
           ]

    assert web_config[:plugins] == [Oban.Plugins.Pruner]
    assert web_config[:cron] == nil
    assert MapSet.disjoint?(engine_queues, web_queues)
    assert Application.get_env(:ircpipe, Oban) == nil
  end

  defp direct_child_pid(supervisor, child_id) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^child_id, pid, _type, _modules} -> pid
      _child -> nil
    end)
  end

  defp production_oban_configs do
    config_path = Path.expand("../../config/config.exs", __DIR__)
    config = Config.Reader.read!(config_path, env: :prod)

    {
      config[:ircpipe_engine][Ircpipe.EngineOban],
      config[:ircpipe_web][IrcpipeWeb.Oban]
    }
  end
end
