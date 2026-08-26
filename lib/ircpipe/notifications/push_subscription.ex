defmodule Ircpipe.Notifications.PushSubscription do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ircpipe.Accounts.User

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
end
