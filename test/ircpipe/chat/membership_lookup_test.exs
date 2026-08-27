defmodule Ircpipe.Chat.MembershipLookupTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.{Connections, MembershipLookup}

  test "loads memberships only for their owner" do
    user = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")

    assert MembershipLookup.get!(user, membership.id).id == membership.id

    assert MembershipLookup.get_by_channel!(user, connection, "#elixir").id ==
             membership.id

    assert_raise Ecto.NoResultsError, fn ->
      MembershipLookup.get!(other_user, membership.id)
    end

    assert_raise Ecto.NoResultsError, fn ->
      MembershipLookup.get_by_channel!(other_user, connection, "#elixir")
    end
  end

  test "finds memberships with explicit and stored IRC casemapping" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, connection} = Chat.update_connection_casemapping(connection, :ascii)
    {:ok, membership} = Chat.request_channel_join(user, connection, "#[Pipe]", :ascii)

    assert MembershipLookup.find_by_channel(connection, "#[PIPE]", :ascii).id == membership.id
    assert MembershipLookup.get_by_channel!(user, connection, "#[PIPE]").id == membership.id

    assert MembershipLookup.find_by_channel(connection, "#" <> "{pipe}", :rfc1459).id ==
             membership.id

    assert MembershipLookup.find_by_channel(connection, "#" <> "{pipe}", :ascii) == nil
  end

  defp connection_fixture(user) do
    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    connection
  end
end
