defmodule Ircpipe.Chat.ChannelMembership do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ircpipe.Accounts.User
  alias Ircpipe.Chat.{Message, ServerConnection}

  schema "channel_memberships" do
    field :channel, :string
    field :joined_at, :utc_datetime
    field :last_read_at, :utc_datetime
    field :unread_count, :integer, default: 0
    field :mention_count, :integer, default: 0

    belongs_to :server_connection, ServerConnection
    belongs_to :user, User
    has_many :messages, Message

    timestamps(type: :utc_datetime)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:channel, :joined_at, :last_read_at, :unread_count, :mention_count])
    |> validate_required([:channel])
    |> unique_constraint([:server_connection_id, :channel])
  end
end
