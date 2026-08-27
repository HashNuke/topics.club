defmodule Ircpipe.Repo.Migrations.AddDesiredStateToServerConnections do
  use Ecto.Migration

  def change do
    alter table(:server_connections) do
      add :desired_state, :string, null: false, default: "connected"
    end

    create constraint(:server_connections, :server_connections_desired_state_check,
             check: "desired_state IN ('connected', 'paused')"
           )
  end
end
