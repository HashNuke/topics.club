defmodule Ircpipe.Notifications.PreferencesTest do
  use Ircpipe.DataCase, async: false

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Notifications.Preferences
  alias Ircpipe.Repo

  setup do
    previous_pause = Application.get_env(:ircpipe, :pause_notification_preference_broadcast)

    on_exit(fn ->
      if is_nil(previous_pause) do
        Application.delete_env(:ircpipe, :pause_notification_preference_broadcast)
      else
        Application.put_env(:ircpipe, :pause_notification_preference_broadcast, previous_pause)
      end
    end)

    user = AccountsFixtures.user_fixture()
    scope = AccountsFixtures.user_scope_fixture(user)

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "Libera",
        "host" => "irc.example.test",
        "port" => 6697,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")

    %{scope: scope, connection: connection, membership: membership}
  end

  test "updates and broadcasts server and channel preferences", context do
    %{scope: scope, connection: connection, membership: membership} = context
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{scope.user.id}")

    assert {:ok, server} = Preferences.update_server(scope, connection.id, false)
    refute server.mention_notifications_enabled
    assert server.notification_preference_revision == 1

    assert_receive {:notification_preference,
                    %{
                      scope: "server",
                      id: server_id,
                      mention_notifications_enabled: false,
                      revision: 1
                    }}

    assert server_id == connection.id

    assert {:ok, channel} = Preferences.update_channel(scope, membership.id, false)
    refute channel.mention_notifications_enabled
    assert channel.notification_preference_revision == 1

    assert_receive {:notification_preference,
                    %{
                      scope: "channel",
                      id: channel_id,
                      mention_notifications_enabled: false,
                      revision: 1
                    }}

    assert channel_id == membership.id
  end

  test "does not update another user's preference scopes", %{scope: scope} do
    other_user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(other_user, %{
        "name" => "Other",
        "host" => "irc.other.test",
        "port" => 6697,
        "nickname" => "other"
      })

    {:ok, membership} = Chat.join_channel(other_user, connection, "#private")

    assert_raise Ecto.NoResultsError, fn ->
      Preferences.update_server(scope, connection.id, false)
    end

    assert_raise Ecto.NoResultsError, fn ->
      Preferences.update_channel(scope, membership.id, false)
    end
  end

  test "revision broadcasts remain ordered when an older update is delayed", context do
    %{scope: scope, connection: connection} = context
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{scope.user.id}")
    Application.put_env(:ircpipe, :pause_notification_preference_broadcast, {self(), 1})
    supervisor = start_supervised!(Task.Supervisor)

    first =
      Task.Supervisor.async_nolink(supervisor, fn ->
        receive do
          :update_preference -> Preferences.update_server(scope, connection.id, false)
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), first.pid)
    send(first.pid, :update_preference)

    assert_receive {:notification_preference_broadcast_paused, first_pid, connection_id, 1}
    assert connection_id == connection.id

    assert {:ok, latest} = Preferences.update_server(scope, connection.id, true)
    assert latest.notification_preference_revision == 2

    assert_receive {:notification_preference,
                    %{id: ^connection_id, mention_notifications_enabled: true, revision: 2}}

    send(first_pid, {:continue_notification_preference_broadcast, 1})
    assert {:ok, delayed} = Task.await(first)
    assert delayed.notification_preference_revision == 1

    assert_receive {:notification_preference,
                    %{id: ^connection_id, mention_notifications_enabled: false, revision: 1}}

    stored = Repo.get!(Ircpipe.Chat.ServerConnection, connection.id)
    assert stored.mention_notifications_enabled
    assert stored.notification_preference_revision == 2
  end
end
