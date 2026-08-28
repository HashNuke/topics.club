defmodule TopicsClub.Chat.Topic do
  use Ecto.Schema
  import Ecto.Changeset

  schema "topics" do
    field :name, :string
    field :description, :string
    field :server_host, :string
    field :server_port, :integer, default: 6697
    field :use_tls, :boolean, default: true
    field :channel, :string
    field :sort_order, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(topic, attrs) do
    topic
    |> cast(attrs, [
      :name,
      :description,
      :server_host,
      :server_port,
      :use_tls,
      :channel,
      :sort_order
    ])
    |> validate_required([:name, :description, :server_host, :server_port, :channel])
    |> validate_number(:server_port, greater_than: 0, less_than: 65_536)
  end
end
