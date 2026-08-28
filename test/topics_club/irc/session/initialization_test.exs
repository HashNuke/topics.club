defmodule TopicsClub.Irc.Session.InitializationTest do
  use TopicsClub.DataCase, async: true

  alias TopicsClub.AccountsFixtures
  alias TopicsClub.Chat.{ChannelJoinRequest, Connections}
  alias TopicsClub.Irc.Session.{Initialization, PendingEchoes}

  test "authorizes the connection and builds the complete initial session state" do
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "initialization",
               "host" => "irc.initialization.test",
               "nickname" => "mira"
             })

    assert {:ok, _membership} = ChannelJoinRequest.request(user, connection, "#elixir")

    assert {:ok, state} = Initialization.initialize(connection)
    assert_receive :connect

    assert state.connection.id == connection.id
    assert state.pending_joins == MapSet.new(["#elixir"])
    assert PendingEchoes.empty?(state.pending_echoes)

    assert Map.take(state, [
             :client,
             :registered?,
             :joined_channels,
             :names_buffers,
             :pending_commands,
             :ignored_event_logs,
             :client_info,
             :isupport_received?,
             :isupport_seen?,
             :registration_boundary_reached?,
             :join_validation_ready?,
             :joins_flushed?,
             :join_flush_timer,
             :sent_joins,
             :channel_list_request
           ]) == %{
             client: nil,
             registered?: false,
             joined_channels: MapSet.new(),
             names_buffers: %{},
             pending_commands: %{},
             ignored_event_logs: %{},
             client_info: nil,
             isupport_received?: false,
             isupport_seen?: false,
             registration_boundary_reached?: false,
             join_validation_ready?: false,
             joins_flushed?: false,
             join_flush_timer: nil,
             sent_joins: MapSet.new(),
             channel_list_request: nil
           }
  end
end
