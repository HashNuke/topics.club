defmodule TopicsClub.Chat.ChannelUser do
  use Ecto.Schema
  import Ecto.Changeset

  alias TopicsClub.Chat.ChannelMembership

  @roles ~w(owner admin op halfop voice user)
  @statuses ~w(online away unknown)

  schema "channel_users" do
    field :nick, :string
    field :nick_key, :string
    field :role, :string, default: "user"
    field :status, :string, default: "online"
    field :hostmask, :string
    field :last_observed_at, :utc_datetime

    belongs_to :channel_membership, ChannelMembership

    timestamps(type: :utc_datetime)
  end

  def changeset(channel_user, attrs) do
    nick_key = Map.get(attrs, :nick_key) || Map.get(attrs, "nick_key")

    channel_user
    |> cast(attrs, [:nick, :role, :status, :hostmask, :last_observed_at])
    |> put_change(:nick_key, nick_key)
    |> validate_required([:nick, :nick_key, :role, :status, :last_observed_at])
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:channel_membership_id, :nick_key])
  end
end
