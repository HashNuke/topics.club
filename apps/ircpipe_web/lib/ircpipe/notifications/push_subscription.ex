defmodule Ircpipe.Notifications.PushSubscription do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ircpipe.Accounts.{User, UserToken}

  schema "push_subscriptions" do
    field :installation_id, :string
    field :endpoint, Ircpipe.Encrypted.Binary, redact: true
    field :endpoint_hash, :binary, redact: true
    field :p256dh, Ircpipe.Encrypted.Binary, redact: true
    field :auth, Ircpipe.Encrypted.Binary, redact: true
    field :expiration_time, :utc_datetime
    field :user_agent, :string
    field :last_success_at, :utc_datetime

    belongs_to :user, User
    belongs_to :user_token, UserToken

    timestamps(type: :utc_datetime)
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :installation_id,
      :endpoint,
      :p256dh,
      :auth,
      :expiration_time,
      :user_agent
    ])
    |> validate_required([:installation_id, :endpoint, :p256dh, :auth])
    |> validate_length(:installation_id, max: 128)
    |> validate_length(:endpoint, max: 2_048)
    |> validate_length(:p256dh, max: 256)
    |> validate_length(:auth, max: 128)
    |> validate_length(:user_agent, max: 1_000)
    |> validate_change(:endpoint, &validate_endpoint/2)
    |> validate_change(:p256dh, &validate_p256dh/2)
    |> validate_change(:auth, &validate_auth/2)
    |> unique_constraint([:user_id, :installation_id])
    |> unique_constraint(:endpoint_hash)
  end

  defp validate_endpoint(:endpoint, endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: "https", host: host, userinfo: nil}
      when is_binary(host) and host != "" ->
        if Ircpipe.Notifications.WebPush.public_host_syntax?(host),
          do: [],
          else: [endpoint: "must use a public push service host"]

      _other ->
        [endpoint: "must be a valid HTTPS push service URL"]
    end
  end

  defp validate_p256dh(:p256dh, value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, <<4, _coordinates::binary-size(64)>> = public_key} ->
        if valid_p256_public_key?(public_key),
          do: [],
          else: [p256dh: "must be a 65-byte uncompressed P-256 public key"]

      _invalid ->
        [p256dh: "must be a 65-byte uncompressed P-256 public key"]
    end
  end

  defp valid_p256_public_key?(public_key) do
    {_public_key, private_key} = :crypto.generate_key(:ecdh, :prime256v1)
    shared_secret = :crypto.compute_key(:ecdh, public_key, private_key, :prime256v1)
    byte_size(shared_secret) == 32
  rescue
    _error -> false
  end

  defp validate_auth(:auth, value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} when byte_size(decoded) == 16 -> []
      _invalid -> [auth: "must decode to 16 bytes"]
    end
  end
end
