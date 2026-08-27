defmodule Ircpipe.Chat.ConnectionLifecycleTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat.ConnectionLifecycle
  alias Ircpipe.Chat.Connections
  alias Ircpipe.Repo

  setup do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "lifecycle",
        "host" => "irc.lifecycle.test",
        "nickname" => "mira"
      })

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    %{connection: connection}
  end

  test "updates status, records connected time, and broadcasts the stored state", %{
    connection: connection
  } do
    before_update = DateTime.utc_now(:second)

    assert {:ok, connected} = ConnectionLifecycle.update_status(connection, "connected")
    assert connected.status == "connected"
    assert DateTime.compare(connected.last_connected_at, before_update) in [:eq, :gt]

    assert_receive {:server_status,
                    %{
                      server_connection_id: connection_id,
                      nickname: "mira",
                      status: "connected"
                    }}

    assert connection_id == connection.id
  end

  test "does not persist or broadcast an invalid status", %{connection: connection} do
    assert {:error, changeset} = ConnectionLifecycle.update_status(connection, "invalid")
    assert "is invalid" in errors_on(changeset).status
    refute_receive {:server_status, _event}
  end

  test "touches connected time without changing status or broadcasting", %{connection: connection} do
    assert {:ok, touched} = ConnectionLifecycle.touch_connected(connection)
    assert touched.status == "disconnected"
    assert %DateTime{} = touched.last_connected_at
    refute_receive {:server_status, _event}
  end

  test "updates nickname and broadcasts an explicit transient status", %{connection: connection} do
    assert {:ok, updated} =
             ConnectionLifecycle.update_nickname(connection, "mira_", "connected")

    assert updated.nickname == "mira_"
    assert updated.status == "disconnected"

    assert_receive {:server_status, %{nickname: "mira_", status: "connected"}}
  end

  test "nickname broadcasts default to the stored status", %{connection: connection} do
    assert {:ok, updated} = ConnectionLifecycle.update_nickname(connection, "mira_")
    assert_receive {:server_status, %{nickname: "mira_", status: "disconnected"}}
    assert updated.status == "disconnected"
  end

  test "does not broadcast when the persisted nickname already matches", %{connection: connection} do
    assert {:ok, unchanged} = ConnectionLifecycle.update_nickname(connection, "mira", "connected")
    assert unchanged.nickname == "mira"
    refute_receive {:server_status, _event}
  end

  test "drops mutations and status publication after deletion is marked", %{
    connection: connection
  } do
    connection
    |> Ecto.Changeset.change(deleting: true)
    |> Repo.update!()

    assert {:error, :connection_deleting} =
             ConnectionLifecycle.update_status(connection, "connected")

    assert {:error, :connection_deleting} = ConnectionLifecycle.touch_connected(connection)

    assert {:error, :connection_deleting} =
             ConnectionLifecycle.update_nickname(connection, "too-late")

    assert {:error, :connection_deleting} =
             ConnectionLifecycle.broadcast_status(connection, "disconnected")

    stored = Repo.get!(Ircpipe.Chat.ServerConnection, connection.id)
    assert stored.status == "disconnected"
    assert stored.nickname == "mira"
    assert stored.last_connected_at == nil
    refute_receive {:server_status, _event}
  end

  test "rejects outer transactions before mutation or publication", %{connection: connection} do
    assert {:ok, :committed} =
             Repo.transaction(fn ->
               for callback <- [
                     fn -> ConnectionLifecycle.update_status(connection, "connected") end,
                     fn -> ConnectionLifecycle.touch_connected(connection) end,
                     fn -> ConnectionLifecycle.update_nickname(connection, "too-late") end,
                     fn -> ConnectionLifecycle.broadcast_status(connection, "connected") end
                   ] do
                 assert_raise ArgumentError, ~r/existing transaction/, callback
               end

               :committed
             end)

    stored = Repo.get!(Ircpipe.Chat.ServerConnection, connection.id)
    assert stored.status == "disconnected"
    assert stored.nickname == "mira"
    assert stored.last_connected_at == nil
    refute_receive {:server_status, _event}
  end
end
