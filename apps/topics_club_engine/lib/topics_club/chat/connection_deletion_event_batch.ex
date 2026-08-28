defmodule TopicsClub.Chat.ConnectionDeletionEventBatch do
  @moduledoc false

  use Ecto.Schema

  alias TopicsClub.Accounts.User

  schema "connection_deletion_event_batches" do
    field :server_connection_id, :integer
    field :payloads, :map

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end
end
