defmodule Ircpipe.Notifications.PushRegistrationsTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.Accounts
  alias Ircpipe.Accounts.UserToken
  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Notifications.{PushSubscription, PushRegistrations}
  alias Ircpipe.Repo

  setup do
    user = AccountsFixtures.user_fixture()
    scope = AccountsFixtures.user_scope_fixture(user)
    %{scope: scope}
  end

  test "stores one encrypted subscription per installation", %{scope: scope} do
    session_token = Accounts.generate_user_session_token(scope.user)
    attrs = subscription_attrs("https://push.example.test/subscription/one")

    assert {:ok, first} = PushRegistrations.register(scope, session_token, attrs, "test browser")
    assert first.endpoint == attrs["endpoint"]
    assert first.user_agent == "test browser"

    raw_endpoint =
      Repo.query!("SELECT endpoint FROM push_subscriptions WHERE id = $1", [first.id]).rows
      |> List.first()
      |> List.first()

    refute raw_endpoint == attrs["endpoint"]

    replacement_session_token = Accounts.generate_user_session_token(scope.user)

    assert {:ok, replacement} =
             PushRegistrations.register(
               scope,
               replacement_session_token,
               %{attrs | "endpoint" => "https://push.example.test/subscription/two"}
             )

    assert replacement.installation_id == first.installation_id
    assert Repo.aggregate(PushSubscription, :count) == 1

    assert :ok = PushRegistrations.unregister(scope, first.installation_id)
    assert Repo.aggregate(PushSubscription, :count) == 0
  end

  test "reports registration for the exact authenticated session", %{scope: scope} do
    session_token = Accounts.generate_user_session_token(scope.user)

    assert {:ok, _subscription} =
             PushRegistrations.register(
               scope,
               session_token,
               subscription_attrs("https://push.example.test/subscription/session-bootstrap")
             )

    assert %{
             session_generation: session_generation,
             session_installation_id: "browser-installation",
             session_registration_confirmed: true
           } = PushRegistrations.session_config(scope, session_token)

    assert session_generation == UserToken.session_token_fingerprint(session_token)

    other_session_token = Accounts.generate_user_session_token(scope.user)

    assert %{
             session_installation_id: nil,
             session_registration_confirmed: false
           } = PushRegistrations.session_config(scope, other_session_token)
  end

  defp subscription_attrs(endpoint) do
    {public_key, _private_key} = :crypto.generate_key(:ecdh, :prime256v1)

    %{
      "installation_id" => "browser-installation",
      "endpoint" => endpoint,
      "p256dh" => Base.url_encode64(public_key, padding: false),
      "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    }
  end
end
