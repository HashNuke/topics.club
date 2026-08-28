defmodule Ircpipe.Discovery.Network do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ircpipe.Discovery.ServerChannel

  schema "irc_networks" do
    field :name, :string
    field :slug, :string
    field :host, :string
    field :port, :integer, default: 6697
    field :use_tls, :boolean, default: true
    field :rank, :integer
    field :source_url, :string
    field :source_refreshed_at, :utc_datetime
    field :channels_refreshed_at, :utc_datetime
    field :last_refresh_error, :string
    field :active, :boolean, default: true

    has_many :server_channels, ServerChannel, foreign_key: :irc_network_id

    timestamps(type: :utc_datetime)
  end

  def changeset(network, attrs) do
    network
    |> cast(attrs, [
      :name,
      :slug,
      :host,
      :port,
      :use_tls,
      :rank,
      :source_url,
      :source_refreshed_at,
      :channels_refreshed_at,
      :last_refresh_error,
      :active
    ])
    |> validate_required([
      :name,
      :slug,
      :host,
      :port,
      :use_tls,
      :rank,
      :source_url,
      :source_refreshed_at
    ])
    |> validate_number(:port, greater_than: 0, less_than: 65_536)
    |> validate_number(:rank, greater_than: 0)
    |> unique_constraint(:slug)
  end
end
