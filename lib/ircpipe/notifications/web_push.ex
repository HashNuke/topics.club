defmodule Ircpipe.Notifications.WebPush do
  @moduledoc false
  import Bitwise

  @record_size 4_096
  @default_ttl 86_400

  def configured? do
    config = config()

    valid_encoded_key?(config[:public_key], 65) and
      valid_encoded_key?(config[:private_key], 32) and
      valid_subject?(config[:subject])
  end

  def public_key do
    if configured?(), do: config()[:public_key]
  end

  def send(subscription, payload) when is_map(payload) do
    with true <- configured?(),
         {:ok, endpoint_ip} <- validate_endpoint(subscription.endpoint),
         {:ok, encrypted} <-
           encrypt(Jason.encode!(payload), subscription.p256dh, subscription.auth),
         {:ok, authorization} <- authorization_header(subscription.endpoint) do
      request(subscription.endpoint, endpoint_ip, encrypted, authorization)
    else
      false -> {:error, :not_configured}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:invalid_subscription, Exception.message(error)}}
  end

  def generate_keypair do
    {public, private} = :crypto.generate_key(:ecdh, :prime256v1)

    %{
      public_key: Base.url_encode64(public, padding: false),
      private_key: Base.url_encode64(private, padding: false)
    }
  end

  def validate_endpoint(endpoint) when is_binary(endpoint) do
    with %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" <-
           URI.parse(endpoint),
         true <- public_host_syntax?(host),
         {:ok, addresses} <- resolve_addresses(host),
         true <- addresses != [] and Enum.all?(addresses, &public_address?/1) do
      {:ok, List.first(addresses)}
    else
      _invalid -> {:error, :unsafe_push_endpoint}
    end
  end

  def validate_endpoint(_endpoint), do: {:error, :unsafe_push_endpoint}

  def public_host_syntax?(host) when is_binary(host) do
    normalized = host |> String.trim_trailing(".") |> String.downcase()

    normalized not in ["localhost", "localhost.localdomain"] and
      not String.ends_with?(normalized, ".localhost") and
      not String.ends_with?(normalized, ".local") and
      case :inet.parse_address(String.to_charlist(normalized)) do
        {:ok, address} -> public_address?(address)
        {:error, :einval} -> true
      end
  end

  def public_host_syntax?(_host), do: false

  defp request(endpoint, endpoint_ip, encrypted, authorization) do
    endpoint_uri = URI.parse(endpoint)

    pinned_endpoint =
      %{endpoint_uri | host: endpoint_ip |> :inet.ntoa() |> to_string()} |> URI.to_string()

    hostname = endpoint_uri.host

    options =
      [
        body: encrypted,
        redirect: false,
        receive_timeout: 10_000,
        connect_options: [hostname: hostname],
        headers: [
          {"authorization", authorization},
          {"content-encoding", "aes128gcm"},
          {"content-type", "application/octet-stream"},
          {"host", endpoint_authority(endpoint_uri)},
          {"ttl", Integer.to_string(@default_ttl)},
          {"urgency", "normal"}
        ]
      ]
      |> Keyword.merge(config()[:req_options] || [])

    case Req.post(pinned_endpoint, options) do
      {:ok, %{status: status}} when status in [200, 201, 202, 204] ->
        :ok

      {:ok, %{status: status}} when status in [404, 410] ->
        {:error, :expired}

      {:ok, %{status: status}} when status == 429 or status >= 500 ->
        {:error, {:retryable, status}}

      {:ok, %{status: status}} ->
        {:error, {:rejected, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp endpoint_authority(%URI{host: host, port: port}) when port not in [nil, 443],
    do: "#{host}:#{port}"

  defp endpoint_authority(%URI{host: host}), do: host

  defp resolve_addresses(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} ->
        {:ok, [address]}

      {:error, :einval} ->
        resolver = config()[:endpoint_resolver] || (&:inet.getaddrs/2)

        addresses =
          [:inet, :inet6]
          |> Enum.flat_map(fn family ->
            case resolver.(String.to_charlist(host), family) do
              {:ok, values} -> values
              {:error, _reason} -> []
            end
          end)
          |> Enum.uniq()

        if addresses == [], do: {:error, :nxdomain}, else: {:ok, addresses}
    end
  end

  defp public_address?({a, b, _c, _d}) do
    cond do
      a in [0, 10, 127] -> false
      a == 100 and b in 64..127 -> false
      a == 169 and b == 254 -> false
      a == 172 and b in 16..31 -> false
      a == 192 and b in [0, 168] -> false
      a == 192 and b == 0 -> false
      a == 198 and b in 18..19 -> false
      a >= 224 -> false
      true -> true
    end
  end

  defp public_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  defp public_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: false

  defp public_address?({0, 0, 0, 0, 0, 0xFFFF, high, low}) do
    public_address?({high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF})
  end

  defp public_address?({first, _b, _c, _d, _e, _f, _g, _h}) do
    first not in 0xFC00..0xFDFF and first not in 0xFE80..0xFEBF and
      first not in 0xFF00..0xFFFF
  end

  defp public_address?(_address), do: false

  defp encrypt(plaintext, p256dh, auth) do
    user_agent_public = Base.url_decode64!(p256dh, padding: false)
    auth_secret = Base.url_decode64!(auth, padding: false)
    {server_public, server_private} = :crypto.generate_key(:ecdh, :prime256v1)
    salt = :crypto.strong_rand_bytes(16)

    with 65 <- byte_size(user_agent_public),
         16 <- byte_size(auth_secret),
         true <- byte_size(plaintext) <= @record_size - 17 do
      shared_secret =
        :crypto.compute_key(:ecdh, user_agent_public, server_private, :prime256v1)

      input_key =
        auth_secret
        |> hmac(shared_secret)
        |> hkdf_expand("WebPush: info" <> <<0>> <> user_agent_public <> server_public, 32)

      pseudo_random_key = hmac(salt, input_key)
      content_key = hkdf_expand(pseudo_random_key, "Content-Encoding: aes128gcm" <> <<0>>, 16)
      nonce = hkdf_expand(pseudo_random_key, "Content-Encoding: nonce" <> <<0>>, 12)
      padded = plaintext <> <<2>>

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_128_gcm, content_key, nonce, padded, <<>>, true)

      {:ok,
       salt <>
         <<@record_size::32>> <>
         <<byte_size(server_public)>> <>
         server_public <>
         ciphertext <>
         tag}
    else
      _other -> {:error, :invalid_subscription_keys}
    end
  end

  defp authorization_header(endpoint) do
    config = config()
    public_key = config[:public_key]
    private_key = Base.url_decode64!(config[:private_key], padding: false)
    audience = audience_for(endpoint)
    header = Jason.encode!(%{"typ" => "JWT", "alg" => "ES256"}) |> base64url()

    claims =
      Jason.encode!(%{
        "aud" => audience,
        "exp" => System.system_time(:second) + 12 * 3_600,
        "sub" => config[:subject]
      })
      |> base64url()

    signing_input = header <> "." <> claims
    signature = :crypto.sign(:ecdsa, :sha256, signing_input, [private_key, :secp256r1])
    raw_signature = der_signature_to_raw(signature)
    jwt = signing_input <> "." <> base64url(raw_signature)
    {:ok, "vapid t=#{jwt}, k=#{public_key}"}
  end

  defp audience_for(endpoint) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(endpoint)
    default_port = if scheme == "https", do: 443, else: 80
    port_part = if port && port != default_port, do: ":#{port}", else: ""
    "#{scheme}://#{host}#{port_part}"
  end

  defp der_signature_to_raw(<<0x30, _length, 0x02, r_length, rest::binary>>),
    do: extract_signature_parts(rest, r_length)

  defp der_signature_to_raw(<<0x30, 0x81, _length, 0x02, r_length, rest::binary>>),
    do: extract_signature_parts(rest, r_length)

  defp extract_signature_parts(rest, r_length) do
    <<r::binary-size(^r_length), 0x02, s_length, s::binary-size(s_length)>> = rest
    pad_signature_part(trim_leading_zero(r)) <> pad_signature_part(trim_leading_zero(s))
  end

  defp trim_leading_zero(<<0, rest::binary>>) when byte_size(rest) > 0,
    do: trim_leading_zero(rest)

  defp trim_leading_zero(value), do: value

  defp pad_signature_part(value) when byte_size(value) == 32, do: value

  defp pad_signature_part(value) when byte_size(value) < 32 do
    padding_bits = (32 - byte_size(value)) * 8
    <<0::size(padding_bits), value::binary>>
  end

  defp hkdf_expand(key, info, length), do: key |> hmac(info <> <<1>>) |> binary_part(0, length)
  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp base64url(value), do: Base.url_encode64(value, padding: false)

  defp valid_encoded_key?(value, expected_size) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} -> byte_size(decoded) == expected_size
      :error -> false
    end
  end

  defp valid_encoded_key?(_value, _expected_size), do: false

  defp valid_subject?(subject) when is_binary(subject) do
    case URI.parse(subject) do
      %URI{scheme: "mailto", path: path} when is_binary(path) and path != "" ->
        true

      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        true

      _uri ->
        false
    end
  end

  defp valid_subject?(_subject), do: false
  defp config, do: Application.get_env(:ircpipe, __MODULE__, [])
end
