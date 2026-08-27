defmodule Ircpipe.ApplicationTest do
  use ExUnit.Case, async: true

  alias Ircpipe.Discovery.Refresher

  test "the combined root starts the core, engine, and web supervisor branches" do
    assert direct_child_pid(Ircpipe.Supervisor, Ircpipe.CoreSupervisor) ==
             Process.whereis(Ircpipe.CoreSupervisor)

    assert direct_child_pid(Ircpipe.Supervisor, Ircpipe.EngineSupervisor) ==
             Process.whereis(Ircpipe.EngineSupervisor)

    assert direct_child_pid(Ircpipe.Supervisor, IrcpipeWeb.Supervisor) ==
             Process.whereis(IrcpipeWeb.Supervisor)
  end

  test "shared infrastructure starts once under the core branch" do
    assert direct_child_pid(Ircpipe.CoreSupervisor, Ircpipe.Vault) ==
             Process.whereis(Ircpipe.Vault)

    assert direct_child_pid(Ircpipe.CoreSupervisor, Ircpipe.Repo) ==
             Process.whereis(Ircpipe.Repo)

    assert is_pid(direct_child_pid(Ircpipe.CoreSupervisor, Phoenix.PubSub.Supervisor))
    assert is_pid(Process.whereis(Ircpipe.PubSub))
  end

  test "engine runtime and its Oban instance are direct engine children" do
    assert direct_child_pid(Ircpipe.EngineSupervisor, Ircpipe.Engine.Marker) ==
             elem(Ircpipe.EngineClient.Discovery.whereis(), 1)

    assert direct_child_pid(Ircpipe.EngineSupervisor, Ircpipe.Engine.RequestTaskSupervisor) ==
             Process.whereis(Ircpipe.Engine.RequestTaskSupervisor)

    assert direct_child_pid(Ircpipe.EngineSupervisor, Ircpipe.EngineOban) ==
             Oban.whereis(Ircpipe.EngineOban)

    assert direct_child_pid(Ircpipe.EngineSupervisor, Ircpipe.Irc.SessionSystemSupervisor) ==
             Process.whereis(Ircpipe.Irc.SessionSystemSupervisor)
  end

  test "web runtime and its Oban instance are direct web children" do
    assert direct_child_pid(IrcpipeWeb.Supervisor, IrcpipeWeb.Telemetry) ==
             Process.whereis(IrcpipeWeb.Telemetry)

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
    engine_config = Application.fetch_env!(:ircpipe, Ircpipe.EngineOban)
    web_config = Application.fetch_env!(:ircpipe, IrcpipeWeb.Oban)

    assert engine_config[:name] == Ircpipe.EngineOban

    assert get_in(engine_config, [:cron, :crontab]) == [
             {"* * * * *", Ircpipe.Chat.ConnectionDeletionReconcilerWorker}
           ]

    assert web_config[:name] == IrcpipeWeb.Oban
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
end
