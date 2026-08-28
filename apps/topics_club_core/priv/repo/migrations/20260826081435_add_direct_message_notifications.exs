defmodule TopicsClub.Repo.Migrations.AddDirectMessageNotifications do
  use Ecto.Migration

  def up do
    alter table(:notifications) do
      add :direct_message_thread_id,
          references(:direct_message_threads, on_delete: :delete_all)
    end

    execute("ALTER TABLE notifications ALTER COLUMN channel_membership_id DROP NOT NULL")

    create constraint(:notifications, :notifications_buffer_owner_check,
             check:
               "(channel_membership_id IS NOT NULL) <> (direct_message_thread_id IS NOT NULL)"
           )

    create index(:notifications, [:direct_message_thread_id, :read_at])
  end

  def down do
    drop constraint(:notifications, :notifications_buffer_owner_check)
    execute("DELETE FROM notifications WHERE direct_message_thread_id IS NOT NULL")
    drop index(:notifications, [:direct_message_thread_id, :read_at])

    alter table(:notifications) do
      remove :direct_message_thread_id
    end

    execute("ALTER TABLE notifications ALTER COLUMN channel_membership_id SET NOT NULL")
  end
end
