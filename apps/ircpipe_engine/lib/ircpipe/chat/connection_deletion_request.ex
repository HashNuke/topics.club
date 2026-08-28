defmodule Ircpipe.Chat.ConnectionDeletionRequest do
  @moduledoc false

  use Ecto.Schema

  alias Ircpipe.Accounts.User
  alias Ircpipe.Chat.ServerConnection

  schema "connection_deletion_requests" do
    belongs_to :user, User
    belongs_to :server_connection, ServerConnection

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
