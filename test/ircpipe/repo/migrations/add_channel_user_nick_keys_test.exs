defmodule Ircpipe.Repo.Migrations.AddChannelUserNickKeysTest do
  use ExUnit.Case, async: false

  alias Ircpipe.Irc.Identifier
  alias Ircpipe.MigrationTestRepo
  alias Ircpipe.Repo.Migrations.AddChannelUserNickKeys

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20260827063033_add_channel_user_nick_keys.exs",
                    __DIR__
                  )
  @migration_version 20_260_827_063_033

  Code.require_file(@migration_path)

  setup do
    repo_config =
      Ircpipe.Repo.config()
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({MigrationTestRepo, repo_config})
    :ok
  end

  test "backfills runtime-compatible keys and restores canonical collisions on rollback" do
    prefix = "nick_key_migration_#{System.unique_integer([:positive])}"

    query!(~s(CREATE SCHEMA "#{prefix}"))

    try do
      create_pre_migration_tables!(prefix)
      seed_pre_migration_users!(prefix)

      assert :ok =
               Ecto.Migrator.up(MigrationTestRepo, @migration_version, AddChannelUserNickKeys,
                 prefix: prefix,
                 log: false
               )

      rows =
        query!("""
        SELECT channel_user.nick, channel_user.nick_key, server_connection.casemapping
        FROM "#{prefix}".channel_users AS channel_user
        JOIN "#{prefix}".channel_memberships AS membership
          ON membership.id = channel_user.channel_membership_id
        JOIN "#{prefix}".server_connections AS server_connection
          ON server_connection.id = membership.server_connection_id
        ORDER BY channel_user.id
        """).rows

      assert Enum.map(rows, fn [nick, nick_key, mapping] ->
               {nick, nick_key, mapping}
             end) == [
               {"[Mira]", "[mira]", "ascii"},
               {"mi~ra", "mi^ra", "rfc1459"},
               {"{mira}", "{mira}", "rfc1459"},
               {"mi~ra", "mi~ra", "strict_rfc1459"},
               {"{orphan}", "{orphan}", "rfc1459"}
             ]

      Enum.each(rows, fn [nick, nick_key, mapping] ->
        assert nick_key == Identifier.key(nick, mapping_atom(mapping))
      end)

      assert [["[Mira]"], ["[Orphan]"]] =
               query!("""
               SELECT nick
               FROM "#{prefix}".channel_user_nick_key_collisions
               ORDER BY id
               """).rows

      query!("""
      UPDATE "#{prefix}".channel_users
      SET nick = '[Mira]'
      WHERE id = 4
      """)

      query!(~s|DELETE FROM "#{prefix}".channel_memberships WHERE id = 14|)

      assert [[0]] =
               query!("""
               SELECT count(*)
               FROM "#{prefix}".channel_user_nick_key_collisions
               WHERE channel_membership_id = 14
               """).rows

      assert :ok =
               Ecto.Migrator.down(
                 MigrationTestRepo,
                 @migration_version,
                 AddChannelUserNickKeys,
                 prefix: prefix,
                 log: false
               )

      assert [[4]] = query!(~s|SELECT count(*) FROM "#{prefix}".channel_users|).rows

      assert [[1]] =
               query!("""
               SELECT count(*)
               FROM "#{prefix}".channel_users
               WHERE channel_membership_id = 12
                 AND nick = '[Mira]'
               """).rows

      assert [[0]] =
               query!(
                 """
                 SELECT count(*)
                 FROM information_schema.columns
                 WHERE table_schema = $1
                   AND table_name = 'channel_users'
                   AND column_name = 'nick_key'
                 """,
                 [prefix]
               ).rows
    after
      query!(~s(DROP SCHEMA IF EXISTS "#{prefix}" CASCADE))
    end
  end

  defp create_pre_migration_tables!(prefix) do
    query!("""
    CREATE TABLE "#{prefix}".server_connections (
      id bigint PRIMARY KEY,
      casemapping varchar(255)
    )
    """)

    query!("""
    CREATE TABLE "#{prefix}".channel_memberships (
      id bigint PRIMARY KEY,
      server_connection_id bigint NOT NULL
        REFERENCES "#{prefix}".server_connections(id) ON DELETE CASCADE
    )
    """)

    query!("""
    CREATE TABLE "#{prefix}".channel_users (
      id bigint PRIMARY KEY,
      nick varchar(255) NOT NULL,
      role varchar(255) NOT NULL DEFAULT 'user',
      status varchar(255) NOT NULL DEFAULT 'online',
      hostmask varchar(255),
      last_observed_at timestamp(0) without time zone NOT NULL,
      channel_membership_id bigint NOT NULL
        REFERENCES "#{prefix}".channel_memberships(id) ON DELETE CASCADE,
      inserted_at timestamp(0) without time zone NOT NULL,
      updated_at timestamp(0) without time zone NOT NULL
    )
    """)

    query!("""
    CREATE UNIQUE INDEX channel_users_channel_membership_id_nick_index
    ON "#{prefix}".channel_users (channel_membership_id, nick)
    """)
  end

  defp seed_pre_migration_users!(prefix) do
    query!("""
    INSERT INTO "#{prefix}".server_connections (id, casemapping)
    VALUES (1, 'ascii'), (2, 'rfc1459'), (3, 'strict_rfc1459')
    """)

    query!("""
    INSERT INTO "#{prefix}".channel_memberships (id, server_connection_id)
    VALUES (11, 1), (12, 2), (13, 3), (14, 2)
    """)

    query!("""
    INSERT INTO "#{prefix}".channel_users (
      id, nick, role, status, last_observed_at, channel_membership_id, inserted_at, updated_at
    )
    VALUES
      (1, '[Mira]', 'user', 'online', now(), 11, now(), now()),
      (2, 'mi~ra', 'user', 'online', now(), 12, now(), now()),
      (3, '[Mira]', 'user', 'online', now(), 12, now(), now()),
      (4, '{mira}', 'op', 'online', now(), 12, now(), now()),
      (5, 'mi~ra', 'user', 'online', now(), 13, now(), now()),
      (6, '[Orphan]', 'user', 'online', now(), 14, now(), now()),
      (7, '{orphan}', 'op', 'online', now(), 14, now(), now())
    """)
  end

  defp query!(sql, params \\ []) do
    Ecto.Adapters.SQL.query!(MigrationTestRepo, sql, params, log: false)
  end

  defp mapping_atom("ascii"), do: :ascii
  defp mapping_atom("rfc1459"), do: :rfc1459
  defp mapping_atom("strict_rfc1459"), do: :strict_rfc1459
end
