defmodule Ircpipe.Chat.ConnectionLifecycleTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat.ConnectionLifecycle
  alias Ircpipe.Chat.Connections

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
end
