defmodule Ircpipe.Chat.ConnectionActivityTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.Accounts.User
  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.Connections
  alias Ircpipe.Chat.ConnectionActivity
  alias Ircpipe.Repo

  test "partitions connections by their owner's last-seen time and preloads memberships" do
    cutoff = ~U[2026-08-26 12:00:00Z]
    active_user = user_seen_at(DateTime.add(cutoff, 1, :second))
    cutoff_user = user_seen_at(cutoff)
    inactive_user = user_seen_at(DateTime.add(cutoff, -1, :second))
    never_seen_user = AccountsFixtures.user_fixture()

    active_zulu = connection_fixture(active_user, "zulu")
    active_alpha = connection_fixture(active_user, "alpha")
    paused_connection = connection_fixture(active_user, "paused")
    cutoff_connection = connection_fixture(cutoff_user, "cutoff")
    inactive_connection = connection_fixture(inactive_user, "inactive")
    never_seen_connection = connection_fixture(never_seen_user, "never-seen")
    {:ok, membership} = Chat.join_channel(active_user, active_alpha, "#elixir")

    assert {:ok, paused_connection} =
             paused_connection
             |> Ecto.Changeset.change(desired_state: "paused")
             |> Repo.update()

    assert [recent_alpha, recent_zulu, recent_at_cutoff] =
             ConnectionActivity.recently_seen(cutoff)

    assert Enum.map([recent_alpha, recent_zulu, recent_at_cutoff], & &1.id) == [
             active_alpha.id,
             active_zulu.id,
             cutoff_connection.id
           ]

    assert Enum.map(recent_alpha.channel_memberships, & &1.id) == [membership.id]
    assert recent_zulu.channel_memberships == []
    assert recent_at_cutoff.channel_memberships == []

    refute paused_connection.id in Enum.map(
             ConnectionActivity.recently_seen(cutoff),
             & &1.id
           )

    assert Enum.map(ConnectionActivity.inactive(cutoff), & &1.id) == [
             inactive_connection.id,
             never_seen_connection.id
           ]
  end

  defp user_seen_at(last_seen_at) do
    user = AccountsFixtures.user_fixture()

    Repo.update_all(from(candidate in User, where: candidate.id == ^user.id),
      set: [last_seen_at: last_seen_at]
    )

    user
  end

  defp connection_fixture(user, name) do
    {:ok, connection} =
      Connections.create(user, %{
        "name" => name,
        "host" => "irc.example.test",
        "port" => 6697,
        "use_tls" => true,
        "nickname" => name
      })

    connection
  end
end
