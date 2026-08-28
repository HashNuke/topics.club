defmodule Ircpipe.Repo.Migrations.AddNotificationPreferencesAndPushSubscriptions do
  use Ecto.Migration

  def change do
    alter table(:server_connections) do
      add :mention_notifications_enabled, :boolean, null: false, default: true
    end

    alter table(:channel_memberships) do
      add :mention_notifications_enabled, :boolean, null: false, default: true
    end

    create table(:push_subscriptions) do
      add :installation_id, :string, null: false
      add :endpoint, :binary, null: false
      add :endpoint_hash, :binary, null: false
      add :p256dh, :binary, null: false
      add :auth, :binary, null: false
      add :expiration_time, :utc_datetime
      add :user_agent, :string
      add :last_success_at, :utc_datetime
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:push_subscriptions, [:user_id, :installation_id])
    create unique_index(:push_subscriptions, [:endpoint_hash])
    create index(:push_subscriptions, [:user_id])
  end
end
