defmodule Ircpipe.Chat.ChannelJoinRequestTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.{ChannelJoinRequest, Connections}

  test "creates and reuses a trimmed pending membership" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)

    assert {:ok, pending} = ChannelJoinRequest.request(user, connection, "  #Elixir  ")
    assert pending.channel == "#Elixir"
    assert pending.status == "pending"
    assert pending.auto_join

    assert {:ok, reused} = ChannelJoinRequest.request(user, connection, "#elixir")
    assert reused.id == pending.id
  end

  test "uses stored casemapping and rejects a connection owned by another user" do
    user = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, connection} = Chat.update_connection_casemapping(connection, :ascii)

    assert {:ok, pending} = ChannelJoinRequest.request(user, connection, "#[Ops]")
    assert {:ok, reused} = ChannelJoinRequest.request(user, connection, "#[OPS]")
    assert reused.id == pending.id

    assert ChannelJoinRequest.request(other_user, connection, "#private") ==
             {:error, :invalid_connection}
  end

  defp connection_fixture(user) do
    {:ok, connection} =
      Connections.create(user, %{
        "name" => "join request",
        "host" => "irc.example.test",
        "port" => 6697,
        "use_tls" => true,
        "nickname" => "mira"
      })

    connection
  end
end
