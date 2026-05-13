defmodule Ircpipe.Repo.Migrations.AllowServerBufferMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      modify :channel_membership_id, references(:channel_memberships, on_delete: :delete_all),
        null: true,
        from: references(:channel_memberships, on_delete: :delete_all)
    end

    create index(:messages, [:server_connection_id, :occurred_at])
  end
end
