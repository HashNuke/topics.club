defmodule Ircpipe.Chat.ConnectionDeletionEventBatch do
  @moduledoc false

  use Ecto.Schema

  alias Ircpipe.Accounts.User

  schema "connection_deletion_event_batches" do
    field :server_connection_id, :integer
    field :payloads, :map

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end
end
