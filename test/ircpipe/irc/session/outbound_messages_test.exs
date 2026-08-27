defmodule Ircpipe.Irc.Session.OutboundMessagesTest do
  use Ircpipe.DataCase

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat

  alias Ircpipe.Chat.{
    Connections,
    DirectMessageLifecycle,
    MessageHistory,
    ServerConnection
  }

  alias Ircpipe.Irc.{Session, SessionLocator, SessionSupervisor}
  alias Ircpipe.Irc.Session.{OutboundMessages, PendingEchoes}
  alias Ircpipe.IrcTestServer

  test "distinguishes disconnected, joining, and unjoined channel delivery" do
    state = state_fixture()
    disconnected = %{state | client: nil}

    assert {{:error, :not_connected}, ^disconnected} =
             OutboundMessages.say(disconnected, "#elixir", "hello")

    joining = %{state | pending_joins: MapSet.new(["#elixir"])}

    assert {{:error, :joining_channel}, ^joining} =
             OutboundMessages.say(joining, "#Elixir", "hello")

    assert {{:error, :not_joined}, ^state} =
             OutboundMessages.action(state, "#elixir", "waves")
  end

  test "rejects invalid chat messages before checking connection state" do
    state = %{state_fixture() | client: nil}

    assert {{:error, _reason}, ^state} = OutboundMessages.say(state, "#elixir", "")
  end

  test "rejects direct messages while disconnected without changing state" do
    state = %{state_fixture() | client: nil}

    assert {{:error, :not_connected}, ^state} =
             OutboundMessages.direct(state, 123, "hello")
  end

  test "sends and persists channel messages and actions with normalized pending echoes" do
    {_server, user, connection, membership, state} = connected_state("#Elixir")

    assert {{:ok, sent_message}, state} = OutboundMessages.say(state, "#Elixir", "hello")
    assert sent_message.body == "hello"
    assert sent_message.kind == "message"
    assert_receive {:irc_server_line, "PRIVMSG #Elixir hello"}

    assert {:matched, pending_echoes} =
             PendingEchoes.pop(state.pending_echoes, "#elixir", "hello", "message")

    state = %{state | pending_echoes: pending_echoes}

    assert {{:ok, sent_action}, state} = OutboundMessages.action(state, "#Elixir", "waves")
    assert sent_action.body == "waves"
    assert sent_action.kind == "action"
    assert_receive {:irc_server_line, "PRIVMSG #Elixir :\x01ACTION waves\x01"}

    assert {:matched, pending_echoes} =
             PendingEchoes.pop(state.pending_echoes, "#elixir", "waves", "action")

    state = %{state | pending_echoes: pending_echoes}

    assert {{:error, _reason}, ^state} = OutboundMessages.action(state, "#Elixir", "")
    assert {{:error, _reason}, ^state} = OutboundMessages.say(state, "#Elixir", "   ")
    assert {{:error, _reason}, ^state} = OutboundMessages.action(state, "#Elixir", "   ")
    refute_receive {:irc_server_line, "PRIVMSG " <> _payload}
    assert PendingEchoes.empty?(state.pending_echoes)

    persisted_outbound =
      user
      |> MessageHistory.list_messages(membership.id)
      |> Enum.filter(&(&1.kind in ["message", "action"]))

    assert Enum.map(persisted_outbound, & &1.id) == [sent_message.id, sent_action.id]

    assert Enum.map(persisted_outbound, fn message ->
             {message.kind, message.body, message.metadata}
           end) == [
             {"message", "hello", %{"direction" => "outgoing"}},
             {"action", "waves", %{"direction" => "outgoing"}}
           ]

    assert :ok = Session.quit(connection)
  end

  test "sends and persists direct messages with the exact reply and pending echo" do
    {_server, user, connection, nil, state} = connected_state(nil)
    assert {:ok, thread} = DirectMessageLifecycle.open(user, connection, "Akash")

    assert {{:error, _reason}, ^state} = OutboundMessages.direct(state, thread.id, "   ")
    refute_receive {:irc_server_line, "PRIVMSG " <> _payload}
    assert PendingEchoes.empty?(state.pending_echoes)
    assert MessageHistory.list_buffer_messages(user, "direct:#{thread.id}") == []

    assert {{:ok, %{thread: sent_thread, message: message}}, state} =
             OutboundMessages.direct(state, thread.id, "hello privately")

    assert sent_thread.id == thread.id
    assert message.direct_message_thread_id == thread.id
    assert message.body == "hello privately"
    assert message.kind == "message"

    assert message.metadata == %{
             "account" => nil,
             "direction" => "outgoing",
             "hostmask" => nil,
             "peer_nick" => "Akash",
             "target" => "Akash"
           }

    assert_receive {:irc_server_line, "PRIVMSG Akash :hello privately"}

    assert {:matched, pending_echoes} =
             PendingEchoes.pop(state.pending_echoes, "akash", "hello privately", "message")

    assert PendingEchoes.empty?(pending_echoes)

    assert Enum.map(MessageHistory.list_buffer_messages(user, "direct:#{thread.id}"), & &1.id) ==
             [message.id]

    assert :ok = Session.quit(connection)
  end

  test "managed execution rejects empty logical bodies before wire send or persistence" do
    {_server, user, connection, membership, _state} = connected_state("#Elixir")

    messages = [
      {"PRIVMSG", "   "},
      {"NOTICE", "   "},
      {"PRIVMSG", <<1, "ACTION    ", 1>>}
    ]

    for {{command, body}, index} <- Enum.with_index(messages) do
      intent = %{
        disposition: :managed,
        display: "#{command} #Elixir :[blank]",
        message: %Ircxd.Message{command: command, params: ["#Elixir", body]},
        spec: %{family: :message}
      }

      assert {:error, %{code: "invalid_arguments"}} =
               Session.execute(
                 connection,
                 intent,
                 "blank-managed-#{index}",
                 "channel:#{membership.id}"
               )
    end

    refute_receive {:irc_server_line, "PRIVMSG " <> _payload}
    refute_receive {:irc_server_line, "NOTICE " <> _payload}

    refute Enum.any?(MessageHistory.list_messages(user, membership.id), fn message ->
             message.kind in ["message", "action", "notice", "command"]
           end)

    assert :ok = Session.quit(connection)
  end

  defp state_fixture do
    %{
      connection: %ServerConnection{nickname: "mira"},
      client: self(),
      active_casemapping: :ascii,
      joined_channels: MapSet.new(),
      pending_joins: MapSet.new(),
      pending_echoes: PendingEchoes.new()
    }
  end

  defp connected_state(channel) do
    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "outbound-#{System.unique_integer([:positive])}",
               "host" => "localhost",
               "port" => IrcTestServer.port(server),
               "use_tls" => false,
               "nickname" => "ircpipe"
             })

    membership =
      if channel do
        assert {:ok, membership} = Chat.join_channel(user, connection, channel)
        membership
      end

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    assert {:ok, _pid} = SessionSupervisor.start_session(connection)

    on_exit(fn ->
      _ = SessionSupervisor.stop_session(connection)
    end)

    assert_receive {:irc_server_line, "NICK ircpipe"}
    assert_receive {:irc_server_line, "USER ircpipe 0 * ircpipe"}
    assert_receive {:buffer_system, %{body: "Connected to localhost."}}

    if channel do
      assert_receive {:irc_server_line, "JOIN " <> ^channel}
      assert_receive {:presence_sync, %{buffer_id: "channel:" <> _membership_id}}
    end

    state = :sys.get_state(SessionLocator.via(connection))
    {server, user, connection, membership, state}
  end
end
