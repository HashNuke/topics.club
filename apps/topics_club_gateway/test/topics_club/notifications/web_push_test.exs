defmodule TopicsClub.Notifications.WebPushTest do
  use ExUnit.Case, async: false

  alias TopicsClub.Notifications.{PushSubscription, WebPush}

  setup do
    previous_config = Application.get_env(:topics_club_gateway, WebPush)

    on_exit(fn ->
      if previous_config,
        do: Application.put_env(:topics_club_gateway, WebPush, previous_config),
        else: Application.delete_env(:topics_club_gateway, WebPush)
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

    Application.put_env(:topics_club_gateway, WebPush,
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

  test "streams and discards arbitrarily large response bodies" do
    test_pid = self()
    vapid = WebPush.generate_keypair()
    {user_agent_public, _user_agent_private} = :crypto.generate_key(:ecdh, :prime256v1)

    finch_request = fn request, _finch_request, _finch_name, _finch_options ->
      response = Req.Response.new(status: 201, body: "")
      chunk = String.duplicate("x", 1_000_000)

      assert is_function(request.into, 2)

      assert {:cont, {streamed_request, streamed_response}} =
               request.into.({:data, chunk}, {request, response})

      Kernel.send(test_pid, {
        :discarded_web_push_response,
        streamed_request.into,
        streamed_response.body
      })

      {request, response}
    end

    Application.put_env(:topics_club_gateway, WebPush,
      public_key: vapid.public_key,
      private_key: vapid.private_key,
      subject: "mailto:notifications@example.com",
      endpoint_resolver: fn _host, _family -> {:ok, [{93, 184, 216, 34}]} end,
      req_options: [finch_request: finch_request, retry: false]
    )

    subscription = %PushSubscription{
      endpoint: "https://push.example.test/subscription/large-response",
      p256dh: Base.url_encode64(user_agent_public, padding: false),
      auth: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    }

    assert :ok = WebPush.send(subscription, %{title: "Mention"})
    assert_receive {:discarded_web_push_response, into, ""}
    assert is_function(into, 2)
  end

  test "brackets an IPv6 literal in the Host header and VAPID audience" do
    test_pid = self()
    vapid = WebPush.generate_keypair()
    {user_agent_public, _user_agent_private} = :crypto.generate_key(:ecdh, :prime256v1)

    finch_request = fn request, finch_request, _finch_name, _finch_options ->
      Kernel.send(test_pid, {:ipv6_web_push_request, finch_request.headers})
      {request, Req.Response.new(status: 201, body: "")}
    end

    Application.put_env(:topics_club_gateway, WebPush,
      public_key: vapid.public_key,
      private_key: vapid.private_key,
      subject: "mailto:notifications@example.com",
      req_options: [finch_request: finch_request, retry: false]
    )

    subscription = %PushSubscription{
      endpoint: "https://[2606:4700:4700::1111]:8443/subscription/ipv6",
      p256dh: Base.url_encode64(user_agent_public, padding: false),
      auth: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    }

    assert :ok = WebPush.send(subscription, %{title: "Mention"})
    assert_receive {:ipv6_web_push_request, headers}
    assert header(headers, "host") == "[2606:4700:4700::1111]:8443"

    authorization = header(headers, "authorization")
    [jwt | _rest] = authorization |> String.replace_prefix("vapid t=", "") |> String.split(",")
    [_header, claims, _signature] = String.split(jwt, ".")
    assert {:ok, claims_json} = Base.url_decode64(claims, padding: false)
    assert Jason.decode!(claims_json)["aud"] == "https://[2606:4700:4700::1111]:8443"
  end

  test "rejects loopback, private, local DNS, and mixed DNS answers before sending" do
    vapid = WebPush.generate_keypair()
    {user_agent_public, _user_agent_private} = :crypto.generate_key(:ecdh, :prime256v1)

    subscription = %PushSubscription{
      p256dh: Base.url_encode64(user_agent_public, padding: false),
      auth: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    }

    Application.put_env(:topics_club_gateway, WebPush,
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

  test "rejects site-local and IPv4-translated private IPv6 answers" do
    Application.put_env(:topics_club_gateway, WebPush,
      endpoint_resolver: fn _host, _family ->
        {:ok, [{0xFEC0, 0, 0, 0, 0, 0, 0, 1}]}
      end
    )

    for endpoint <- [
          "https://[fec0::1]/push",
          "https://[::ffff:0:10.0.0.1]/push",
          "https://site-local.example.test/push"
        ] do
      assert {:error, :unsafe_push_endpoint} = WebPush.validate_endpoint(endpoint)
    end

    assert {:ok, {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}} =
             WebPush.validate_endpoint("https://[2606:4700:4700::1111]/push")
  end

  test "reports an unconfigured sender without making a request" do
    Application.put_env(:topics_club_gateway, WebPush,
      public_key: "replace-with-generated-public-key",
      private_key: "replace-with-generated-private-key",
      subject: "mailto:notifications@example.com"
    )

    refute WebPush.configured?()

    assert {:error, :not_configured} =
             WebPush.send(%PushSubscription{}, %{title: "Mention"})
  end

  test "rejects mismatched and invalid VAPID key material" do
    first = WebPush.generate_keypair()
    second = WebPush.generate_keypair()

    for {public_key, private_key} <- [
          {first.public_key, second.private_key},
          {first.public_key, Base.url_encode64(<<0::256>>, padding: false)},
          {first.public_key,
           Base.url_encode64(
             <<0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551::256>>,
             padding: false
           )},
          {Base.url_encode64(<<4, 0::512>>, padding: false), first.private_key}
        ] do
      Application.put_env(:topics_club_gateway, WebPush,
        public_key: public_key,
        private_key: private_key,
        subject: "mailto:notifications@example.com"
      )

      refute WebPush.configured?()
      assert WebPush.public_key() == nil
    end
  end

  defp header(headers, name) do
    headers
    |> Enum.find_value(fn
      {^name, value} -> value
      _header -> nil
    end)
  end
end
