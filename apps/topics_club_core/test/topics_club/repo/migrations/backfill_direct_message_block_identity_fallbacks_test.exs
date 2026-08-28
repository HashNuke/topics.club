defmodule TopicsClub.Repo.Migrations.BackfillDirectMessageBlockIdentityFallbacksTest do
  use ExUnit.Case, async: false

  alias TopicsClub.MigrationTestRepo

  alias TopicsClub.Repo.Migrations.BackfillDirectMessageBlockIdentityFallbacks,
    as: BackfillMigration

  alias TopicsClub.Repo.Migrations.RepairDirectMessageIdentityBackfillTracking,
    as: RepairMigration

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20260826094528_backfill_direct_message_block_identity_fallbacks.exs",
                    __DIR__
                  )
  @migration_version 20_260_826_094_528
  @repair_migration_path Path.expand(
                           "../../../../priv/repo/migrations/20260827074729_repair_direct_message_identity_backfill_tracking.exs",
                           __DIR__
                         )
  @repair_migration_version 20_260_827_074_729

  Code.require_file(@migration_path)

  unless Code.ensure_loaded?(RepairMigration) do
    Code.require_file(@repair_migration_path)
  end

  setup do
    repo_config =
      TopicsClub.Repo.config()
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({MigrationTestRepo, repo_config})
    :ok
  end

  test "rolls back only identities inserted by the backfill" do
    prefix = "dm_identity_backfill_#{System.unique_integer([:positive])}"

    query!(~s(CREATE SCHEMA "#{prefix}"))

    try do
      create_pre_migration_tables!(prefix)
      seed_pre_migration_rows!(prefix)

      assert :ok =
               Ecto.Migrator.up(MigrationTestRepo, @migration_version, BackfillMigration,
                 prefix: prefix,
                 log: false
               )

      assert [
               ["account:mira"],
               ["account:other"],
               ["hostmask:other.host"],
               ["hostmask:user@host.example"]
             ] =
               query!("""
               SELECT identity_key
               FROM "#{prefix}".direct_message_block_identities
               ORDER BY identity_key
               """).rows

      assert [[3]] =
               query!("""
               SELECT count(*)
               FROM "#{prefix}".direct_message_identity_backfill_entries
               """).rows

      query!("""
      DELETE FROM "#{prefix}".direct_message_block_identities
      WHERE identity_key = 'account:other'
      """)

      assert [[2]] =
               query!("""
               SELECT count(*)
               FROM "#{prefix}".direct_message_identity_backfill_entries
               """).rows

      query!("""
      INSERT INTO "#{prefix}".direct_message_block_identities (
        identity_key,
        direct_message_thread_id,
        server_connection_id,
        user_id,
        inserted_at,
        updated_at
      ) VALUES ('account:later', 12, 1, 1, NOW(), NOW())
      """)

      assert :ok =
               Ecto.Migrator.up(MigrationTestRepo, @repair_migration_version, RepairMigration,
                 prefix: prefix,
                 log: false
               )

      assert [[false]] =
               query!("""
               SELECT tracker_created
               FROM "#{prefix}".direct_message_identity_backfill_tracking_repairs
               """).rows

      assert :ok =
               Ecto.Migrator.down(
                 MigrationTestRepo,
                 @repair_migration_version,
                 RepairMigration,
                 prefix: prefix,
                 log: false
               )

      assert [[2]] =
               query!("""
               SELECT count(*)
               FROM "#{prefix}".direct_message_identity_backfill_entries
               """).rows

      assert :ok =
               Ecto.Migrator.down(MigrationTestRepo, @migration_version, BackfillMigration,
                 prefix: prefix,
                 log: false
               )

      assert [["account:later"], ["account:mira"]] =
               query!("""
               SELECT identity_key
               FROM "#{prefix}".direct_message_block_identities
               ORDER BY identity_key
               """).rows

      assert [[0]] =
               query!(
                 """
                 SELECT count(*)
                 FROM information_schema.tables
                 WHERE table_schema = $1
                   AND table_name = 'direct_message_identity_backfill_entries'
                 """,
                 [prefix]
               ).rows
    after
      query!(~s(DROP SCHEMA IF EXISTS "#{prefix}" CASCADE))
    end
  end

  test "repairs an already-applied empty development database without breaking rollback" do
    prefix =
      "dm_identity_repair_'$$$topics_club_migration_0$quoted_#{System.unique_integer([:positive])}"

    query!(~s(CREATE SCHEMA "#{prefix}"))

    try do
      create_pre_migration_tables!(prefix)

      assert :ok =
               Ecto.Migrator.up(MigrationTestRepo, @repair_migration_version, RepairMigration,
                 prefix: prefix,
                 log: false
               )

      assert [[true]] =
               query!("""
               SELECT tracker_created
               FROM "#{prefix}".direct_message_identity_backfill_tracking_repairs
               """).rows

      assert [[0]] =
               query!("""
               SELECT count(*)
               FROM "#{prefix}".direct_message_identity_backfill_entries
               """).rows

      query!("""
      INSERT INTO "#{prefix}".schema_migrations (version, inserted_at)
      VALUES (#{@migration_version}, NOW())
      """)

      assert :ok =
               Ecto.Migrator.down(
                 MigrationTestRepo,
                 @repair_migration_version,
                 RepairMigration,
                 prefix: prefix,
                 log: false
               )

      assert :ok =
               Ecto.Migrator.down(MigrationTestRepo, @migration_version, BackfillMigration,
                 prefix: prefix,
                 log: false
               )

      assert [[0]] =
               query!(
                 """
                 SELECT count(*)
                 FROM information_schema.tables
                 WHERE table_schema = $1
                   AND table_name IN (
                     'direct_message_identity_backfill_entries',
                     'direct_message_identity_backfill_tracking_repairs'
                   )
                 """,
                 [prefix]
               ).rows
    after
      query!(~s(DROP SCHEMA IF EXISTS "#{prefix}" CASCADE))
    end
  end

  test "requires a reset when an applied database has identity rows without provenance" do
    prefix = "dm_identity_reset_#{System.unique_integer([:positive])}"

    query!(~s(CREATE SCHEMA "#{prefix}"))

    try do
      create_pre_migration_tables!(prefix)
      seed_pre_migration_rows!(prefix)

      assert_raise Postgrex.Error, ~r/provenance cannot be reconstructed/, fn ->
        Ecto.Migrator.up(MigrationTestRepo, @repair_migration_version, RepairMigration,
          prefix: prefix,
          log: false
        )
      end

      assert [[0]] =
               query!(
                 """
                 SELECT count(*)
                 FROM information_schema.tables
                 WHERE table_schema = $1
                   AND table_name IN (
                     'direct_message_identity_backfill_entries',
                     'direct_message_identity_backfill_tracking_repairs'
                   )
                 """,
                 [prefix]
               ).rows
    after
      query!(~s(DROP SCHEMA IF EXISTS "#{prefix}" CASCADE))
    end
  end

  defp create_pre_migration_tables!(prefix) do
    query!(~s|CREATE TABLE "#{prefix}".users (id bigint PRIMARY KEY)|)

    query!("""
    CREATE TABLE "#{prefix}".server_connections (
      id bigint PRIMARY KEY,
      user_id bigint NOT NULL REFERENCES "#{prefix}".users(id) ON DELETE CASCADE
    )
    """)

    query!("""
    CREATE TABLE "#{prefix}".direct_message_threads (
      id bigint PRIMARY KEY,
      identity_key varchar(255),
      account varchar(255),
      hostmask varchar(255),
      blocked_at timestamp(0) without time zone,
      server_connection_id bigint NOT NULL
        REFERENCES "#{prefix}".server_connections(id) ON DELETE CASCADE,
      user_id bigint NOT NULL REFERENCES "#{prefix}".users(id) ON DELETE CASCADE
    )
    """)

    query!("""
    CREATE TABLE "#{prefix}".direct_message_block_identities (
      id bigserial PRIMARY KEY,
      identity_key varchar(255) NOT NULL,
      direct_message_thread_id bigint NOT NULL
        REFERENCES "#{prefix}".direct_message_threads(id) ON DELETE CASCADE,
      server_connection_id bigint NOT NULL
        REFERENCES "#{prefix}".server_connections(id) ON DELETE CASCADE,
      user_id bigint NOT NULL REFERENCES "#{prefix}".users(id) ON DELETE CASCADE,
      inserted_at timestamp(0) without time zone NOT NULL,
      updated_at timestamp(0) without time zone NOT NULL
    )
    """)

    query!("""
    CREATE UNIQUE INDEX direct_message_block_identities_connection_identity_index
    ON "#{prefix}".direct_message_block_identities (server_connection_id, identity_key)
    """)
  end

  defp seed_pre_migration_rows!(prefix) do
    query!(~s|INSERT INTO "#{prefix}".users (id) VALUES (1)|)
    query!(~s|INSERT INTO "#{prefix}".server_connections (id, user_id) VALUES (1, 1)|)

    query!("""
    INSERT INTO "#{prefix}".direct_message_threads (
      id,
      identity_key,
      account,
      hostmask,
      blocked_at,
      server_connection_id,
      user_id
    ) VALUES
      (11, 'nick:mira', ' Mira ', 'Mira!User@Host.Example', NOW(), 1, 1),
      (12, 'nick:other', 'Other', 'Other.Host', NOW(), 1, 1),
      (13, 'nick:open', 'Open', 'Open.Host', NULL, 1, 1)
    """)

    query!("""
    INSERT INTO "#{prefix}".direct_message_block_identities (
      identity_key,
      direct_message_thread_id,
      server_connection_id,
      user_id,
      inserted_at,
      updated_at
    ) VALUES ('account:mira', 11, 1, 1, NOW(), NOW())
    """)
  end

  defp query!(sql, params \\ []) do
    Ecto.Adapters.SQL.query!(MigrationTestRepo, sql, params, log: false)
  end
end
