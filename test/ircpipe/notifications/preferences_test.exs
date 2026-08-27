defmodule Ircpipe.Notifications.PreferencesTest do
  use Ircpipe.DataCase, async: false

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.Connections
  alias Ircpipe.Notifications.Preferences
  alias Ircpipe.Repo

  setup do
    previous_pause = Application.get_env(:ircpipe, :pause_notification_preference_broadcast)

    previous_effects_barrier =
      Application.get_env(:ircpipe, :connection_effects_before_lock_barrier)

    on_exit(fn ->
      restore_env(:pause_notification_preference_broadcast, previous_pause)
      restore_env(:connection_effects_before_lock_barrier, previous_effects_barrier)
    end)

    user = AccountsFixtures.user_fixture()
    scope = AccountsFixtures.user_scope_fixture(user)

    {:ok, connection} =
      Connections.create(user, %{
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
      Connections.create(other_user, %{
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

  test "rejects preference updates after connection deletion is marked", context do
    %{scope: scope, connection: connection, membership: membership} = context
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{scope.user.id}")

    connection
    |> Ecto.Changeset.change(deleting: true)
    |> Repo.update!()

    assert {:error, :connection_deleting} =
             Preferences.update_server(scope, connection.id, false)

    assert {:error, :connection_deleting} =
             Preferences.update_channel(scope, membership.id, false)

    assert Repo.reload!(connection).notification_preference_revision == 0
    assert Repo.reload!(membership).notification_preference_revision == 0
    refute_received {:notification_preference, _payload}
  end

  test "rejects preference updates inside an outer transaction", context do
    %{scope: scope, connection: connection, membership: membership} = context
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{scope.user.id}")

    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               assert_raise ArgumentError,
                            ~r/cannot update notification preferences inside an existing transaction/,
                            fn ->
                              Preferences.update_server(scope, connection.id, false)
                            end

               assert_raise ArgumentError,
                            ~r/cannot update notification preferences inside an existing transaction/,
                            fn ->
                              Preferences.update_channel(scope, membership.id, false)
                            end

               Repo.rollback(:forced_rollback)
             end)

    assert Repo.reload!(connection).notification_preference_revision == 0
    assert Repo.reload!(membership).notification_preference_revision == 0
    refute_received {:notification_preference, _payload}
  end

  test "completed deletion between a preference commit and effects drops publication", context do
    %{scope: scope, connection: connection} = context
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{scope.user.id}")
    supervisor = start_supervised!(Task.Supervisor)
    effects_ref = make_ref()

    Application.put_env(
      :ircpipe,
      :connection_effects_before_lock_barrier,
      {self(), effects_ref}
    )

    update =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Preferences.update_server(scope, connection.id, false)
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), update.pid)

    assert_receive {:connection_effects_paused, effects_pid, ^effects_ref, connection_id}, 5_000
    assert connection_id == connection.id
    assert Repo.reload!(connection).notification_preference_revision == 1

    assert {:ok, deleted} = Connections.delete(scope.user, connection.id)
    assert deleted.id == connection.id

    send(effects_pid, {:continue_connection_effects, effects_ref})
    assert {:ok, updated} = Task.await(update, 5_000)
    assert updated.notification_preference_revision == 1
    refute_received {:notification_preference, _payload}
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

    second =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Preferences.update_server(scope, connection.id, true)
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), second.pid)
    refute Task.yield(second, 100)

    send(first_pid, {:continue_notification_preference_broadcast, 1})
    assert {:ok, delayed} = Task.await(first)
    assert delayed.notification_preference_revision == 1

    assert_receive {:notification_preference,
                    %{id: ^connection_id, mention_notifications_enabled: false, revision: 1}}

    assert {:ok, latest} = Task.await(second)
    assert latest.notification_preference_revision == 2

    assert_receive {:notification_preference,
                    %{id: ^connection_id, mention_notifications_enabled: true, revision: 2}}

    stored = Repo.get!(Ircpipe.Chat.ServerConnection, connection.id)
    assert stored.mention_notifications_enabled
    assert stored.notification_preference_revision == 2
  end

  defp restore_env(key, nil), do: Application.delete_env(:ircpipe, key)
  defp restore_env(key, value), do: Application.put_env(:ircpipe, key, value)
end
