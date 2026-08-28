defmodule Ircpipe.MigrationTestRepo do
  use Ecto.Repo,
    otp_app: :ircpipe_core,
    adapter: Ecto.Adapters.Postgres
end
