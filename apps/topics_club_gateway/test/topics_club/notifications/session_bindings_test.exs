defmodule TopicsClub.Notifications.SessionBindingsTest do
  use TopicsClubWeb.DataCase, async: true

  alias TopicsClub.Accounts
  alias TopicsClub.Accounts.UserToken
  alias TopicsClub.AccountsFixtures

  alias TopicsClub.Notifications.{PushRegistrations, SessionBindings}

  alias TopicsClub.Repo

  setup do
    user = AccountsFixtures.user_fixture()
    scope = AccountsFixtures.user_scope_fixture(user)
    %{scope: scope}
  end

  test "reports only a currently authenticated notification account", %{scope: scope} do
    session_token = Accounts.generate_user_session_token(scope.user)

    assert %{
             user_id: user_id,
             session_generation: session_generation
           } = SessionBindings.notification_account(scope, session_token)

    assert user_id == scope.user.id
    assert session_generation == UserToken.session_token_fingerprint(session_token)

    assert :ok = Accounts.delete_user_session_token(session_token)

    assert %{user_id: nil, session_generation: nil} =
             SessionBindings.notification_account(scope, session_token)

    assert %{user_id: nil, session_generation: nil} =
             SessionBindings.notification_account(nil, nil)
  end

  test "rotates a session and keeps its push registration on the new token", %{scope: scope} do
    session_token = Accounts.generate_user_session_token(scope.user)

    assert {:ok, registration} =
             PushRegistrations.register(scope, session_token, subscription_attrs())

    assert {:ok, %{session_token: next_token, rebound_count: 1}} =
             SessionBindings.rotate(scope, session_token)

    refute Repo.get_by(UserToken, token: session_token, context: "session")
    next_user_token = Repo.get_by!(UserToken, token: next_token, context: "session")
    assert Repo.reload(registration).user_token_id == next_user_token.id
  end

  test "rejects rotation after the authenticated session expires", %{scope: scope} do
    session_token = Accounts.generate_user_session_token(scope.user)
    assert :ok = Accounts.delete_user_session_token(session_token)

    assert {:error, :invalid_session} = SessionBindings.rotate(scope, session_token)
  end

  defp subscription_attrs do
    {public_key, _private_key} = :crypto.generate_key(:ecdh, :prime256v1)

    %{
      "installation_id" => "session-binding-browser",
      "endpoint" => "https://push.example.test/subscription/session-binding",
      "p256dh" => Base.url_encode64(public_key, padding: false),
      "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    }
  end
end
