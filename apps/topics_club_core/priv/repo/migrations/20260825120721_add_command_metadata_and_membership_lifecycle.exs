defmodule TopicsClub.Repo.Migrations.AddCommandMetadataAndMembershipLifecycle do
  use Ecto.Migration

  def change do
    alter table(:channel_memberships) do
      add :status, :string, null: false, default: "joined"
      add :auto_join, :boolean, null: false, default: true
      add :left_at, :utc_datetime
      add :last_error, :text
    end

    create constraint(:channel_memberships, :channel_memberships_status_check,
             check: "status IN ('pending', 'joined', 'left', 'error')"
           )

    create index(:channel_memberships, [:server_connection_id, :status])

    execute(
      "ALTER TABLE channel_memberships ALTER COLUMN status SET DEFAULT 'pending'",
      "ALTER TABLE channel_memberships ALTER COLUMN status SET DEFAULT 'joined'"
    )

    execute(
      "ALTER TABLE channel_memberships ALTER COLUMN auto_join SET DEFAULT false",
      "ALTER TABLE channel_memberships ALTER COLUMN auto_join SET DEFAULT true"
    )

    alter table(:messages) do
      add :metadata, :map, null: false, default: %{}
    end
  end
end
