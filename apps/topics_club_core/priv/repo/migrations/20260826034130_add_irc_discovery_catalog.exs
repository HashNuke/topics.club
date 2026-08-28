defmodule TopicsClub.Repo.Migrations.AddIrcDiscoveryCatalog do
  use Ecto.Migration

  def change do
    create table(:irc_networks) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :host, :string, null: false
      add :port, :integer, null: false, default: 6697
      add :use_tls, :boolean, null: false, default: true
      add :rank, :integer, null: false
      add :source_url, :string, null: false
      add :source_refreshed_at, :utc_datetime, null: false
      add :channels_refreshed_at, :utc_datetime
      add :last_refresh_error, :text
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:irc_networks, [:slug])
    create index(:irc_networks, [:active, :rank])
    create index(:irc_networks, [:channels_refreshed_at])

    create table(:irc_channels) do
      add :name, :string, null: false
      add :topic, :text
      add :user_count, :integer, null: false, default: 0
      add :listed_at, :utc_datetime, null: false
      add :irc_network_id, references(:irc_networks, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:irc_channels, [:irc_network_id, :name])
    create index(:irc_channels, [:user_count])
  end
end
