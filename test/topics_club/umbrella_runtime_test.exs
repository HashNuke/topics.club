defmodule TopicsClub.UmbrellaRuntimeTest do
  use ExUnit.Case, async: false

  alias TopicsClub.Discovery.Refresher

  test "the combined runtime starts each extracted application once" do
    assert is_pid(Process.whereis(TopicsClub.CoreSupervisor))
    assert is_pid(Process.whereis(TopicsClub.EngineSupervisor))
    assert is_pid(Process.whereis(TopicsClubWeb.Supervisor))
    assert Process.whereis(TopicsClub.Supervisor) == nil

    started_apps = Application.started_applications() |> Enum.map(&elem(&1, 0))

    assert :topics_club_core in started_apps
    assert :topics_club_engine in started_apps
    assert :topics_club_gateway in started_apps
    refute :topics_club in started_apps
    refute :ircpipe in started_apps
  end

  test "shared infrastructure starts once under the core branch" do
    assert direct_child_pid(TopicsClub.CoreSupervisor, TopicsClub.Vault) ==
             Process.whereis(TopicsClub.Vault)

    assert direct_child_pid(TopicsClub.CoreSupervisor, TopicsClub.Repo) ==
             Process.whereis(TopicsClub.Repo)

    assert is_pid(direct_child_pid(TopicsClub.CoreSupervisor, Phoenix.PubSub.Supervisor))
    assert is_pid(Process.whereis(TopicsClub.PubSub))
    assert Application.fetch_env!(:topics_club_core, :pubsub_pool_size) == 1
  end

  test "core owns the Ecto repository configuration" do
    assert Application.fetch_env!(:topics_club_core, :ecto_repos) == [TopicsClub.Repo]
    assert Application.get_env(:topics_club, :ecto_repos) == nil
    assert Application.get_env(:ircpipe, :ecto_repos) == nil
  end

  test "legacy OTP application and release names are not accepted" do
    for application <- [:ircpipe_core, :ircpipe_engine, :ircpipe_web] do
      assert Application.get_all_env(application) == []
    end

    config_path = Path.expand("../../config/runtime.exs", __DIR__)

    for release_name <- ["ircpipe", "ircpipe_web", "ircpipe_engine"] do
      with_system_env(%{"RELEASE_NAME" => release_name}, fn ->
        assert_raise RuntimeError, ~r/unsupported release name/, fn ->
          Config.Reader.read!(config_path, env: :prod)
        end
      end)
    end
  end

  test "engine owns its runtime configuration" do
    assert Application.fetch_env!(:topics_club_engine, :irc_bouncer_enabled) == false

    assert Application.fetch_env!(:topics_club_engine, TopicsClub.EngineOban)[:name] ==
             TopicsClub.EngineOban

    assert Application.get_env(:topics_club, :irc_bouncer_enabled) == nil
    assert Application.get_env(:topics_club, TopicsClub.EngineOban) == nil
    assert Application.get_env(:ircpipe, :irc_bouncer_enabled) == nil
    assert Application.get_env(:ircpipe, TopicsClub.EngineOban) == nil
  end

  test "engine runtime and its Oban instance are direct engine children" do
    assert direct_child_pid(TopicsClub.EngineSupervisor, TopicsClub.Engine.Marker) ==
             elem(TopicsClub.EngineClient.Discovery.whereis(), 1)

    assert direct_child_pid(TopicsClub.EngineSupervisor, TopicsClub.Engine.OperationLock) ==
             Process.whereis(TopicsClub.Engine.OperationLock)

    assert direct_child_pid(TopicsClub.EngineSupervisor, TopicsClub.Engine.RequestTaskSupervisor) ==
             Process.whereis(TopicsClub.Engine.RequestTaskSupervisor)

    assert direct_child_pid(TopicsClub.EngineSupervisor, TopicsClub.EngineOban) ==
             Oban.whereis(TopicsClub.EngineOban)

    assert direct_child_pid(
             TopicsClub.EngineSupervisor,
             TopicsClub.Irc.ConnectionOperationLock
           ) == Process.whereis(TopicsClub.Irc.ConnectionOperationLock)

    assert direct_child_pid(TopicsClub.EngineSupervisor, TopicsClub.Irc.SessionSystemSupervisor) ==
             Process.whereis(TopicsClub.Irc.SessionSystemSupervisor)

    assert direct_child_pid(TopicsClub.EngineSupervisor, TopicsClub.Irc.Bouncer) ==
             Process.whereis(TopicsClub.Irc.Bouncer)

    assert direct_child_pid(TopicsClub.EngineSupervisor, TopicsClub.Irc.HostedServerSupervisor) ==
             Process.whereis(TopicsClub.Irc.HostedServerSupervisor)
  end

  test "web runtime and its Oban instance are direct web children" do
    assert direct_child_pid(TopicsClubWeb.Supervisor, TopicsClubWeb.Telemetry) ==
             Process.whereis(TopicsClubWeb.Telemetry)

    assert direct_child_pid(TopicsClubWeb.Supervisor, TopicsClubWeb.EngineRestoreTaskSupervisor) ==
             Process.whereis(TopicsClubWeb.EngineRestoreTaskSupervisor)

    assert direct_child_pid(TopicsClubWeb.Supervisor, TopicsClubWeb.EngineRestorer) ==
             Process.whereis(TopicsClubWeb.EngineRestorer)

    assert direct_child_pid(TopicsClubWeb.Supervisor, TopicsClubWeb.Oban) ==
             Oban.whereis(TopicsClubWeb.Oban)

    assert direct_child_pid(TopicsClubWeb.Supervisor, TopicsClubWeb.Endpoint) ==
             Process.whereis(TopicsClubWeb.Endpoint)
  end

  test "the web branch controls discovery and keeps Endpoint last" do
    assert TopicsClubWeb.Supervisor.discovery_children(true) == [{Refresher, []}]
    assert TopicsClubWeb.Supervisor.discovery_children(false) == []
    assert TopicsClubWeb.Supervisor.split_runtime_children(nil) == []

    assert TopicsClubWeb.Supervisor.split_runtime_children(:engine@localhost) == [
             {TopicsClubWeb.InternalEvents.Subscriber, []},
             {TopicsClubWeb.EngineNodeConnector, engine_node: :engine@localhost}
           ]

    assert List.last(TopicsClubWeb.Supervisor.children(discovery_enabled?: true)) ==
             TopicsClubWeb.Endpoint
  end

  test "split gateway runtime defaults the engine node and configures cluster credentials" do
    credentials_key = Base.encode64(:binary.copy(<<0>>, 32))

    with_system_env(
      %{
        "DATABASE_URL" => "ecto://postgres:postgres@localhost/topics_club_prod",
        "IRC_CREDENTIALS_KEY" => credentials_key,
        "GATEWAY_HOST" => "topics.club",
        "RELEASE_COOKIE" => String.duplicate("a", 32),
        "RELEASE_NAME" => "topics_club_gateway",
        "RELEASE_NODE" => "topics_club_gateway@web.internal",
        "SECRET_KEY_BASE" => String.duplicate("b", 64),
        "TOPICS_CLUB_ENGINE_NODE" => nil
      },
      fn ->
        config_path = Path.expand("../../config/runtime.exs", __DIR__)
        config = Config.Reader.read!(config_path, env: :prod)

        assert config[:topics_club_gateway][:engine_node] == :topics_club_engine@localhost

        assert config[:topics_club_core][:engine_client_adapter] ==
                 TopicsClub.EngineClient.RpcAdapter
      end
    )
  end

  test "split engine defaults to Wirekeeper while retaining an explicit direct mode" do
    credentials_key = Base.encode64(:binary.copy(<<0>>, 32))

    base_env = %{
      "DATABASE_URL" => "ecto://postgres:postgres@localhost/topics_club_prod",
      "IRC_CREDENTIALS_KEY" => credentials_key,
      "RELEASE_COOKIE" => String.duplicate("a", 32),
      "RELEASE_NAME" => "topics_club_engine",
      "RELEASE_NODE" => "topics_club_engine@engine.internal",
      "TOPICS_CLUB_WIREKEEPER_NODE" => nil
    }

    with_system_env(Map.put(base_env, "TOPICS_CLUB_IRC_TRANSPORT", nil), fn ->
      config = read_production_runtime()

      assert config[:topics_club_engine][:irc_transport] ==
               {:wirekeeper, :topics_club_wirekeeper@localhost}
    end)

    with_system_env(Map.put(base_env, "TOPICS_CLUB_IRC_TRANSPORT", "direct"), fn ->
      config = read_production_runtime()
      assert config[:topics_club_engine][:irc_transport] == :direct
    end)
  end

  test "the standalone Wirekeeper runtime requires distribution but no database secrets" do
    with_system_env(
      %{
        "DATABASE_URL" => nil,
        "IRC_CREDENTIALS_KEY" => nil,
        "RELEASE_COOKIE" => String.duplicate("a", 32),
        "RELEASE_NAME" => "topics_club_wirekeeper",
        "RELEASE_NODE" => "topics_club_wirekeeper@wire.internal",
        "TOPICS_CLUB_WIREKEEPER_MAX_CONNECTIONS" => nil
      },
      fn ->
        config = read_production_runtime()
        assert config[:topics_club_core] == nil
        assert config[:topics_club_gateway] == nil
      end
    )
  end

  test "the standalone Wirekeeper runtime accepts only a positive connection limit" do
    base_env = %{
      "RELEASE_COOKIE" => String.duplicate("a", 32),
      "RELEASE_NAME" => "topics_club_wirekeeper",
      "RELEASE_NODE" => "topics_club_wirekeeper@wire.internal"
    }

    with_system_env(
      Map.put(base_env, "TOPICS_CLUB_WIREKEEPER_MAX_CONNECTIONS", "2500"),
      fn ->
        config = read_production_runtime()
        assert config[:topics_club_wirekeeper][:max_connections] == 2_500
      end
    )

    for invalid <- ["0", "-1", "many", "10.5"] do
      with_system_env(
        Map.put(base_env, "TOPICS_CLUB_WIREKEEPER_MAX_CONNECTIONS", invalid),
        fn ->
          assert_raise RuntimeError,
                       ~r/TOPICS_CLUB_WIREKEEPER_MAX_CONNECTIONS must be a positive integer/,
                       fn -> read_production_runtime() end
        end
      )
    end
  end

  test "the combined tree uses named role-specific Oban instances" do
    runtime_engine_config = Application.fetch_env!(:topics_club_engine, TopicsClub.EngineOban)
    runtime_web_config = Application.fetch_env!(:topics_club_gateway, TopicsClubWeb.Oban)
    {engine_config, web_config} = production_oban_configs()
    engine_queues = engine_config |> Keyword.fetch!(:queues) |> Keyword.keys() |> MapSet.new()
    web_queues = web_config |> Keyword.fetch!(:queues) |> Keyword.keys() |> MapSet.new()

    assert runtime_engine_config[:name] == TopicsClub.EngineOban
    assert runtime_web_config[:name] == TopicsClubWeb.Oban
    assert engine_config[:plugins] == []

    assert get_in(engine_config, [:cron, :crontab]) == [
             {"* * * * *", TopicsClub.Chat.ConnectionDeletionReconcilerWorker}
           ]

    assert web_config[:plugins] == [Oban.Plugins.Pruner]
    assert web_config[:cron] == nil
    assert MapSet.equal?(engine_queues, MapSet.new([:connection_deletions]))
    assert MapSet.equal?(web_queues, MapSet.new([:internal_events, :notifications]))
    assert MapSet.disjoint?(engine_queues, web_queues)
    assert Application.get_env(:topics_club, Oban) == nil
    assert Application.get_env(:ircpipe, Oban) == nil
  end

  test "production config accepts discrete database credentials without URL encoding" do
    credentials_key = Base.encode64(:binary.copy(<<0>>, 32))

    with_system_env(
      %{
        "DATABASE_URL" => nil,
        "DATABASE_HOST" => "postgres",
        "DATABASE_USER" => "postgres",
        "DATABASE_PASSWORD" => "pa:ss@word#x?/+",
        "DATABASE_NAME" => "topics_club_prod",
        "DB_QUEUE_TARGET" => "6100",
        "DB_QUEUE_INTERVAL" => "6200",
        "IRC_CREDENTIALS_KEY" => credentials_key,
        "RELEASE_COOKIE" => String.duplicate("c", 32),
        "RELEASE_NAME" => "topics_club_engine",
        "RELEASE_NODE" => "topics_club_engine@engine.internal"
      },
      fn ->
        config_path = Path.expand("../../config/runtime.exs", __DIR__)
        config = Config.Reader.read!(config_path, env: :prod)
        repo_config = config[:topics_club_core][TopicsClub.Repo]

        refute Keyword.has_key?(repo_config, :url)
        assert repo_config[:hostname] == "postgres"
        assert repo_config[:username] == "postgres"
        assert repo_config[:password] == "pa:ss@word#x?/+"
        assert repo_config[:database] == "topics_club_prod"
        assert repo_config[:queue_target] == 6_100
        assert repo_config[:queue_interval] == 6_200
      end
    )
  end

  test "split releases use short local names without reusing runtime distribution ports" do
    env_script = Path.expand("../../rel/env.sh.eex", __DIR__)

    for {release_name, release_node, port} <- [
          {"topics_club_gateway", "topics_club_gateway@web.internal", "4370"},
          {"topics_club_engine", "topics_club_engine@engine.internal", "4371"},
          {"topics_club_wirekeeper", "topics_club_wirekeeper@wire.internal", "4372"}
        ] do
      for command <- ~w(start start_iex daemon daemon_iex) do
        output = release_env(env_script, release_name, release_node, command)
        assert output =~ "sname|"
        assert output =~ "inet_dist_use_interface {127,0,0,1}"
        refute output =~ "'{127,0,0,1}'"
        assert output =~ "inet_dist_listen_min #{port} inet_dist_listen_max #{port}"
      end

      for command <- ~w(pid remote restart rpc stop) do
        output = release_env(env_script, release_name, release_node, command)
        assert output =~ "sname|"
        refute output =~ "inet_dist_listen"
      end

      for command <- ~w(eval version) do
        output = release_env(env_script, release_name, release_node, command)
        assert output =~ "none|"
        refute output =~ "inet_dist_listen"
      end
    end
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
      config[:topics_club_engine][TopicsClub.EngineOban],
      config[:topics_club_gateway][TopicsClubWeb.Oban]
    }
  end

  defp read_production_runtime do
    config_path = Path.expand("../../config/runtime.exs", __DIR__)
    Config.Reader.read!(config_path, env: :prod)
  end

  defp release_env(script, release_name, release_node, command) do
    env = [
      {"ELIXIR_ERL_OPTIONS", ""},
      {"RELEASE_COMMAND", command},
      {"RELEASE_COOKIE", String.duplicate("a", 32)},
      {"RELEASE_NAME", release_name},
      {"RELEASE_NODE", release_node}
    ]

    assert {output, 0} =
             System.cmd(
               "sh",
               [
                 "-c",
                 ~S(. "$1"; printf '%s|%s' "${RELEASE_DISTRIBUTION:-}" "${ELIXIR_ERL_OPTIONS:-}"),
                 "env-test",
                 script
               ],
               env: env
             )

    output
  end

  defp with_system_env(overrides, callback) do
    previous = Map.new(Map.keys(overrides), &{&1, System.get_env(&1)})
    set_system_env(overrides)

    try do
      callback.()
    after
      set_system_env(previous)
    end
  end

  defp set_system_env(environment) do
    Enum.each(environment, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end
end
