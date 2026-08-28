import hashlib
import shlex
from pathlib import Path

from pyinfra import host
from pyinfra.facts.files import File, Sha256File
from pyinfra.facts.server import Command
from pyinfra.operations import apt, files, server, systemd


DEPLOY_DIR = Path(__file__).resolve().parent
SYSTEMD_UNITS = [
    "topics-club-gateway.service",
    "topics-club-engine.service",
    "topics-club-migrate.service",
    "topics-club-engine-health.service",
]

apt.packages(
    name="Install the TopicsClub host runtime and container build tools",
    packages=[
        "ca-certificates",
        "curl",
        "docker-buildx",
        "docker.io",
        "git",
        "libncurses6",
        "libstdc++6",
        "locales",
        "openssl",
        "util-linux",
    ],
    present=True,
    update=True,
    cache_time=86_400,
    no_recommends=True,
)

# A clean release build can exceed the 1.5 GB runtime-memory floor. Bare hosts
# with less than 4 GiB of swap get one exact, persistent build-swap file. The
# pseudo-VPS already uses the outer Docker host's swap through its cgroup limit.
containerized = host.get_fact(File, path="/.dockerenv") is not None
swap_total_lines = host.get_fact(
    Command,
    command="awk '/^SwapTotal:/ {print $2}' /proc/meminfo",
)
memory_total_lines = host.get_fact(
    Command,
    command="awk '/^MemTotal:/ {print $2}' /proc/meminfo",
)
swap_total_kib = int(swap_total_lines[0]) if swap_total_lines else 0
memory_total_kib = int(memory_total_lines[0]) if memory_total_lines else 0

if (
    not containerized
    and memory_total_kib < 4 * 1024 * 1024
    and swap_total_kib < 4 * 1024 * 1024
):
    swap_file = host.get_fact(File, path="/swapfile")
    if swap_file is False:
        raise RuntimeError("/swapfile exists but is not a regular file")
    if swap_file is not None and swap_file["size"] < 4 * 1024 * 1024 * 1024:
        raise RuntimeError("existing /swapfile is smaller than the required 4 GiB")

    if swap_file is None:
        server.shell(
            name="Create the bounded build swap file",
            commands="fallocate -l 4G /swapfile && chmod 0600 /swapfile && mkswap /swapfile",
        )

    files.file(
        name="Protect the build swap file",
        path="/swapfile",
        user="root",
        group="root",
        mode="0600",
    )

    files.line(
        name="Persist the build swap file",
        path="/etc/fstab",
        line="/swapfile none swap sw 0 0",
        escape_regex_characters=True,
        ensure_newline=True,
    )

    server.shell(
        name="Enable the build swap file",
        commands="swapon /swapfile",
    )

apt.packages(
    name="Keep host Erlang, Elixir, Node.js, and npm packages absent",
    packages=["elixir", "erlang-base", "nodejs", "npm"],
    present=False,
    purge=True,
)

systemd.service(
    name="Enable and start the container build service",
    service="docker.service",
    running=True,
    enabled=True,
)

server.group(
    name="Create the TopicsClub deployment group",
    group="topics-club-deploy",
    system=True,
)

server.user(
    name="Create the controlled TopicsClub deployment user",
    user="topics-club-deploy",
    group="topics-club-deploy",
    home="/srv/topics-club/build-home",
    shell="/usr/sbin/nologin",
    system=True,
    ensure_home=False,
)

for role in ("gateway", "engine"):
    server.group(
        name=f"Create the TopicsClub {role} group",
        group=f"topics-club-{role}",
        system=True,
    )

    server.user(
        name=f"Create the unprivileged TopicsClub {role} user",
        user=f"topics-club-{role}",
        group=f"topics-club-{role}",
        home=f"/var/lib/topics-club/{role}",
        shell="/usr/sbin/nologin",
        system=True,
        ensure_home=False,
    )

for path, user, group, mode in [
    ("/etc/topics-club", "root", "root", "0755"),
    ("/srv/topics-club", "topics-club-deploy", "topics-club-deploy", "0755"),
    ("/srv/topics-club/build-home", "topics-club-deploy", "topics-club-deploy", "0700"),
    ("/srv/topics-club/sources", "topics-club-deploy", "topics-club-deploy", "0750"),
    ("/srv/topics-club/releases", "topics-club-deploy", "topics-club-deploy", "0755"),
    ("/srv/topics-club/releases/gateway", "topics-club-deploy", "topics-club-deploy", "0755"),
    ("/srv/topics-club/releases/engine", "topics-club-deploy", "topics-club-deploy", "0755"),
    ("/var/lib/topics-club", "root", "root", "0755"),
    ("/var/lib/topics-club/gateway", "topics-club-gateway", "topics-club-gateway", "0750"),
    ("/var/lib/topics-club/gateway/tmp", "topics-club-gateway", "topics-club-gateway", "0750"),
    ("/var/lib/topics-club/engine", "topics-club-engine", "topics-club-engine", "0750"),
    ("/var/lib/topics-club/engine/tmp", "topics-club-engine", "topics-club-engine", "0750"),
]:
    files.directory(
        name=f"Configure {path}",
        path=path,
        user=user,
        group=group,
        mode=mode,
    )

for role in ("gateway", "engine"):
    environment_path = f"/etc/topics-club/{role}.env"
    if not host.get_fact(File, path=environment_path):
        raise RuntimeError(
            f"missing {environment_path}; create it on the destination before provisioning"
        )
    files.file(
        name=f"Verify {environment_path} metadata without reading its contents",
        path=environment_path,
        user=f"topics-club-{role}",
        group=f"topics-club-{role}",
        mode="0600",
        create_remote_dir=False,
    )

systemd_units_changed = any(
    host.get_fact(Sha256File, path=f"/etc/systemd/system/{unit}")
    != hashlib.sha256((DEPLOY_DIR / unit).read_bytes()).hexdigest()
    for unit in SYSTEMD_UNITS
)

for unit in SYSTEMD_UNITS:
    files.put(
        name=f"Install {unit}",
        src=str(DEPLOY_DIR / unit),
        dest=f"/etc/systemd/system/{unit}",
        user="root",
        group="root",
        mode="0644",
    )

files.put(
    name="Install the pinned release-builder Dockerfile",
    src=str(DEPLOY_DIR / "release-builder.dockerfile"),
    dest="/etc/topics-club/release-builder.dockerfile",
    user="root",
    group="root",
    mode="0644",
)

files.template(
    name="Install the atomic TopicsClub deploy program",
    src=str(DEPLOY_DIR / "topics-club-deploy.sh.j2"),
    dest="/usr/local/sbin/topics-club-deploy",
    user="root",
    group="root",
    mode="0755",
    repo_url_quoted=shlex.quote(host.data.repo_url),
)

systemd.service(
    name="Enable the TopicsClub gateway service without starting it",
    service="topics-club-gateway.service",
    running=None,
    enabled=True,
    daemon_reload=systemd_units_changed,
)

systemd.service(
    name="Enable the TopicsClub engine service without starting it",
    service="topics-club-engine.service",
    running=None,
    enabled=True,
)
