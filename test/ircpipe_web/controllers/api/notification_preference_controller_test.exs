defmodule IrcpipeWeb.Api.NotificationPreferenceControllerTest do
  use IrcpipeWeb.ConnCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.{ChannelMembership, ServerConnection}
  alias Ircpipe.Repo

  setup :register_and_log_in_user

  test "updates server and channel mention preferences", %{conn: conn, user: user} do
    {connection, membership} = connection_with_channel(user)

    server_conn =
      put(conn, ~p"/api/connections/#{connection.id}/notification_preferences", %{
        mention_notifications_enabled: false
      })

    assert %{
             "preference" => %{
               "scope" => "server",
               "id" => server_id,
               "mention_notifications_enabled" => false
             }
           } = json_response(server_conn, 200)

    assert server_id == connection.id
    refute Repo.get!(ServerConnection, connection.id).mention_notifications_enabled

    channel_conn =
      put(conn, ~p"/api/channel_memberships/#{membership.id}/notification_preferences", %{
        mention_notifications_enabled: false
      })

    assert %{
             "preference" => %{
               "scope" => "channel",
               "id" => membership_id,
               "mention_notifications_enabled" => false
             }
           } = json_response(channel_conn, 200)

    assert membership_id == membership.id
    refute Repo.get!(ChannelMembership, membership.id).mention_notifications_enabled
  end

  test "does not expose another user's notification scopes", %{conn: conn} do
    other_user = AccountsFixtures.user_fixture()
    {connection, membership} = connection_with_channel(other_user)

    server_conn =
      put(conn, ~p"/api/connections/#{connection.id}/notification_preferences", %{
        mention_notifications_enabled: false
      })

    assert %{"error" => "notification_scope_not_found"} = json_response(server_conn, 404)

    channel_conn =
      put(conn, ~p"/api/channel_memberships/#{membership.id}/notification_preferences", %{
        mention_notifications_enabled: false
      })

    assert %{"error" => "notification_scope_not_found"} = json_response(channel_conn, 404)
  end

  test "rejects non-boolean preference values", %{conn: conn, user: user} do
    {connection, _membership} = connection_with_channel(user)

    conn =
      put(conn, ~p"/api/connections/#{connection.id}/notification_preferences", %{
        mention_notifications_enabled: "false"
      })

    assert %{"error" => "invalid_notification_preference"} = json_response(conn, 422)
  end

  test "treats malformed scope IDs as missing", %{conn: conn} do
    conn =
      put(conn, ~p"/api/connections/not-an-id/notification_preferences", %{
        mention_notifications_enabled: false
      })

    assert %{"error" => "notification_scope_not_found"} = json_response(conn, 404)
  end

  defp connection_with_channel(user) do
    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "server-#{System.unique_integer([:positive])}",
        "host" => "irc.example.test",
        "port" => 6697,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    {connection, membership}
  end
end
