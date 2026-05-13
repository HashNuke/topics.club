defmodule IrcpipeWeb.Api.MessageControllerTest do
  use IrcpipeWeb.ConnCase, async: true

  alias Ircpipe.Chat
  alias Ircpipe.Chat.Message
  alias Ircpipe.Repo

  setup :register_and_log_in_user

  test "returns latest channel buffer messages with a capped limit", %{conn: conn, user: user} do
    {_connection, membership} = joined_channel(user)

    old = insert_message(user, membership, "old", ~U[2026-05-13 09:00:00Z])
    newer = insert_message(user, membership, "newer", ~U[2026-05-13 09:01:00Z])

    newest =
      insert_message(user, membership, "newest", ~U[2026-05-13 09:02:00Z], %{
        hostmask: "akash!user@example.test",
        sender_role: "op"
      })

    conn = get(conn, ~p"/api/buffers/#{buffer_id(membership)}/messages?limit=2")

    assert %{"messages" => messages} = json_response(conn, 200)
    assert Enum.map(messages, & &1["id"]) == [newer.id, newest.id]
    assert Enum.map(messages, & &1["body"]) == ["newer", "newest"]
    assert Enum.all?(messages, &(&1["buffer_id"] == buffer_id(membership)))
    assert Enum.all?(messages, &(&1["type"] == "buffer:message"))
    assert Enum.all?(messages, &(&1["version"] == 1))
    assert Enum.all?(messages, &String.starts_with?(&1["event_id"], "message:"))
    assert List.last(messages)["hostmask"] == "akash!user@example.test"
    assert List.last(messages)["sender_role"] == "op"
    refute Enum.any?(messages, &(&1["id"] == old.id))
  end

  test "returns older channel buffer messages before a cursor", %{conn: conn, user: user} do
    {_connection, membership} = joined_channel(user)

    oldest = insert_message(user, membership, "oldest", ~U[2026-05-13 09:00:00Z])
    older = insert_message(user, membership, "older", ~U[2026-05-13 09:01:00Z])
    cursor = insert_message(user, membership, "cursor", ~U[2026-05-13 09:02:00Z])
    _newest = insert_message(user, membership, "newest", ~U[2026-05-13 09:03:00Z])

    conn =
      get(
        conn,
        ~p"/api/buffers/#{buffer_id(membership)}/messages?before=#{cursor.id}&limit=50"
      )

    assert %{"messages" => messages} = json_response(conn, 200)
    assert Enum.map(messages, & &1["id"]) == [oldest.id, older.id]
  end

  test "returns server buffer message history", %{
    conn: conn,
    user: user
  } do
    {connection, _membership} = joined_channel(user)
    Chat.record_server_message(connection, "Connected to local")

    conn = get(conn, ~p"/api/buffers/server:#{connection.id}/messages")

    assert %{"messages" => [%{"buffer_id" => buffer_id, "body" => "Connected to local"}]} =
             json_response(conn, 200)

    assert buffer_id == "server:#{connection.id}"
  end

  defp joined_channel(user) do
    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    {%{connection | channel_memberships: [membership]}, membership}
  end

  defp insert_message(user, membership, body, occurred_at, attrs \\ %{}) do
    %Message{
      user_id: user.id,
      server_connection_id: membership.server_connection_id,
      channel_membership_id: membership.id
    }
    |> Message.changeset(
      Map.merge(
        %{
          kind: "message",
          nick: "akash",
          body: body,
          occurred_at: occurred_at
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp buffer_id(membership), do: "channel:#{membership.id}"
end
