defmodule TopicsClub.Repo.Migrations.BindPushSubscriptionsToUserSessions do
  use Ecto.Migration

  def change do
    # Existing registrations cannot be safely attributed to a live auth session.
    # Browsers will recreate them during their next authenticated synchronization.
    execute "DELETE FROM push_subscriptions", "SELECT 1"

    alter table(:push_subscriptions) do
      add :user_token_id,
          references(:users_tokens, on_delete: :delete_all),
          null: false
    end

    create index(:push_subscriptions, [:user_token_id])
  end
end
