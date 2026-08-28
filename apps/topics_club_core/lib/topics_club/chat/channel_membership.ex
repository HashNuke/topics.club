defmodule TopicsClub.Chat.ChannelMembership do
  use Ecto.Schema
  import Ecto.Changeset

  alias TopicsClub.Accounts.User
  alias TopicsClub.Chat.{ChannelUser, Message, ServerConnection}

  schema "channel_memberships" do
    field :channel, :string
    field :status, :string, default: "pending"
    field :auto_join, :boolean, default: false
    field :joined_at, :utc_datetime
    field :left_at, :utc_datetime
    field :last_error, :string
    field :last_read_at, :utc_datetime
    field :unread_count, :integer, default: 0
    field :mention_count, :integer, default: 0
    field :mention_notifications_enabled, :boolean, default: true
    field :notification_preference_revision, :integer, default: 0

    belongs_to :server_connection, ServerConnection
    belongs_to :user, User
    has_many :messages, Message
    has_many :channel_users, ChannelUser

    timestamps(type: :utc_datetime)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [
      :channel,
      :status,
      :auto_join,
      :joined_at,
      :left_at,
      :last_error,
      :last_read_at,
      :unread_count,
      :mention_count
    ])
    |> validate_required([:channel])
    |> validate_inclusion(:status, ~w(pending joined left error))
    |> unique_constraint([:server_connection_id, :channel])
  end
end
