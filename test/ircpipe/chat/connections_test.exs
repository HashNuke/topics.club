defmodule Ircpipe.Chat.ConnectionsTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat.ChannelMembership
  alias Ircpipe.Chat.Connections
  alias Ircpipe.Chat.ServerConnection
  alias Ircpipe.Repo

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
               "host" => " IRC.Renamed.Test "
             })

    assert updated.name == "renamed"
    assert updated.host == "irc.renamed.test"
  end

  test "reuses a normalized host and port but not a different port" do
    user = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture()

    assert {:ok, existing} =
             Connections.create(user, %{
               "name" => "primary",
               "host" => " IRC.Example.Test ",
               "port" => 6697,
               "use_tls" => true
             })

    assert existing.host == "irc.example.test"

    assert {:ok, reused} =
             Connections.create_or_get(user, %{
               "name" => "different display name",
               "host" => " irc.example.test ",
               "port" => 6697,
               "use_tls" => false
             })

    assert reused.id == existing.id

    assert {:ok, other_port} =
             Connections.create_or_get(user, %{
               "name" => "alternate port",
               "host" => "irc.example.test",
               "port" => 6667
             })

    refute other_port.id == existing.id

    assert {:ok, other_owner} =
             Connections.create_or_get(other_user, %{
               "name" => "other owner",
               "host" => "irc.example.test",
               "port" => 6697
             })

    refute other_owner.id == existing.id
  end

  test "rejects invalid and oversized ports without querying them" do
    user = AccountsFixtures.user_fixture()

    for port <- [0, 65_536, 2_147_483_648, "2147483648"] do
      assert {:error, changeset} =
               Connections.create_or_get(user, %{
                 "name" => "invalid-#{port}",
                 "host" => "irc.invalid.test",
                 "port" => port
               })

      assert "must be less than 65536" in errors_on(changeset).port or
               "must be greater than 0" in errors_on(changeset).port
    end

    assert Repo.aggregate(ServerConnection, :count) == 0
  end

  test "retains connection credentials while encrypting them at rest" do
    user = AccountsFixtures.user_fixture(%{email: "mira@example.com"})

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "authenticated",
               "host" => "irc.example.com",
               "nickname" => " ",
               "sasl_password" => "account-secret",
               "server_password" => "network-secret"
             })

    stored_connection = Repo.get!(ServerConnection, connection.id)

    assert stored_connection.nickname == "mira"
    assert stored_connection.sasl_username == "mira"
    assert stored_connection.sasl_password == "account-secret"
    assert stored_connection.server_password == "network-secret"

    assert %{rows: [[encrypted_server_password, encrypted_sasl_password]]} =
             Repo.query!(
               "SELECT server_password, sasl_password FROM server_connections WHERE id = $1",
               [connection.id]
             )

    refute encrypted_server_password == "network-secret"
    refute encrypted_sasl_password == "account-secret"
    assert Ircpipe.Vault.decrypt!(encrypted_server_password) == "network-secret"
    assert Ircpipe.Vault.decrypt!(encrypted_sasl_password) == "account-secret"
  end

  test "defaults the SASL account in atom-keyed connection attributes" do
    user = AccountsFixtures.user_fixture(%{email: "mira@example.com"})

    assert {:ok, connection} =
             Connections.create(user, %{
               name: "authenticated",
               host: "irc.example.com",
               nickname: "mira",
               sasl_password: "account-secret"
             })

    assert connection.sasl_username == "mira"

    assert {:ok, blank_nickname} =
             Connections.create(user, %{
               name: "blank nickname",
               host: "irc.blank.test",
               nickname: "   "
             })

    assert blank_nickname.nickname == "mira"

    assert {:ok, missing_nickname} =
             Connections.create(user, %{
               name: "missing nickname",
               host: "irc.missing.test"
             })

    assert missing_nickname.nickname == "mira"
  end
end
