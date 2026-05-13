defmodule Ircpipe.Repo.Migrations.AddOauthFieldsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :name, :string
      add :avatar_url, :string
      add :auth_provider, :string
      add :auth_uid, :string
    end

    create unique_index(:users, [:auth_provider, :auth_uid],
             where: "auth_provider IS NOT NULL AND auth_uid IS NOT NULL"
           )
  end
end
