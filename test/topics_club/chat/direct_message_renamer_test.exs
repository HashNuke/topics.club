defmodule TopicsClub.Chat.DirectMessageRenamerTest do
  use TopicsClub.DataCase, async: true

  alias TopicsClub.AccountsFixtures

  alias TopicsClub.Chat.{
    Connections,
    DirectMessageLifecycle,
    DirectMessageRenamer,
    DirectMessageThread
  }

  alias TopicsClub.Repo

  test "renames an existing peer while preserving its thread identity" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, thread} = DirectMessageLifecycle.open(user, connection, "akash")

    assert {:ok, renamed} =
             DirectMessageRenamer.rename(
               connection,
               "akash",
               "mira",
               %{account: "account-a", hostmask: "mira!a@example.test"},
               :rfc1459
             )

    assert renamed.id == thread.id
    assert renamed.peer_nick == "mira"
    assert renamed.peer_key == "mira"
    assert renamed.account == "account-a"
    assert renamed.hostmask == "mira!a@example.test"
  end

  test "does not rename or publish after deletion is marked" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, thread} = DirectMessageLifecycle.open(user, connection, "akash")
    Phoenix.PubSub.subscribe(TopicsClub.PubSub, "user:#{user.id}")

    connection
    |> Ecto.Changeset.change(deleting: true)
    |> Repo.update!()

    assert {:error, :connection_deleting} =
             DirectMessageRenamer.rename(connection, "akash", "too-late")

    assert Repo.get!(DirectMessageThread, thread.id).peer_nick == "akash"
    refute_receive {:direct_message_thread, _event}
  end

  test "rejects an outer transaction before rename or publication" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, thread} = DirectMessageLifecycle.open(user, connection, "akash")
    Phoenix.PubSub.subscribe(TopicsClub.PubSub, "user:#{user.id}")

    assert {:ok, :committed} =
             Repo.transaction(fn ->
               assert_raise ArgumentError, ~r/existing transaction/, fn ->
                 DirectMessageRenamer.rename(connection, "akash", "too-late")
               end

               :committed
             end)

    assert Repo.get!(DirectMessageThread, thread.id).peer_nick == "akash"
    refute_receive {:direct_message_thread, _event}
  end

  defp connection_fixture(user) do
    {:ok, connection} =
      Connections.create(user, %{
        "name" => "renamer-test",
        "host" => "irc.example.com",
        "nickname" => "local"
      })

    connection
  end
end
