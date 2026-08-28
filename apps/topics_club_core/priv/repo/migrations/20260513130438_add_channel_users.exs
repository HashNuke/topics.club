defmodule TopicsClub.Repo.Migrations.AddChannelUsers do
  use Ecto.Migration

  def change do
    create table(:channel_users) do
      add :nick, :string, null: false
      add :role, :string, null: false, default: "user"
      add :status, :string, null: false, default: "online"
      add :hostmask, :string
      add :last_observed_at, :utc_datetime, null: false

      add :channel_membership_id, references(:channel_memberships, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create index(:channel_users, [:channel_membership_id])
    create unique_index(:channel_users, [:channel_membership_id, :nick])
  end
end
