"""Provision the destination-local PostgreSQL service for TopicsClub."""

from pyinfra import host
from pyinfra.facts.files import File
from pyinfra.operations import apt, files, server, systemd


POSTGRES_MAJOR = 18
DATABASE_ENV = "/etc/topics-club/db.env"

apt.packages(
    name="Install PostgreSQL repository prerequisites",
    packages=["ca-certificates", "gnupg", "openssl", "wget"],
    present=True,
    update=True,
    cache_time=86_400,
    no_recommends=True,
)

apt.key(
    name="Install the PostgreSQL Apt repository signing key",
    src="https://www.postgresql.org/media/keys/ACCC4CF8.asc",
    dest="postgresql.gpg",
)

apt.repo(
    name="Configure the PostgreSQL Apt repository for Ubuntu 26.04",
    src=(
        "deb [signed-by=/etc/apt/keyrings/postgresql.gpg] "
        "https://apt.postgresql.org/pub/repos/apt resolute-pgdg main"
    ),
    filename="postgresql",
)

apt.packages(
    name=f"Install the latest PostgreSQL {POSTGRES_MAJOR} packages",
    packages=[f"postgresql-{POSTGRES_MAJOR}", f"postgresql-client-{POSTGRES_MAJOR}"],
    present=True,
    latest=True,
    update=True,
    cache_time=86_400,
    no_recommends=True,
)

systemd.service(
    name="Enable and start PostgreSQL",
    service="postgresql.service",
    running=True,
    enabled=True,
)

files.directory(
    name="Create the TopicsClub configuration directory",
    path="/etc/topics-club",
    user="root",
    group="root",
    mode="0755",
)

database_env = host.get_fact(File, path=DATABASE_ENV)
if database_env is False:
    raise RuntimeError(f"{DATABASE_ENV} exists but is not a regular file")

if database_env is None:
    server.shell(
        name="Create the TopicsClub database, role, and destination-only database URL",
        commands=r"""
set -eu
database_env=/etc/topics-club/db.env
database_password=$(openssl rand -hex 32)

if ! runuser --user postgres -- psql --no-psqlrc --tuples-only --no-align --dbname postgres \
    --command "SELECT 1 FROM pg_roles WHERE rolname = 'topics_club'" | grep -qx 1; then
  runuser --user postgres -- createuser --login topics_club
fi

printf "ALTER ROLE topics_club WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD '%s';\n" \
  "$database_password" | \
  runuser --user postgres -- psql --no-psqlrc --set ON_ERROR_STOP=1 --quiet --dbname postgres \
  >/dev/null

if ! runuser --user postgres -- psql --no-psqlrc --tuples-only --no-align --dbname postgres \
    --command "SELECT 1 FROM pg_database WHERE datname = 'topics_club_prod'" | grep -qx 1; then
  runuser --user postgres -- createdb --owner=topics_club --encoding=UTF8 topics_club_prod
else
  runuser --user postgres -- psql --no-psqlrc --set ON_ERROR_STOP=1 --quiet --dbname postgres \
    --command 'ALTER DATABASE topics_club_prod OWNER TO topics_club' >/dev/null
fi

database_env_tmp=$(mktemp /etc/topics-club/.db.env.XXXXXX)
trap 'rm -f -- "$database_env_tmp"' EXIT HUP INT TERM
printf 'DATABASE_URL=ecto://topics_club:%s@127.0.0.1:5432/topics_club_prod\n' \
  "$database_password" >"$database_env_tmp"
chown root:root "$database_env_tmp"
chmod 0600 "$database_env_tmp"
mv -- "$database_env_tmp" "$database_env"
trap - EXIT HUP INT TERM
""",
    )

files.file(
    name="Protect the generated database environment file",
    path=DATABASE_ENV,
    user="root",
    group="root",
    mode="0600",
    create_remote_dir=False,
)

server.shell(
    name="Verify the destination-local TopicsClub database without exposing credentials",
    commands=r"""
set -eu
grep -Eq '^DATABASE_URL=ecto://topics_club:[0-9a-f]{64}@127\.0\.0\.1:5432/topics_club_prod$' \
  /etc/topics-club/db.env
test "$(runuser --user postgres -- psql --no-psqlrc --tuples-only --no-align --dbname postgres \
  --command "SELECT 1 FROM pg_roles WHERE rolname = 'topics_club'")" = 1
test "$(runuser --user postgres -- psql --no-psqlrc --tuples-only --no-align --dbname postgres \
  --command "SELECT 1 FROM pg_database WHERE datname = 'topics_club_prod'")" = 1
test "$(runuser --user postgres -- psql --no-psqlrc --tuples-only --no-align --dbname postgres \
  --command 'SHOW listen_addresses')" = localhost
""",
)
