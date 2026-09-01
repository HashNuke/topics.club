defmodule TopicsClub.Chat.ConnectionsTest do
  use TopicsClub.DataCase, async: true

  alias TopicsClub.AccountsFixtures
  alias TopicsClub.Chat
  alias TopicsClub.Chat.ChannelMembership
  alias TopicsClub.Chat.Connections
  alias TopicsClub.Repo

  test "creates, scopes, and updates a connection with safe defaults" do
    user = AccountsFixtures.user_fixture(%{email: "3dev@example.com"})
    other_user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "primary",
               "host" => "irc.example.test",
               "nickname" => " ",
               "sasl_password" => "account-secret"
             })

    assert connection.nickname == "u_3dev"
    assert connection.sasl_username == "u_3dev"
    assert connection.desired_state == "connected"
    assert connection.transport_revision == 1

    Repo.insert!(%ChannelMembership{
      channel: "#elixir",
      server_connection_id: connection.id,
      user_id: user.id
    })

    fetched = Connections.get!(user, connection.id)
    assert fetched.id == connection.id
    assert [%ChannelMembership{channel: "#elixir"}] = fetched.channel_memberships
    assert_raise Ecto.NoResultsError, fn -> Connections.get!(other_user, connection.id) end

    assert_raise Ecto.NoResultsError, fn ->
      Connections.update(other_user, connection.id, %{"name" => "stolen"})
    end

    assert {:ok, updated} =
             Connections.update(user, connection.id, %{
               "name" => "renamed",
               "host" => "irc.renamed.test",
               "sasl_username" => "someone_else",
               "port" => 6697,
               "nickname" => "mira2"
             })

    assert updated.name == "primary"
    assert updated.host == "irc.example.test"
    assert updated.sasl_username == "u_3dev"
    assert updated.port == 6697
    assert updated.nickname == "mira2"
    assert updated.transport_revision == 2

    assert {:ok, unchanged} =
             Connections.update(user, connection.id, %{
               "port" => 6697,
               "nickname" => "mira2"
             })

    assert unchanged.transport_revision == 2
  end

  test "defaults the SASL account when credentials are added to an existing connection" do
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "add sasl later",
               "host" => "irc.example.test",
               "nickname" => "mira"
             })

    assert connection.sasl_username == nil

    assert {:ok, updated} =
             Connections.update(user, connection.id, %{"sasl_password" => "account-secret"})

    assert updated.sasl_username == "mira"
    assert updated.sasl_password == "account-secret"
  end

  test "deletes an owned connection before broadcasting its buffers as left" do
    user = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "delete me",
               "host" => "irc.delete.test",
               "nickname" => "mira"
             })

    assert {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    Phoenix.PubSub.subscribe(TopicsClub.PubSub, "user:#{user.id}")

    assert_raise Ecto.NoResultsError, fn -> Connections.delete(other_user, connection.id) end
    refute_receive {:buffer_left, _event}
    assert Connections.get!(user, connection.id).id == connection.id

    assert {:ok, deleted} = Connections.delete(user, connection.id)
    assert deleted.id == connection.id
    assert_raise Ecto.NoResultsError, fn -> Connections.get!(user, connection.id) end

    assert_receive {:buffer_left,
                    %{
                      buffer_id: "channel:" <> _,
                      server_connection_id: connection_id,
                      channel_membership_id: membership_id
                    }}

    assert connection_id == connection.id
    assert membership_id == membership.id

    assert_receive {:buffer_left,
                    %{
                      buffer_id: "server:" <> _,
                      server_connection_id: ^connection_id,
                      channel_membership_id: nil
                    }}
  end

  test "rejects connection deletion from an outer transaction" do
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "transaction guard",
               "host" => "irc.transaction.test",
               "nickname" => "mira"
             })

    Phoenix.PubSub.subscribe(TopicsClub.PubSub, "user:#{user.id}")

    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               assert_raise ArgumentError, ~r/cannot delete inside an existing transaction/, fn ->
                 Connections.delete(user, connection.id)
               end

               Repo.rollback(:forced_rollback)
             end)

    refute_receive {:buffer_left, _event}
    assert Connections.get!(user, connection.id).id == connection.id
  end
end
