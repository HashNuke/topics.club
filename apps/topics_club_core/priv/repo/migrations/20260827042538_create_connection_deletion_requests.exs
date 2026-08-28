defmodule TopicsClub.Repo.Migrations.CreateConnectionDeletionRequests do
  use Ecto.Migration

  def change do
    create table(:connection_deletion_requests) do
      add :user_id, references(:users, on_delete: :delete_all), null: false

      add :server_connection_id, references(:server_connections, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:connection_deletion_requests, [:server_connection_id])
  end
end
