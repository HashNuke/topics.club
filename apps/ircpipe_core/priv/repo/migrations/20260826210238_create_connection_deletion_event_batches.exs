defmodule Ircpipe.Repo.Migrations.CreateConnectionDeletionEventBatches do
  use Ecto.Migration

  def change do
    create table(:connection_deletion_event_batches) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :server_connection_id, :bigint, null: false
      add :payloads, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:connection_deletion_event_batches, [:server_connection_id])
  end
end
