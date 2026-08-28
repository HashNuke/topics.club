defmodule Ircpipe.MigrationTestRepo do
  use Ecto.Repo,
    otp_app: :topics_club_core,
    adapter: Ecto.Adapters.Postgres
end
