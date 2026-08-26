defmodule IrcpipeWeb.Api.PushSubscriptionControllerTest do
  use IrcpipeWeb.ConnCase, async: true

  alias Ircpipe.Notifications.PushSubscription
  alias Ircpipe.Repo

  setup :register_and_log_in_user

  test "creates and removes the current device subscription", %{conn: conn, user: user} do
    expiration_time = DateTime.add(DateTime.utc_now(:second), 86_400, :second)
    {public_key, _private_key} = :crypto.generate_key(:ecdh, :prime256v1)

    create_conn =
      post(conn, ~p"/api/push_subscriptions", %{
        installation_id: "browser-installation",
        subscription: %{
          endpoint: "https://push.example.test/subscription/one",
          expirationTime: DateTime.to_unix(expiration_time, :millisecond),
          keys: %{
            p256dh: Base.url_encode64(public_key, padding: false),
            auth: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
          }
        }
      })

    assert %{"subscription" => %{"installation_id" => "browser-installation"}} =
             json_response(create_conn, 201)

    assert subscription = Repo.get_by(PushSubscription, user_id: user.id)
    assert subscription.endpoint == "https://push.example.test/subscription/one"
    assert DateTime.compare(subscription.expiration_time, expiration_time) == :eq

    delete_conn = delete(conn, ~p"/api/push_subscriptions/browser-installation")
    assert %{"ok" => true} = json_response(delete_conn, 200)
    refute Repo.get_by(PushSubscription, user_id: user.id)
  end

  test "rejects malformed and insecure subscriptions", %{conn: conn} do
    for endpoint <- [
          "http://push.example.test/subscription/one",
          "https://localhost/subscription/one",
          "https://127.0.0.1/subscription/one",
          "https://push.local/subscription/one"
        ] do
      response =
        post(conn, ~p"/api/push_subscriptions", %{
          installation_id: "browser-installation",
          subscription: %{
            endpoint: endpoint,
            keys: %{p256dh: "public", auth: "auth"}
          }
        })

      assert %{"error" => "invalid_push_subscription"} = json_response(response, 422)
    end
  end
end
