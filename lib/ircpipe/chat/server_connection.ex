defmodule Ircpipe.Chat.ServerConnection do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ircpipe.Accounts.User
  alias Ircpipe.Chat.ChannelMembership

  @statuses ~w(disconnected connecting connected errored)

  schema "server_connections" do
    field :name, :string
    field :host, :string
    field :port, :integer, default: 6697
    field :use_tls, :boolean, default: true
    field :nickname, :string
    field :username, :string
    field :realname, :string
    field :server_password, :string, redact: true
    field :sasl_username, :string
    field :sasl_password, :string, redact: true
    field :status, :string, default: "disconnected"
    field :last_connected_at, :utc_datetime

    belongs_to :user, User
    has_many :channel_memberships, ChannelMembership

    timestamps(type: :utc_datetime)
  end

  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [
      :name,
      :host,
      :port,
      :use_tls,
      :nickname,
      :username,
      :realname,
      :server_password,
      :sasl_username,
      :sasl_password,
      :status,
      :last_connected_at
    ])
    |> validate_required([:name, :host, :port, :nickname])
    |> validate_number(:port, greater_than: 0, less_than: 65_536)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:user_id, :name])
  end
end
