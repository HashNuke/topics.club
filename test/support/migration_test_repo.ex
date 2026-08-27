defmodule Ircpipe.MigrationTestRepo do
  use Ecto.Repo,
    otp_app: :ircpipe,
    adapter: Ecto.Adapters.Postgres
end
