defmodule Ircpipe.Notifications.WebPushTest do
  use ExUnit.Case, async: false

  alias Ircpipe.Notifications.{PushSubscription, WebPush}

  setup do
    previous_config = Application.get_env(:ircpipe, WebPush)

    on_exit(fn ->
      if previous_config,
        do: Application.put_env(:ircpipe, WebPush, previous_config),
        else: Application.delete_env(:ircpipe, WebPush)
    end)

    :ok
  end

  test "encrypts a payload and sends the required Web Push headers with Req" do
    test_pid = self()
    vapid = WebPush.generate_keypair()
    {user_agent_public, _user_agent_private} = :crypto.generate_key(:ecdh, :prime256v1)

    finch_request = fn request, finch_request, _finch_name, _finch_options ->
      Kernel.send(test_pid, {
        :web_push_request,
        finch_request.headers,
        IO.iodata_to_binary(finch_request.body)
      })

      {request, Req.Response.new(status: 201, body: "")}
    end

    Application.put_env(:ircpipe, WebPush,
      public_key: vapid.public_key,
      private_key: vapid.private_key,
      subject: "mailto:notifications@example.com",
      endpoint_resolver: fn _host, _family -> {:ok, [{93, 184, 216, 34}]} end,
      req_options: [finch_request: finch_request, retry: false]
    )

    subscription = %PushSubscription{
      endpoint: "https://push.example.test/subscription/one",
      p256dh: Base.url_encode64(user_agent_public, padding: false),
      auth: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    }

    assert WebPush.configured?()
    assert WebPush.public_key() == vapid.public_key
    assert :ok = WebPush.send(subscription, %{title: "Mention", body: "mira: ping"})

    assert_receive {:web_push_request, headers, body}
    authorization = header(headers, "authorization")
    assert header(headers, "content-encoding") == "aes128gcm"
    assert header(headers, "ttl") == "86400"
    assert String.starts_with?(authorization, "vapid t=")
    assert String.contains?(authorization, ", k=#{vapid.public_key}")
    assert byte_size(body) > byte_size(Jason.encode!(%{title: "Mention", body: "mira: ping"}))
  end

  test "rejects loopback, private, local DNS, and mixed DNS answers before sending" do
    vapid = WebPush.generate_keypair()
    {user_agent_public, _user_agent_private} = :crypto.generate_key(:ecdh, :prime256v1)

    subscription = %PushSubscription{
      p256dh: Base.url_encode64(user_agent_public, padding: false),
      auth: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    }

    Application.put_env(:ircpipe, WebPush,
      public_key: vapid.public_key,
      private_key: vapid.private_key,
      subject: "mailto:notifications@example.com",
      endpoint_resolver: fn _host, _family ->
        {:ok, [{93, 184, 216, 34}, {10, 0, 0, 1}]}
      end
    )

    for endpoint <- [
          "https://127.0.0.1/push",
          "https://[::1]/push",
          "https://push.local/push",
          "https://mixed.example.test/push"
        ] do
      assert {:error, :unsafe_push_endpoint} =
               WebPush.send(%{subscription | endpoint: endpoint}, %{title: "Mention"})
    end
  end

  test "reports an unconfigured sender without making a request" do
    Application.put_env(:ircpipe, WebPush,
      public_key: "replace-with-generated-public-key",
      private_key: "replace-with-generated-private-key",
      subject: "mailto:notifications@example.com"
    )

    refute WebPush.configured?()

    assert {:error, :not_configured} =
             WebPush.send(%PushSubscription{}, %{title: "Mention"})
  end

  defp header(headers, name) do
    headers
    |> Enum.find_value(fn
      {^name, value} -> value
      _header -> nil
    end)
  end
end
