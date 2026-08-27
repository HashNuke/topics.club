defmodule Ircpipe.Repo.Migrations.RepairDirectMessageIdentityBackfillTracking do
  use Ecto.Migration

  def up do
    identities = qualified_table("direct_message_block_identities")

    backfill_entries_regclass =
      qualified_table_literal("direct_message_identity_backfill_entries")

    repair_state = qualified_table("direct_message_identity_backfill_tracking_repairs")

    create table(:direct_message_identity_backfill_tracking_repairs, primary_key: false) do
      add :id, :integer, primary_key: true
      add :tracker_created, :boolean, null: false
    end

    execute("""
    INSERT INTO #{repair_state} (id, tracker_created)
    SELECT 1, to_regclass(#{backfill_entries_regclass}) IS NULL
    """)

    execute(
      do_block("""
      IF (SELECT tracker_created FROM #{repair_state} WHERE id = 1)
         AND EXISTS (SELECT 1 FROM #{identities}) THEN
        RAISE EXCEPTION
          'direct-message identity backfill provenance cannot be reconstructed; reset this development database before migrating';
      END IF;
      """)
    )

    create_if_not_exists table(:direct_message_identity_backfill_entries, primary_key: false) do
      add :direct_message_block_identity_id,
          references(:direct_message_block_identities, on_delete: :delete_all),
          primary_key: true
    end
  end

  def down do
    backfill_entries = qualified_table("direct_message_identity_backfill_entries")
    repair_state = qualified_table("direct_message_identity_backfill_tracking_repairs")

    execute(
      do_block("""
      IF (SELECT tracker_created FROM #{repair_state} WHERE id = 1) THEN
        DROP TABLE #{backfill_entries};
      END IF;
      """)
    )

    drop table(:direct_message_identity_backfill_tracking_repairs)
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
