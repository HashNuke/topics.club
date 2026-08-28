defmodule TopicsClub.Repo.Migrations.AddTopicsClubDomainTables do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :message_retention_days, :integer, null: false, default: 3
    end

    create table(:topics) do
      add :name, :string, null: false
      add :description, :text, null: false
      add :server_host, :string, null: false
      add :server_port, :integer, null: false, default: 6697
      add :use_tls, :boolean, null: false, default: true
      add :channel, :string, null: false
      add :sort_order, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create table(:server_connections) do
      add :name, :string, null: false
      add :host, :string, null: false
      add :port, :integer, null: false, default: 6697
      add :use_tls, :boolean, null: false, default: true
      add :nickname, :string, null: false
      add :username, :string
      add :realname, :string
      add :server_password, :string
      add :sasl_username, :string
      add :sasl_password, :string
      add :status, :string, null: false, default: "disconnected"
      add :last_connected_at, :utc_datetime
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:server_connections, [:user_id])
    create unique_index(:server_connections, [:user_id, :name])

    create table(:channel_memberships) do
      add :channel, :string, null: false
      add :joined_at, :utc_datetime
      add :last_read_at, :utc_datetime
      add :unread_count, :integer, null: false, default: 0
      add :mention_count, :integer, null: false, default: 0

      add :server_connection_id, references(:server_connections, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:channel_memberships, [:user_id])
    create index(:channel_memberships, [:server_connection_id])
    create unique_index(:channel_memberships, [:server_connection_id, :channel])

    create table(:messages) do
      add :server_connection_id, references(:server_connections, on_delete: :delete_all),
        null: false

      add :channel_membership_id, references(:channel_memberships, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :kind, :string, null: false, default: "message"
      add :nick, :string
      add :body, :text, null: false
      add :mentioned, :boolean, null: false, default: false
      add :occurred_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:messages, [:channel_membership_id, :occurred_at])
    create index(:messages, [:user_id, :occurred_at])

    create table(:notifications) do
      add :message_id, references(:messages, on_delete: :delete_all), null: false

      add :channel_membership_id, references(:channel_memberships, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :read_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:notifications, [:user_id, :read_at])
  end
end
