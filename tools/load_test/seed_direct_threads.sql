\set ON_ERROR_STOP on

INSERT INTO direct_message_threads (
  peer_nick,
  peer_key,
  server_connection_id,
  user_id,
  inserted_at,
  updated_at
)
SELECT
  'peer',
  'peer',
  connections.id,
  connections.user_id,
  NOW(),
  NOW()
FROM server_connections AS connections;
