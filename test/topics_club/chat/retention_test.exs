defmodule TopicsClub.Chat.RetentionTest do
  use TopicsClub.DataCase, async: true

  alias TopicsClub.AccountsFixtures
  alias TopicsClub.Chat
  alias TopicsClub.Chat.Connections
  alias TopicsClub.Chat.{Message, Retention}
  alias TopicsClub.Repo

  test "updates retention days within the supported one-to-three-day range" do
    user = AccountsFixtures.user_fixture()

    assert {:ok, %{message_retention_days: 2}} = Retention.update_days(user, "2")
    assert {:ok, %{message_retention_days: 3}} = Retention.update_days(user, "9")
    assert {:ok, %{message_retention_days: 1}} = Retention.update_days(user, 0)
    assert {:ok, %{message_retention_days: 3}} = Retention.update_days(user, "invalid")
  end

  test "prunes only the user's messages older than their retention window" do
    user = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture()
    {:ok, user} = Retention.update_days(user, 1)
    user_membership = membership_fixture(user, "user")
    other_membership = membership_fixture(other_user, "other")
    now = ~U[2026-08-26 12:00:00Z]
    cutoff = DateTime.add(now, -1, :day)

    expired = insert_message(user, user_membership, "expired", DateTime.add(cutoff, -1, :second))
    at_cutoff = insert_message(user, user_membership, "at cutoff", cutoff)
    retained = insert_message(user, user_membership, "retained", now)

    other_expired =
      insert_message(other_user, other_membership, "other expired", DateTime.add(now, -2, :day))

    assert {1, nil} = Retention.prune(user, now)
    assert is_nil(Repo.get(Message, expired.id))
    assert Repo.get!(Message, at_cutoff.id)
    assert Repo.get!(Message, retained.id)
    assert Repo.get!(Message, other_expired.id)
  end

  defp membership_fixture(user, name) do
    {:ok, connection} =
      Connections.create(user, %{
        "name" => name,
        "host" => "irc.example.test",
        "port" => 6697,
        "use_tls" => true,
        "nickname" => name
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    membership
  end

  defp insert_message(user, membership, body, occurred_at) do
    %Message{
      user_id: user.id,
      server_connection_id: membership.server_connection_id,
      channel_membership_id: membership.id
    }
    |> Message.changeset(%{
      kind: "message",
      nick: "akash",
      body: body,
      occurred_at: occurred_at
    })
    |> Repo.insert!()
  end
end
