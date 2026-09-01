defmodule TopicsClub.Repo.Migrations.AddJoinAttemptIdToChannelMemberships do
  use Ecto.Migration

  def change do
    alter table(:channel_memberships) do
      add :join_attempt_id, :uuid
    end
  end
end
