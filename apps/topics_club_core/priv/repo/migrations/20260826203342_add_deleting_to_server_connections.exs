defmodule TopicsClub.Repo.Migrations.AddDeletingToServerConnections do
  use Ecto.Migration

  def change do
    alter table(:server_connections) do
      add :deleting, :boolean, null: false, default: false
    end
  end
end
