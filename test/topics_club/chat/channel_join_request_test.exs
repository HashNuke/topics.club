defmodule TopicsClub.Chat.ChannelJoinRequestTest do
  use TopicsClub.DataCase, async: true

  alias TopicsClub.AccountsFixtures

  alias TopicsClub.Chat.{
    ChannelJoinRequest,
    ConnectionCasemapping,
    Connections
  }

  test "creates and reuses a trimmed pending membership" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)

    assert {:ok, pending} = ChannelJoinRequest.request(user, connection, "  #Elixir  ")
    assert pending.channel == "#Elixir"
    assert pending.status == "pending"
    assert pending.auto_join
    assert {:ok, _uuid} = Ecto.UUID.cast(pending.join_attempt_id)

    assert {:ok, reused} = ChannelJoinRequest.request(user, connection, "#elixir")
    assert reused.id == pending.id
    assert reused.join_attempt_id == pending.join_attempt_id

    assert {:ok, rejected} =
             pending
             |> Ecto.Changeset.change(status: "error", last_error: "Invite only")
             |> Repo.update()

    assert rejected.status == "error"

    assert {:ok, retried} = ChannelJoinRequest.request(user, connection, "#elixir")
    assert retried.id == pending.id
    assert retried.join_attempt_id != pending.join_attempt_id
  end

  test "backfills a legacy pending membership before returning it" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    assert {:ok, pending} = ChannelJoinRequest.request(user, connection, "#legacy")

    pending =
      pending
      |> Ecto.Changeset.change(join_attempt_id: nil)
      |> Repo.update!()

    assert {:ok, backfilled} = ChannelJoinRequest.request(user, connection, "#legacy")
    assert backfilled.id == pending.id
    assert {:ok, _uuid} = Ecto.UUID.cast(backfilled.join_attempt_id)
  end

  test "starts a new durable attempt for joined channels on a fresh connection" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    assert {:ok, pending} = ChannelJoinRequest.request(user, connection, "#fresh")

    joined =
      pending
      |> Ecto.Changeset.change(status: "joined")
      |> Repo.update!()

    assert {:ok, [prepared]} = ChannelJoinRequest.prepare_for_fresh_connection(connection)
    assert prepared.id == joined.id
    assert prepared.status == "pending"
    assert prepared.join_attempt_id != joined.join_attempt_id

    assert {:ok, [retried]} = ChannelJoinRequest.prepare_for_fresh_connection(connection)
    assert retried.join_attempt_id == prepared.join_attempt_id
  end

  test "uses stored casemapping and rejects a connection owned by another user" do
    user = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, connection} = ConnectionCasemapping.update(connection, :ascii)

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
