defmodule TopicsClubWeb.Api.NotificationEligibilityControllerTest do
  use TopicsClubWeb.ConnCase, async: true

  alias TopicsClub.Accounts.UserToken
  alias TopicsClub.Chat
  alias TopicsClub.Chat.Connections
  alias TopicsClub.Chat.Notification
  alias TopicsClub.Chat.MessageIngestion
  alias TopicsClub.Chat.ReadState
  alias TopicsClub.Repo

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
    assert ["no-store"] = get_resp_header(eligible, "cache-control")

    assert :ok = ReadState.mark(user, membership)

    ineligible =
      get(
        conn,
        ~p"/api/notifications/#{notification.id}/eligibility?#{%{session_generation: generation}}"
      )

    assert %{"eligible" => false} = json_response(ineligible, 200)
    assert ["no-store"] = get_resp_header(ineligible, "cache-control")
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
    assert ["no-store"] = get_resp_header(malformed, "cache-control")

    generation = conn |> get_session(:user_token) |> UserToken.session_token_fingerprint()

    oversized =
      get(
        conn,
        ~p"/api/notifications/999999999999999999999999999999999999/eligibility?#{%{session_generation: generation}}"
      )

    assert %{"eligible" => false} = json_response(oversized, 200)
  end

  defp mention_notification(user) do
    {:ok, connection} =
      Connections.create(user, %{
        "name" => "server-#{System.unique_integer([:positive])}",
        "host" => "irc.example.test",
        "port" => 6697,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    {:ok, message} = MessageIngestion.record_channel(connection, "#elixir", "akash", "mira: ping")

    {membership, Repo.get_by!(Notification, message_id: message.id)}
  end
end
