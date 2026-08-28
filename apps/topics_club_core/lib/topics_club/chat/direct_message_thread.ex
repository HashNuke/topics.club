defmodule TopicsClub.Chat.DirectMessageThread do
  use Ecto.Schema
  import Ecto.Changeset

  alias TopicsClub.Accounts.User
  alias TopicsClub.Chat.{DirectMessageBlockIdentity, Message, ServerConnection}

  schema "direct_message_threads" do
    field :peer_nick, :string
    field :peer_key, :string
    field :identity_key, :string
    field :account, :string
    field :hostmask, :string
    field :closed_at, :utc_datetime
    field :blocked_at, :utc_datetime
    field :last_read_at, :utc_datetime
    field :unread_count, :integer, default: 0
    field :mutation_revision, :integer, default: 0

    belongs_to :server_connection, ServerConnection
    belongs_to :user, User
    has_many :messages, Message
    has_many :block_identities, DirectMessageBlockIdentity

    timestamps(type: :utc_datetime)
  end

  def changeset(thread, attrs) do
    thread
    |> cast(attrs, [
      :peer_nick,
      :peer_key,
      :identity_key,
      :account,
      :hostmask,
      :closed_at,
      :blocked_at,
      :last_read_at,
      :unread_count
    ])
    |> validate_required([:peer_nick, :peer_key])
    |> validate_length(:peer_nick, max: 128)
    |> validate_length(:peer_key, max: 128)
    |> validate_length(:identity_key, max: 512)
    |> validate_length(:account, max: 128)
    |> validate_length(:hostmask, max: 512)
    |> validate_number(:unread_count, greater_than_or_equal_to: 0)
    |> unique_constraint([:server_connection_id, :peer_key])
    |> unique_constraint([:server_connection_id, :identity_key])
  end
end
