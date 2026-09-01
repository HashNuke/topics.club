defmodule TopicsClub.Repo.Migrations.AddTransportRevisionToServerConnections do
  use Ecto.Migration

  def change do
    alter table(:server_connections) do
      add :transport_revision, :bigint, null: false, default: 1
    end
  end
end
