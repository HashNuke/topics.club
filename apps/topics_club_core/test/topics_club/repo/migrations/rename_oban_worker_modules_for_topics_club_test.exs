defmodule TopicsClub.Repo.Migrations.RenameObanWorkerModulesForTopicsClubTest do
  use ExUnit.Case, async: false

  alias TopicsClub.MigrationTestRepo
  alias TopicsClub.Repo.Migrations.RenameObanWorkerModulesForTopicsClub

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20260828065107_rename_oban_worker_modules_for_topics_club.exs",
                    __DIR__
                  )
  @migration_version 20_260_828_065_107
  @worker_renames [
    {"Ircpipe.Chat.ConnectionDeletionEventsWorker",
     "TopicsClub.Chat.ConnectionDeletionEventsWorker"},
    {"Ircpipe.Chat.ConnectionDeletionReconcilerWorker",
     "TopicsClub.Chat.ConnectionDeletionReconcilerWorker"},
    {"Ircpipe.Chat.ConnectionDeletionWorker", "TopicsClub.Chat.ConnectionDeletionWorker"},
    {"Ircpipe.Chat.NotificationEventsWorker", "TopicsClub.Chat.NotificationEventsWorker"},
    {"Ircpipe.Notifications.PushWorker", "TopicsClub.Notifications.PushWorker"}
  ]

  Code.require_file(@migration_path)

  setup do
    repo_config =
      TopicsClub.Repo.config()
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({MigrationTestRepo, repo_config})
    :ok
  end

  test "renames persisted workers without changing unrelated jobs and rolls back" do
    prefix = "oban_worker_rename_#{System.unique_integer([:positive])}"

    query!(~s(CREATE SCHEMA "#{prefix}"))

    try do
      query!("""
      CREATE TABLE "#{prefix}".oban_jobs (
        id bigserial PRIMARY KEY,
        worker text NOT NULL
      )
      """)

      Enum.each(["Unrelated.Worker" | Enum.map(@worker_renames, &elem(&1, 0))], fn worker ->
        query!(~s|INSERT INTO "#{prefix}".oban_jobs (worker) VALUES ($1)|, [worker])
      end)

      assert :ok =
               Ecto.Migrator.up(
                 MigrationTestRepo,
                 @migration_version,
                 RenameObanWorkerModulesForTopicsClub,
                 prefix: prefix,
                 log: false
               )

      assert worker_names(prefix) ==
               Enum.sort(["Unrelated.Worker" | Enum.map(@worker_renames, &elem(&1, 1))])

      assert :ok =
               Ecto.Migrator.down(
                 MigrationTestRepo,
                 @migration_version,
                 RenameObanWorkerModulesForTopicsClub,
                 prefix: prefix,
                 log: false
               )

      assert worker_names(prefix) ==
               Enum.sort(["Unrelated.Worker" | Enum.map(@worker_renames, &elem(&1, 0))])
    after
      query!(~s(DROP SCHEMA IF EXISTS "#{prefix}" CASCADE))
    end
  end

  defp worker_names(prefix) do
    ~s(SELECT worker FROM "#{prefix}".oban_jobs ORDER BY worker)
    |> query!()
    |> Map.fetch!(:rows)
    |> List.flatten()
  end

  defp query!(sql, params \\ []) do
    Ecto.Adapters.SQL.query!(MigrationTestRepo, sql, params)
  end
end
