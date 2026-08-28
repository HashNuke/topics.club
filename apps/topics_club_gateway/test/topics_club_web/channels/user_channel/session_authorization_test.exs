defmodule TopicsClubWeb.UserChannel.SessionAuthorizationTest do
  use TopicsClubWeb.DataCase, async: true

  alias TopicsClub.Accounts
  alias TopicsClub.Accounts.UserToken
  alias TopicsClub.AccountsFixtures
  alias TopicsClubWeb.UserChannel.SessionAuthorization

  test "authorizes only the matching user with a live session token" do
    user = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture()
    token = Accounts.generate_user_session_token(user)
    socket = %{assigns: %{current_user: user, session_token: token}}

    assert SessionAuthorization.authorized?(socket, Integer.to_string(user.id))
    refute SessionAuthorization.authorized?(socket, Integer.to_string(other_user.id))

    other_token = Accounts.generate_user_session_token(other_user)

    refute SessionAuthorization.authorized?(
             put_in(socket.assigns.session_token, other_token),
             Integer.to_string(user.id)
           )

    Accounts.delete_user_session_token(token)
    refute SessionAuthorization.authorized?(socket, Integer.to_string(user.id))
  end

  test "rejects a socket without a session token" do
    user = AccountsFixtures.user_fixture()
    socket = %{assigns: %{current_user: user}}

    refute SessionAuthorization.authorized?(socket, Integer.to_string(user.id))
  end

  test "schedules immediate validation when the session deadline has passed" do
    socket = %{
      assigns: %{
        session_token_inserted_at: DateTime.utc_now(:second) |> DateTime.add(-15, :day)
      }
    }

    assert is_reference(SessionAuthorization.schedule_expiration(socket))
    assert_receive :validate_auth_session
  end

  test "schedules validation at the future session deadline" do
    inserted_at = DateTime.utc_now(:second)
    socket = %{assigns: %{session_token_inserted_at: inserted_at}}

    timer = SessionAuthorization.schedule_expiration(socket)
    remaining = Process.read_timer(timer)

    expected_remaining =
      inserted_at
      |> UserToken.session_token_expires_at()
      |> DateTime.diff(DateTime.utc_now(:millisecond), :millisecond)

    assert_in_delta remaining, expected_remaining, 1_000
    assert is_integer(Process.cancel_timer(timer))
  end
end
