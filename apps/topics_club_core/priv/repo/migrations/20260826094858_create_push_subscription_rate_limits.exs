defmodule TopicsClub.Repo.Migrations.CreatePushSubscriptionRateLimits do
  use Ecto.Migration

  def change do
    create table(:push_subscription_rate_limits) do
      add :window_started_at, :utc_datetime, null: false
      add :creation_count, :integer, null: false, default: 0
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:push_subscription_rate_limits, [:user_id])
  end
end
