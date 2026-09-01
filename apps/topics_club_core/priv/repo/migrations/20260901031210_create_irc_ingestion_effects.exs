defmodule TopicsClub.Repo.Migrations.CreateIrcIngestionEffects do
  use Ecto.Migration

  def change do
    create table(:irc_ingestion_effects) do
      add :server_connection_id, references(:server_connections, on_delete: :delete_all),
        null: false

      add :wirekeeper_generation, :string, null: false
      add :wirekeeper_sequence, :bigint, null: false
      add :effect_key, :string, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(
             :irc_ingestion_effects,
             [
               :server_connection_id,
               :wirekeeper_generation,
               :wirekeeper_sequence,
               :effect_key
             ],
             name: :irc_ingestion_effects_delivery_index
           )
  end
end
