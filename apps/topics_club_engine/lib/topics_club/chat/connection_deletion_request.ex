defmodule TopicsClub.Chat.ConnectionDeletionRequest do
  @moduledoc false

  use Ecto.Schema

  alias TopicsClub.Accounts.User
  alias TopicsClub.Chat.ServerConnection

  schema "connection_deletion_requests" do
    belongs_to :user, User
    belongs_to :server_connection, ServerConnection

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
