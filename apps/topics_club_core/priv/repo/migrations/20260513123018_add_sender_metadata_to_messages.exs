defmodule Ircpipe.Repo.Migrations.AddSenderMetadataToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :hostmask, :string
      add :sender_role, :string
    end
  end
end
