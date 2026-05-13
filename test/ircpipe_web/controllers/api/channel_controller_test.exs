defmodule IrcpipeWeb.Api.ChannelControllerTest do
  use IrcpipeWeb.ConnCase, async: true

  alias Ircpipe.Chat
  alias Ircpipe.Repo

  setup :register_and_log_in_user

  test "marks a channel membership read through the API", %{conn: conn, user: user} do
    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")

    membership =
      membership |> Ecto.Changeset.change(unread_count: 3, mention_count: 1) |> Repo.update!()

    conn = post(conn, ~p"/api/channels/#{membership.id}/read")

    assert json_response(conn, 200) == %{"ok" => true}

    reloaded = Chat.get_membership!(user, membership.id)
    assert reloaded.unread_count == 0
    assert reloaded.mention_count == 0
  end

  test "leaves a channel membership through the API", %{conn: conn, user: user} do
    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")

    conn = post(conn, ~p"/api/channel_memberships/#{membership.id}/leave")

    assert %{
             "left" => %{
               "type" => "buffer:left",
               "version" => 1,
               "event_id" => "buffer_left:" <> _,
               "occurred_at" => _occurred_at,
               "buffer_id" => buffer_id,
               "channel_membership_id" => membership_id
             }
           } = json_response(conn, 200)

    assert buffer_id == "channel:#{membership.id}"
    assert membership_id == membership.id
    assert_raise Ecto.NoResultsError, fn -> Chat.get_membership!(user, membership.id) end
  end

  test "does not leave another user's channel membership", %{conn: conn} do
    other_user = Ircpipe.AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(other_user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "other"
      })

    {:ok, membership} = Chat.join_channel(other_user, connection, "#private")

    assert_error_sent 404, fn ->
      post(conn, ~p"/api/channel_memberships/#{membership.id}/leave")
    end
  end
end
