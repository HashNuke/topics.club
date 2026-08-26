defmodule Ircpipe.Repo.Migrations.BackfillDirectMessageBlockIdentityFallbacks do
  use Ecto.Migration

  def up do
    execute("""
    INSERT INTO direct_message_block_identities
      (identity_key, direct_message_thread_id, server_connection_id, user_id, inserted_at, updated_at)
    SELECT identities.identity_key, threads.id, threads.server_connection_id, threads.user_id, NOW(), NOW()
    FROM direct_message_threads AS threads
    CROSS JOIN LATERAL (
      VALUES
        (
          CASE
            WHEN NULLIF(BTRIM(threads.account), '') IS NULL OR BTRIM(threads.account) = '*'
              THEN NULL
            ELSE 'account:' || LOWER(BTRIM(threads.account))
          END
        ),
        (
          CASE
            WHEN NULLIF(BTRIM(threads.hostmask), '') IS NULL THEN NULL
            WHEN POSITION('!' IN BTRIM(threads.hostmask)) > 0
              THEN 'hostmask:' || LOWER(
                SUBSTRING(
                  BTRIM(threads.hostmask)
                  FROM POSITION('!' IN BTRIM(threads.hostmask)) + 1
                )
              )
            ELSE 'hostmask:' || LOWER(BTRIM(threads.hostmask))
          END
        )
    ) AS identities(identity_key)
    WHERE threads.blocked_at IS NOT NULL AND identities.identity_key IS NOT NULL
    ON CONFLICT (server_connection_id, identity_key) DO NOTHING
    """)
  end

  def down, do: :ok
end
