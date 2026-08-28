defmodule Ircpipe.Repo.Migrations.AddServerConnectionCasemapping do
  use Ecto.Migration

  def change do
    alter table(:server_connections) do
      add :casemapping, :string
    end

    create constraint(:server_connections, :server_connections_casemapping_check,
             check: "casemapping IS NULL OR casemapping IN ('ascii', 'rfc1459', 'strict_rfc1459')"
           )
  end
end
