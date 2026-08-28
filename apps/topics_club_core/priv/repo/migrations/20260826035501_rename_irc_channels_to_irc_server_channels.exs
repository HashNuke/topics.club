defmodule TopicsClub.Repo.Migrations.RenameIrcChannelsToIrcServerChannels do
  use Ecto.Migration

  def change do
    rename table(:irc_channels), to: table(:irc_server_channels)

    rename(
      index(:irc_server_channels, [:irc_network_id, :name],
        name: :irc_channels_irc_network_id_name_index
      ),
      to: :irc_server_channels_irc_network_id_name_index
    )

    rename(
      index(:irc_server_channels, [:user_count], name: :irc_channels_user_count_index),
      to: :irc_server_channels_user_count_index
    )
  end
end
