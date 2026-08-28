defmodule TopicsClub.Repo.Migrations.AddNotificationAndDirectMessageRevisions do
  use Ecto.Migration

  def change do
    alter table(:server_connections) do
      add :notification_preference_revision, :bigint, null: false, default: 0
    end

    alter table(:channel_memberships) do
      add :notification_preference_revision, :bigint, null: false, default: 0
    end

    alter table(:direct_message_threads) do
      add :mutation_revision, :bigint, null: false, default: 0
    end
  end
end
