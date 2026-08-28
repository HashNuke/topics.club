defmodule TopicsClub.Repo.Migrations.AddDirectMessageBlockIdentities do
  use Ecto.Migration

  def change do
    create table(:direct_message_block_identities) do
      add :identity_key, :string, null: false

      add :direct_message_thread_id,
          references(:direct_message_threads, on_delete: :delete_all),
          null: false

      add :server_connection_id,
          references(:server_connections, on_delete: :delete_all),
          null: false

      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:direct_message_block_identities, [
             :server_connection_id,
             :identity_key
           ])

    create index(:direct_message_block_identities, [:direct_message_thread_id])
    create index(:direct_message_block_identities, [:user_id])

    execute(
      """
      INSERT INTO direct_message_block_identities
        (identity_key, direct_message_thread_id, server_connection_id, user_id, inserted_at, updated_at)
      SELECT identity_key, id, server_connection_id, user_id, NOW(), NOW()
      FROM direct_message_threads
      WHERE blocked_at IS NOT NULL AND identity_key IS NOT NULL
      ON CONFLICT (server_connection_id, identity_key) DO NOTHING
      """,
      "SELECT 1"
    )
  end
end
