defmodule Ircpipe.Irc.Session.JoinFailureEventsTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat

  alias Ircpipe.Chat.{
    CommandMessages,
    Connections,
    MembershipLookup,
    MessageHistory
  }

  alias Ircpipe.Irc.Session.JoinFailureEvents
  alias Ircpipe.Repo

  test "reconciles an IRC numeric and records its error" do
    {user, connection, state} = state_fixture()
    {:ok, membership} = Chat.request_channel_join(user, connection, "#missing", :ascii)

    state = %{
      state
      | pending_joins: MapSet.new(["#missing"]),
        sent_joins: MapSet.new(["#missing"])
    }

    payload = %{code: "403", target: "#missing", reason: "No such channel"}

    returned = JoinFailureEvents.irc_error(state, payload)

    refute MapSet.member?(returned.pending_joins, "#missing")
    refute MapSet.member?(returned.sent_joins, "#missing")
    assert MembershipLookup.get!(user, membership.id).status == "error"

    assert [%{body: "No such channel", kind: "error"}] =
             MessageHistory.list_buffer_messages(user, "channel:#{membership.id}")
  end

  test "records an unmatched standard JOIN failure" do
    {user, connection, state} = state_fixture()

    payload = %{
      type: :fail,
      command: "JOIN",
      context: [],
      description: "JOIN is unavailable"
    }

    assert JoinFailureEvents.standard_reply(state, payload) == state

    assert [%{body: "JOIN is unavailable", kind: "error"}] =
             MessageHistory.list_buffer_messages(user, "server:#{connection.id}")
  end

  test "does not record a second generic error for a managed JOIN failure" do
    {user, connection, state} = state_fixture()
    {:ok, membership} = Chat.request_channel_join(user, connection, "#managed", :ascii)

    {:ok, invocation} =
      CommandMessages.record(
        connection,
        "server:#{connection.id}",
        "/join #managed",
        %{command_status: "sent"}
      )

    timer = Process.send_after(self(), {:command_timeout, "join-1"}, 60_000)
    on_exit(fn -> Process.cancel_timer(timer) end)

    state = %{
      state
      | pending_commands: %{
          "join-1" => %{
            command: "JOIN",
            invocation: invocation,
            labeled?: false,
            targets: ["#managed"],
            timer: timer
          }
        },
        pending_joins: MapSet.new(["#managed"]),
        sent_joins: MapSet.new(["#managed"])
    }

    payload = %{
      type: :fail,
      command: "JOIN",
      context: [],
      description: "JOIN is unavailable"
    }

    returned = JoinFailureEvents.standard_reply(state, payload)

    assert returned.pending_commands == %{}
    refute MapSet.member?(returned.pending_joins, "#managed")
    refute MapSet.member?(returned.sent_joins, "#managed")
    assert MembershipLookup.get!(user, membership.id).status == "error"
    assert Repo.get!(Ircpipe.Chat.Message, invocation.id).metadata["command_status"] == "failed"

    refute Enum.any?(
             MessageHistory.list_buffer_messages(user, "server:#{connection.id}"),
             &(&1.kind == "error")
           )
  end

  defp state_fixture do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "join failures",
        "host" => "irc.example.test",
        "port" => 6697,
        "use_tls" => true,
        "nickname" => "mira"
      })

    state = %{
      active_casemapping: :ascii,
      connection: connection,
      pending_commands: %{},
      pending_joins: MapSet.new(),
      sent_joins: MapSet.new()
    }

    {user, connection, state}
  end
end
