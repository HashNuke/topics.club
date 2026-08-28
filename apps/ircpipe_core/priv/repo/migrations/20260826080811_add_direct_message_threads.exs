defmodule Ircpipe.Repo.Migrations.AddDirectMessageThreads do
  use Ecto.Migration

  def change do
    create table(:direct_message_threads) do
      add :peer_nick, :string, null: false
      add :peer_key, :string, null: false
      add :identity_key, :string
      add :account, :string
      add :hostmask, :string
      add :closed_at, :utc_datetime
      add :blocked_at, :utc_datetime
      add :last_read_at, :utc_datetime
      add :unread_count, :integer, null: false, default: 0

      add :server_connection_id, references(:server_connections, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:direct_message_threads, [:user_id])
    create index(:direct_message_threads, [:server_connection_id])
    create unique_index(:direct_message_threads, [:server_connection_id, :peer_key])

    create unique_index(:direct_message_threads, [:server_connection_id, :identity_key],
             where: "identity_key IS NOT NULL"
           )

    alter table(:messages) do
      add :direct_message_thread_id,
          references(:direct_message_threads, on_delete: :delete_all)
    end

    create index(:messages, [:direct_message_thread_id, :occurred_at])
  end
end
