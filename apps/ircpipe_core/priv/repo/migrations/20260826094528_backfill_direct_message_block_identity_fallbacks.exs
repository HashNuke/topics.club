defmodule Ircpipe.Repo.Migrations.BackfillDirectMessageBlockIdentityFallbacks do
  use Ecto.Migration

  def up do
    identities = qualified_table("direct_message_block_identities")
    threads = qualified_table("direct_message_threads")
    backfill_entries = qualified_table("direct_message_identity_backfill_entries")

    create table(:direct_message_identity_backfill_entries, primary_key: false) do
      add :direct_message_block_identity_id,
          references(:direct_message_block_identities, on_delete: :delete_all),
          primary_key: true
    end

    execute("""
    WITH inserted AS (
      INSERT INTO #{identities}
        (identity_key, direct_message_thread_id, server_connection_id, user_id, inserted_at, updated_at)
      SELECT candidate.identity_key, thread.id, thread.server_connection_id, thread.user_id, NOW(), NOW()
      FROM #{threads} AS thread
      CROSS JOIN LATERAL (
        VALUES
          (
            CASE
              WHEN NULLIF(BTRIM(thread.account), '') IS NULL OR BTRIM(thread.account) = '*'
                THEN NULL
              ELSE 'account:' || LOWER(BTRIM(thread.account))
            END
          ),
          (
            CASE
              WHEN NULLIF(BTRIM(thread.hostmask), '') IS NULL THEN NULL
              WHEN POSITION('!' IN BTRIM(thread.hostmask)) > 0
                THEN 'hostmask:' || LOWER(
                  SUBSTRING(
                    BTRIM(thread.hostmask)
                    FROM POSITION('!' IN BTRIM(thread.hostmask)) + 1
                  )
                )
              ELSE 'hostmask:' || LOWER(BTRIM(thread.hostmask))
            END
          )
      ) AS candidate(identity_key)
      WHERE thread.blocked_at IS NOT NULL AND candidate.identity_key IS NOT NULL
      ON CONFLICT (server_connection_id, identity_key) DO NOTHING
      RETURNING id
    )
    INSERT INTO #{backfill_entries} (direct_message_block_identity_id)
    SELECT id FROM inserted
    """)
  end

  def down do
    identities = qualified_table("direct_message_block_identities")
    backfill_entries = qualified_table("direct_message_identity_backfill_entries")

    backfill_entries_regclass =
      qualified_table_literal("direct_message_identity_backfill_entries")

    execute(
      do_block("""
      IF to_regclass(#{backfill_entries_regclass}) IS NOT NULL THEN
        DELETE FROM #{identities} AS identity
        USING #{backfill_entries} AS backfill_entry
        WHERE identity.id = backfill_entry.direct_message_block_identity_id;
      END IF;
      """)
    )

    drop_if_exists table(:direct_message_identity_backfill_entries)
  end

  defp qualified_table(table_name) do
    case prefix() do
      nil -> ~s("#{table_name}")
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}"."#{table_name}")
    end
  end

  defp qualified_table_literal(table_name) do
    escaped_table = table_name |> qualified_table() |> String.replace("'", "''")
    "'#{escaped_table}'"
  end

  defp do_block(statements) do
    delimiter = available_dollar_delimiter(statements, 0)
    "DO #{delimiter}\nBEGIN\n#{statements}\nEND\n#{delimiter}"
  end

  defp available_dollar_delimiter(statements, suffix) do
    delimiter = "$ircpipe_migration_#{suffix}$"

    if String.contains?(statements, delimiter) do
      available_dollar_delimiter(statements, suffix + 1)
    else
      delimiter
    end
  end
end
