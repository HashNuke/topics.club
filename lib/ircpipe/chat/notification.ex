defmodule Ircpipe.Chat.Notification do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ircpipe.Accounts.User
  alias Ircpipe.Chat.{ChannelMembership, Message}

  schema "notifications" do
    field :read_at, :utc_datetime

    belongs_to :message, Message
    belongs_to :channel_membership, ChannelMembership
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [:read_at])
    |> validate_required([])
  end
end
