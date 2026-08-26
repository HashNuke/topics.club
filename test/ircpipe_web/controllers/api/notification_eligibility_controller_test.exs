defmodule IrcpipeWeb.Api.NotificationEligibilityControllerTest do
  use IrcpipeWeb.ConnCase, async: true

  alias Ircpipe.Accounts.UserToken
  alias Ircpipe.Chat
  alias Ircpipe.Chat.Notification
  alias Ircpipe.Repo

  setup :register_and_log_in_user

  test "checks the authenticated session and current mention state", %{conn: conn, user: user} do
    {membership, notification} = mention_notification(user)
    generation = conn |> get_session(:user_token) |> UserToken.session_token_fingerprint()

    eligible =
      get(
        conn,
        ~p"/api/notifications/#{notification.id}/eligibility?#{%{session_generation: generation}}"
      )

    assert %{"eligible" => true} = json_response(eligible, 200)

    assert :ok = Chat.mark_read(user, membership)

    ineligible =
      get(
        conn,
        ~p"/api/notifications/#{notification.id}/eligibility?#{%{session_generation: generation}}"
      )

    assert %{"eligible" => false} = json_response(ineligible, 200)
  end

  test "fails closed for anonymous, stale-generation, and malformed requests", %{
    conn: conn,
    user: user
  } do
    {_membership, notification} = mention_notification(user)

    anonymous =
      get(
        build_conn(),
        ~p"/api/notifications/#{notification.id}/eligibility?#{%{session_generation: "stale"}}"
      )

    assert %{"eligible" => false} = json_response(anonymous, 200)

    stale =
      get(
        conn,
        ~p"/api/notifications/#{notification.id}/eligibility?#{%{session_generation: "stale"}}"
      )

    assert %{"eligible" => false} = json_response(stale, 200)

    malformed =
      get(
        conn,
        ~p"/api/notifications/not-an-id/eligibility?#{%{session_generation: "stale"}}"
      )

    assert %{"eligible" => false} = json_response(malformed, 200)
  end

  defp mention_notification(user) do
    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "server-#{System.unique_integer([:positive])}",
        "host" => "irc.example.test",
        "port" => 6697,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    {:ok, message} = Chat.record_inbound_message(connection, "#elixir", "akash", "mira: ping")

    {membership, Repo.get_by!(Notification, message_id: message.id)}
  end
end
