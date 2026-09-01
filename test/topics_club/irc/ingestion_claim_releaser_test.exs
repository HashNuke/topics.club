defmodule TopicsClub.Irc.IngestionClaimReleaserTest do
  use TopicsClub.DataCase, async: false

  alias TopicsClub.AccountsFixtures
  alias TopicsClub.Chat.{Connections, IrcIngestionEffect}
  alias TopicsClub.Irc.IngestionClaimReleaser
  alias TopicsClub.IrcTestServer
  alias TopicsClub.Repo
  alias TopicsClub.Wirekeeper

  setup do
    previous_transport = Application.get_env(:topics_club_engine, :irc_transport)
    Application.put_env(:topics_club_engine, :irc_transport, {:wirekeeper, node()})

    on_exit(fn -> restore_transport(previous_transport) end)
  end

  test "a cold recovery removes a claim acknowledged before its volatile release cast" do
    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "claim recovery",
        "host" => "127.0.0.1",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "mira"
      })

    assert {:ok, opened} =
             Wirekeeper.open(
               connection.id,
               {:tcp, host: "127.0.0.1", port: IrcTestServer.port(server)}
             )

    on_exit(fn ->
      case Wirekeeper.info(connection.id) do
        {:ok, %{generation: generation}} -> Wirekeeper.close(connection.id, generation)
        _missing -> :ok
      end
    end)

    assert {:ok, _summary} = Wirekeeper.attach(connection.id, opened.generation, self())
    assert_eventually(fn -> not is_nil(:sys.get_state(server).socket) end)

    assert :ok = IrcTestServer.send_line(server, ":server NOTICE mira :persist me")

    assert_receive {:topics_club_wirekeeper,
                    {:data,
                     %{
                       generation: generation,
                       sequence: sequence,
                       payload: ":server NOTICE mira :persist me\r\n"
                     }}},
                   1_000

    ingestion = %{
      generation: generation,
      sequence: sequence,
      effect_key: "server-line:0"
    }

    assert :new = IrcIngestionEffect.claim(connection, ingestion)
    assert :ok = Wirekeeper.ack(connection.id, generation, sequence)

    assert Repo.get_by(IrcIngestionEffect,
             server_connection_id: connection.id,
             wirekeeper_generation: generation,
             wirekeeper_sequence: sequence
           )

    releaser =
      start_supervised!(
        {IngestionClaimReleaser,
         name: TopicsClub.Irc.IngestionClaimReleaserTest.ColdStartReleaser,
         recovery_interval: 60_000}
      )

    _state = :sys.get_state(releaser)

    assert_eventually(fn ->
      is_nil(
        Repo.get_by(IrcIngestionEffect,
          server_connection_id: connection.id,
          wirekeeper_generation: generation,
          wirekeeper_sequence: sequence
        )
      )
    end)
  end

  test "recovery retains claims while the Wirekeeper boundary is unavailable" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "unavailable claim recovery",
        "host" => "irc.example.test",
        "nickname" => "mira"
      })

    ingestion = %{
      generation: "retained-generation",
      sequence: 7,
      effect_key: "server-line:0"
    }

    assert :new = IrcIngestionEffect.claim(connection, ingestion)

    Application.put_env(
      :topics_club_engine,
      :irc_transport,
      {:wirekeeper, :missing_wirekeeper@localhost}
    )

    assert {:ok,
            %{
              released_generations: 0,
              retained_generations: 1,
              errors: [{connection_id, "retained-generation", _reason}]
            }} = IngestionClaimReleaser.recover()

    assert connection_id == connection.id

    assert Repo.get_by(IrcIngestionEffect,
             server_connection_id: connection.id,
             wirekeeper_generation: ingestion.generation,
             wirekeeper_sequence: ingestion.sequence
           )
  end

  defp assert_eventually(callback, attempts \\ 1_000)

  defp assert_eventually(callback, attempts) when attempts > 0 do
    if callback.() do
      :ok
    else
      receive do
      after
        2 -> assert_eventually(callback, attempts - 1)
      end
    end
  end

  defp assert_eventually(_callback, 0), do: flunk("condition did not become true")

  defp restore_transport(nil),
    do: Application.delete_env(:topics_club_engine, :irc_transport)

  defp restore_transport(previous),
    do: Application.put_env(:topics_club_engine, :irc_transport, previous)
end
