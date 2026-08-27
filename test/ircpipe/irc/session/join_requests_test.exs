defmodule Ircpipe.Irc.Session.JoinRequestsTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.{Connections, ServerConnection}
  alias Ircpipe.Irc.Session.JoinRequests
  alias Ircpipe.Repo

  setup do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "join requests",
        "host" => "irc.example.test",
        "port" => 6697,
        "use_tls" => true,
        "nickname" => "mira"
      })

    state = %{
      connection: connection,
      client: nil,
      client_info: nil,
      registered?: false,
      join_validation_ready?: false,
      isupport_received?: false,
      pending_joins: MapSet.new(),
      joined_channels: MapSet.new(),
      sent_joins: MapSet.new()
    }

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    %{connection: connection, state: state, user: user}
  end

  test "persists and queues a join request while disconnected", context do
    assert {{:ok, membership, :queued}, returned} =
             JoinRequests.request(context.state, context.user, "#elixir")

    assert membership.channel == "#elixir"
    assert membership.status == "pending"
    assert membership.auto_join
    assert MapSet.member?(returned.pending_joins, "#elixir")

    persisted = Repo.get!(Ircpipe.Chat.ChannelMembership, membership.id)
    assert persisted.status == "pending"
    assert persisted.auto_join
  end

  test "returns the existing pending membership idempotently", context do
    assert {{:ok, membership, :queued}, state} =
             JoinRequests.request(context.state, context.user, "#elixir")

    assert {{:ok, duplicate, :queued}, returned} =
             JoinRequests.request(state, context.user, "#ELIXIR")

    assert duplicate.id == membership.id
    assert returned == state
  end

  test "rejects a user who does not own the connection", context do
    other_user = AccountsFixtures.user_fixture()

    assert {{:error, :invalid_connection}, returned} =
             JoinRequests.request(context.state, other_user, "#private")

    assert returned == context.state
    assert Repo.get!(ServerConnection, context.connection.id).user_id == context.user.id

    assert {{:ok, _membership, :queued}, pending_state} =
             JoinRequests.request(context.state, context.user, "#pending")

    assert {{:error, :invalid_connection}, returned} =
             JoinRequests.request(pending_state, other_user, "#pending")

    assert returned == pending_state
  end

  test "reports state-only pending joins that have no persisted membership", context do
    state = %{context.state | pending_joins: MapSet.new(["#missing"])}

    assert {{:error, :already_pending}, returned} =
             JoinRequests.request(state, context.user, "#missing")

    assert returned == state
  end

  test "rejects the persisted membership when immediate transmission fails", context do
    client = start_supervised!({Ircpipe.FailingIrcClient, :closed})

    state = %{
      context.state
      | client: client,
        registered?: true,
        join_validation_ready?: true
    }

    assert {{:error, :closed}, returned} =
             JoinRequests.request(state, context.user, "#elixir")

    assert returned == state

    rejected = Chat.get_channel_membership(context.connection, "#elixir", :ascii)
    assert rejected.status == "error"
    refute rejected.auto_join
    assert rejected.last_error == "{:error, :closed}"
    refute MapSet.member?(returned.pending_joins, "#elixir")

    assert_receive {:buffer_left, %{channel_membership_id: membership_id}}
    assert membership_id == rejected.id
  end
end
