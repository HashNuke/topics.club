defmodule TopicsClub.Chat.Message do
  use Ecto.Schema
  import Ecto.Changeset

  alias TopicsClub.Accounts.User
  alias TopicsClub.Chat.{ChannelMembership, DirectMessageThread, ServerConnection}

  @kinds ~w(message action notice system error command join part quit nick topic mode kick)

  schema "messages" do
    field :kind, :string, default: "message"
    field :nick, :string
    field :hostmask, :string
    field :sender_role, :string
    field :service, :string
    field :metadata, :map, default: %{}
    field :body, :string
    field :mentioned, :boolean, default: false
    field :occurred_at, :utc_datetime

    belongs_to :server_connection, ServerConnection
    belongs_to :channel_membership, ChannelMembership
    belongs_to :direct_message_thread, DirectMessageThread
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :kind,
      :nick,
      :hostmask,
      :sender_role,
      :service,
      :metadata,
      :body,
      :mentioned,
      :occurred_at
    ])
    |> validate_required([:kind, :body, :occurred_at])
    |> validate_inclusion(:kind, @kinds)
  end
end
