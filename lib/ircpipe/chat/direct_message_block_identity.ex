defmodule Ircpipe.Chat.DirectMessageBlockIdentity do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ircpipe.Accounts.User
  alias Ircpipe.Chat.{DirectMessageThread, ServerConnection}

  schema "direct_message_block_identities" do
    field :identity_key, :string

    belongs_to :direct_message_thread, DirectMessageThread
    belongs_to :server_connection, ServerConnection
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:identity_key])
    |> validate_required([:identity_key])
    |> validate_length(:identity_key, max: 512)
    |> unique_constraint([:server_connection_id, :identity_key])
  end
end
