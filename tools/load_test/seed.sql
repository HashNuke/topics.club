\set ON_ERROR_STOP on

INSERT INTO users (
  email,
  name,
  last_seen_at,
  inserted_at,
  updated_at
)
SELECT
  'load-' || sequence || '@example.test',
  'Load user ' || sequence,
  NOW(),
  NOW(),
  NOW()
FROM generate_series(1, :load_connections) AS sequence;

INSERT INTO server_connections (
  name,
  host,
  port,
  use_tls,
  nickname,
  username,
  realname,
  status,
  desired_state,
  deleting,
  user_id,
  inserted_at,
  updated_at
)
SELECT
  'synthetic',
  'irc',
  6667,
  FALSE,
  'load' || users.id,
  'load' || users.id,
  'Load user ' || users.id,
  'disconnected',
  'connected',
  FALSE,
  users.id,
  NOW(),
  NOW()
FROM users
WHERE users.email LIKE 'load-%@example.test';
