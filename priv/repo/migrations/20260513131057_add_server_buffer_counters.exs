defmodule Ircpipe.Repo.Migrations.AddServerBufferCounters do
  use Ecto.Migration

  def change do
    alter table(:server_connections) do
      add :last_read_at, :utc_datetime
      add :unread_count, :integer, null: false, default: 0
      add :mention_count, :integer, null: false, default: 0
    end
  end
end
