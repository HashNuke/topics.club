defmodule Ircpipe.Repo.Migrations.AddChannelUserNickKeys do
  use Ecto.Migration

  def up do
    channel_users = qualified_table("channel_users")
    channel_memberships = qualified_table("channel_memberships")
    server_connections = qualified_table("server_connections")
    collisions = qualified_table("channel_user_nick_key_collisions")

    alter table(:channel_users) do
      add :nick_key, :string
    end

    create table(:channel_user_nick_key_collisions, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :nick, :string, null: false
      add :nick_key, :string, null: false
      add :role, :string, null: false
      add :status, :string, null: false
      add :hostmask, :string
      add :last_observed_at, :utc_datetime, null: false

      add :channel_membership_id,
          references(:channel_memberships, on_delete: :delete_all),
          null: false

      add :inserted_at, :utc_datetime, null: false
      add :updated_at, :utc_datetime, null: false
    end

    execute("""
    UPDATE #{channel_users} AS channel_user
    SET nick_key = CASE COALESCE(server_connection.casemapping, 'ascii')
      WHEN 'rfc1459' THEN translate(lower(channel_user.nick), E'[]\\\\~', '{}|^')
      WHEN 'strict_rfc1459' THEN translate(lower(channel_user.nick), E'[]\\\\', '{}|')
      ELSE lower(channel_user.nick)
    END
    FROM #{channel_memberships} AS membership
    JOIN #{server_connections} AS server_connection
      ON server_connection.id = membership.server_connection_id
    WHERE membership.id = channel_user.channel_membership_id
    """)

    execute("""
    INSERT INTO #{collisions} (
      id,
      nick,
      nick_key,
      role,
      status,
      hostmask,
      last_observed_at,
      channel_membership_id,
      inserted_at,
      updated_at
    )
    SELECT
      channel_user.id,
      channel_user.nick,
      channel_user.nick_key,
      channel_user.role,
      channel_user.status,
      channel_user.hostmask,
      channel_user.last_observed_at,
      channel_user.channel_membership_id,
      channel_user.inserted_at,
      channel_user.updated_at
    FROM #{channel_users} AS channel_user
    JOIN (
      SELECT id,
             row_number() OVER (
               PARTITION BY channel_membership_id, nick_key
               ORDER BY last_observed_at DESC NULLS LAST, id DESC
             ) AS duplicate_position
      FROM #{channel_users}
    ) AS ranked ON ranked.id = channel_user.id
    WHERE ranked.duplicate_position > 1
    """)

    execute("""
    DELETE FROM #{channel_users} AS channel_user
    USING #{collisions} AS collision
    WHERE channel_user.id = collision.id
    """)

    drop unique_index(:channel_users, [:channel_membership_id, :nick])

    alter table(:channel_users) do
      modify :nick_key, :string, null: false
    end

    create unique_index(:channel_users, [:channel_membership_id, :nick_key])
  end

  def down do
    channel_users = qualified_table("channel_users")
    channel_memberships = qualified_table("channel_memberships")
    collisions = qualified_table("channel_user_nick_key_collisions")

    drop unique_index(:channel_users, [:channel_membership_id, :nick_key])

    execute("""
    INSERT INTO #{channel_users} (
      id,
      nick,
      nick_key,
      role,
      status,
      hostmask,
      last_observed_at,
      channel_membership_id,
      inserted_at,
      updated_at
    )
    SELECT
      collision.id,
      collision.nick,
      collision.nick_key,
      collision.role,
      collision.status,
      collision.hostmask,
      collision.last_observed_at,
      collision.channel_membership_id,
      collision.inserted_at,
      collision.updated_at
    FROM #{collisions} AS collision
    JOIN #{channel_memberships} AS membership
      ON membership.id = collision.channel_membership_id
    WHERE NOT EXISTS (
      SELECT 1
      FROM #{channel_users} AS existing_user
      WHERE existing_user.channel_membership_id = collision.channel_membership_id
        AND existing_user.nick = collision.nick
    )
    """)

    create unique_index(:channel_users, [:channel_membership_id, :nick])

    alter table(:channel_users) do
      remove :nick_key
    end

    drop table(:channel_user_nick_key_collisions)
  end

  defp qualified_table(table_name) do
    case prefix() do
      nil -> ~s("#{table_name}")
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}"."#{table_name}")
    end
  end
end
