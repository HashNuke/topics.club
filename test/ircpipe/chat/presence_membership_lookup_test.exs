defmodule Ircpipe.Chat.PresenceMembershipLookupTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures

  alias Ircpipe.Chat.{
    Connections,
    Presence,
    PresenceMembershipLookup
  }

  setup do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "presence lookup",
        "host" => "irc.presence-lookup.test",
        "nickname" => "mira"
      })

    {:ok, equivalent_membership} = Ircpipe.Chat.join_channel(user, connection, "#[ops]")
    {:ok, other_membership} = Ircpipe.Chat.join_channel(user, connection, "#other")

    :ok = Presence.sync(connection, "#[ops]", [%{nick: "[Mira]", prefixes: []}], :rfc1459)
    :ok = Presence.sync(connection, "#other", [%{nick: "Other", prefixes: []}], :rfc1459)

    %{
      connection: connection,
      equivalent_membership: equivalent_membership,
      other_membership: other_membership
    }
  end

  test "finds and lists joined memberships by canonical channel identity", %{
    connection: connection,
    equivalent_membership: equivalent_membership,
    other_membership: other_membership
  } do
    assert PresenceMembershipLookup.find(connection, "#" <> "{ops}", :rfc1459, "joined").id ==
             equivalent_membership.id

    assert Enum.map(PresenceMembershipLookup.list(connection, nil, :rfc1459), & &1.id)
           |> Enum.sort() == Enum.sort([equivalent_membership.id, other_membership.id])

    assert [found] = PresenceMembershipLookup.list(connection, "#" <> "{OPS}", :rfc1459)
    assert found.id == equivalent_membership.id
    assert PresenceMembershipLookup.list(connection, "#missing", :rfc1459) == []
  end

  test "finds joined memberships containing a canonical nick", %{
    connection: connection,
    equivalent_membership: equivalent_membership
  } do
    assert [found] = PresenceMembershipLookup.with_nick(connection, "{MIRA}", :rfc1459)
    assert found.id == equivalent_membership.id
    assert PresenceMembershipLookup.with_nick(connection, "missing", :rfc1459) == []
  end
end
