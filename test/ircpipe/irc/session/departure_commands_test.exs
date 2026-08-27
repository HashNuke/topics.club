defmodule Ircpipe.Irc.Session.DepartureCommandsTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.{Connections, MembershipLookup, MessageHistory}
  alias Ircpipe.Irc.Session
  alias Ircpipe.Irc.Session.DepartureCommands

  setup do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "departure commands",
        "host" => "irc.example.test",
        "port" => 6697,
        "use_tls" => true,
        "nickname" => "mira"
      })

    state = %{
      connection: connection,
      client: nil,
      pending_joins: MapSet.new(),
      joined_channels: MapSet.new(),
      sent_joins: MapSet.new()
    }

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    %{connection: connection, state: state, user: user}
  end

  test "cancels a locally queued join without requiring a client", context do
    {:ok, membership} = Chat.request_channel_join(context.user, context.connection, "#queued")
    state = %{context.state | pending_joins: MapSet.new(["#queued"])}

    assert {:ok, returned} = DepartureCommands.part(state, "#queued", "leaving")

    refute MapSet.member?(returned.pending_joins, "#queued")
    assert MembershipLookup.get!(context.user, membership.id).status == "left"

    assert_receive {:buffer_left, %{channel_membership_id: membership_id}}
    assert membership_id == membership.id
  end

  test "preserves joined state when PART transmission fails", context do
    {:ok, membership} = Chat.join_channel(context.user, context.connection, "#joined")
    client = start_supervised!({Ircpipe.FailingIrcClient, :closed})

    state = %{
      context.state
      | client: client,
        joined_channels: MapSet.new(["#joined"])
    }

    assert {{:error, :closed}, returned} = DepartureCommands.part(state, "#joined", "later")

    assert returned == state
    assert MembershipLookup.get!(context.user, membership.id).status == "joined"
    membership_id = membership.id
    refute_receive {:buffer_left, %{channel_membership_id: ^membership_id}}
  end

  test "quits cleanly without a connected client and records the departure", context do
    assert {:ok, returned} = DepartureCommands.quit(context.state, "leaving")
    assert returned == context.state

    assert [%{kind: "system", body: "Disconnected from irc.example.test."}] =
             messages(context)
  end

  test "returns QUIT transport errors while preserving the visible departure contract", context do
    client = start_supervised!({Ircpipe.FailingIrcClient, :closed})
    state = %{context.state | client: client}

    assert {{:error, :closed}, returned} = DepartureCommands.quit(state, "leaving")
    assert returned == state

    assert [%{kind: "system", body: "Disconnected from irc.example.test."}] =
             messages(context)

    assert {:stop, :normal, {:error, :closed}, callback_state} =
             Session.handle_call({:quit, "leaving"}, self(), state)

    assert callback_state == state

    assert [
             %{kind: "system", body: "Disconnected from irc.example.test."},
             %{kind: "system", body: "Disconnected from irc.example.test."}
           ] = messages(context)
  end

  defp messages(context) do
    MessageHistory.list_buffer_messages(
      context.user,
      "server:#{context.connection.id}"
    )
  end
end
