defmodule Ircpipe.Discovery.Channel do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ircpipe.Discovery.Network

  schema "irc_channels" do
    field :name, :string
    field :topic, :string
    field :user_count, :integer, default: 0
    field :listed_at, :utc_datetime

    belongs_to :network, Network, foreign_key: :irc_network_id

    timestamps(type: :utc_datetime)
  end

  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:name, :topic, :user_count, :listed_at])
    |> validate_required([:name, :user_count, :listed_at])
    |> validate_number(:user_count, greater_than_or_equal_to: 0)
    |> unique_constraint([:irc_network_id, :name])
  end
end
