defmodule TopicsClub.Repo.Migrations.AddServiceToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :service, :string
    end
  end
end
