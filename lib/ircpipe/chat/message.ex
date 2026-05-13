defmodule Ircpipe.Chat.Message do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ircpipe.Accounts.User
  alias Ircpipe.Chat.{ChannelMembership, ServerConnection}

  @kinds ~w(message action notice system error command join part quit nick topic mode kick)

  schema "messages" do
    field :kind, :string, default: "message"
    field :nick, :string
    field :hostmask, :string
    field :sender_role, :string
    field :body, :string
    field :mentioned, :boolean, default: false
    field :occurred_at, :utc_datetime

    belongs_to :server_connection, ServerConnection
    belongs_to :channel_membership, ChannelMembership
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:kind, :nick, :hostmask, :sender_role, :body, :mentioned, :occurred_at])
    |> validate_required([:kind, :body, :occurred_at])
    |> validate_inclusion(:kind, @kinds)
  end
end
