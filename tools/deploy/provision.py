import hashlib
import io
import shlex
from pathlib import Path

from pyinfra import host
from pyinfra.facts.files import File, Sha256File
from pyinfra.facts.server import Command
from pyinfra.operations import apt, files, server, systemd


DEPLOY_DIR = Path(__file__).resolve().parent
gateway_host = host.data.gateway_host
SYSTEMD_UNITS = [
    "topics-club-gateway.service",
    "topics-club-wirekeeper.service",
    "topics-club-wirekeeper-health.service",
    "topics-club-engine.service",
    "topics-club-migrate.service",
    "topics-club-engine-health.service",
]
SSHD_CONFIG = DEPLOY_DIR / "sshd-topics-club.conf"
SSHD_CONFIG_PATH = "/etc/ssh/sshd_config.d/00-topics-club-hardening.conf"

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
        "openssh-client",
        "util-linux",
        "ufw",
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
swap_total_output = host.get_fact(
    Command,
    command="awk '/^SwapTotal:/ {print $2}' /proc/meminfo",
)
active_swap_output = host.get_fact(
    Command,
    command="swapon --show=NAME --noheadings",
)
memory_total_output = host.get_fact(
    Command,
    command="awk '/^MemTotal:/ {print $2}' /proc/meminfo",
)
swap_total_kib = int(swap_total_output.strip()) if swap_total_output else 0
memory_total_kib = int(memory_total_output.strip()) if memory_total_output else 0
active_swaps = {line.strip() for line in active_swap_output.splitlines()}

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

    if "/swapfile" not in active_swaps:
        server.shell(
            name="Enable the build swap file",
            commands="swapon --show=NAME --noheadings | grep -Fxq /swapfile || swapon /swapfile",
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

sshd_config_changed = (
    host.get_fact(Sha256File, path=SSHD_CONFIG_PATH)
    != hashlib.sha256(SSHD_CONFIG.read_bytes()).hexdigest()
)
files.put(
    name="Require key authentication for SSH",
    src=str(SSHD_CONFIG),
    dest=SSHD_CONFIG_PATH,
    user="root",
    group="root",
    mode="0644",
)
server.shell(
    name="Validate the hardened SSH configuration",
    commands="sshd -t",
)
systemd.service(
    name="Reload SSH after hardening",
    service="ssh.service",
    running=True,
    reloaded=sshd_config_changed,
)

if gateway_host:
    apt.packages(
        name="Install the HTTPS reverse proxy",
        packages=["caddy"],
        present=True,
        update=False,
        no_recommends=True,
    )

    caddyfile = (
        f"{gateway_host} {{\n"
        "\treverse_proxy 127.0.0.1:4000\n"
        "}\n\n"
        f"www.{gateway_host} {{\n"
        f"\tredir https://{gateway_host}{{uri}} permanent\n"
        "}\n"
    )
    caddyfile_path = "/etc/caddy/Caddyfile"
    caddyfile_changed = (
        host.get_fact(Sha256File, path=caddyfile_path)
        != hashlib.sha256(caddyfile.encode()).hexdigest()
    )

    files.put(
        name="Configure the TopicsClub HTTPS reverse proxy",
        src=io.StringIO(caddyfile),
        dest=caddyfile_path,
        user="root",
        group="root",
        mode="0644",
    )
    if caddyfile_changed:
        server.shell(
            name="Validate the Caddy configuration",
            commands=f"caddy validate --config {caddyfile_path}",
        )
    systemd.service(
        name="Enable and start the HTTPS reverse proxy",
        service="caddy.service",
        running=True,
        enabled=True,
        restarted=caddyfile_changed,
    )

    ufw_binary = host.get_fact(File, path="/usr/sbin/ufw")
    if ufw_binary is False:
        raise RuntimeError("/usr/sbin/ufw exists but is not a regular file")
    ufw_exists = ufw_binary is not None
    if ufw_exists:
        ufw_rules = host.get_fact(Command, command="ufw show added")
        ufw_status = host.get_fact(Command, command="ufw status")
        ufw_defaults = host.get_fact(
            Command,
            command="grep -E '^(IPV6|DEFAULT_INPUT_POLICY|DEFAULT_OUTPUT_POLICY)=' /etc/default/ufw",
        )
    else:
        ufw_rules = ""
        ufw_status = ""
        ufw_defaults = ""

    if 'IPV6=yes' not in ufw_defaults:
        server.shell(
            name="Enable IPv6 firewall coverage",
            commands=(
                "grep -qx 'IPV6=yes' /etc/default/ufw || "
                "sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw"
            ),
        )
    if 'DEFAULT_INPUT_POLICY="DROP"' not in ufw_defaults:
        server.shell(
            name="Deny unsolicited inbound traffic by default",
            commands="ufw default deny incoming",
        )
    if 'DEFAULT_OUTPUT_POLICY="ACCEPT"' not in ufw_defaults:
        server.shell(
            name="Allow outbound traffic by default",
            commands="ufw default allow outgoing",
        )

    for port, comment in [
        (int(host.data.ssh_port), "SSH"),
        (80, "HTTP"),
        (443, "HTTPS"),
    ]:
        if f"ufw allow {port}/tcp" not in ufw_rules:
            server.shell(
                name=f"Permit {comment} through the host firewall",
                commands=f"ufw allow {port}/tcp comment '{comment}'",
            )

    if "Status: active" not in ufw_status:
        server.shell(
            name="Enable the host firewall",
            commands="ufw --force enable",
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

for role in ("gateway", "wirekeeper", "engine"):
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
    ("/srv/topics-club/releases/wirekeeper", "topics-club-deploy", "topics-club-deploy", "0755"),
    ("/srv/topics-club/releases/engine", "topics-club-deploy", "topics-club-deploy", "0755"),
    ("/var/lib/topics-club", "root", "root", "0755"),
    ("/var/lib/topics-club/gateway", "topics-club-gateway", "topics-club-gateway", "0750"),
    ("/var/lib/topics-club/gateway/tmp", "topics-club-gateway", "topics-club-gateway", "0750"),
    ("/var/lib/topics-club/wirekeeper", "topics-club-wirekeeper", "topics-club-wirekeeper", "0750"),
    ("/var/lib/topics-club/wirekeeper/tmp", "topics-club-wirekeeper", "topics-club-wirekeeper", "0750"),
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

if host.data.repo_url.startswith("git@github.com:"):
    ssh_directory = "/srv/topics-club/build-home/.ssh"
    deploy_key = f"{ssh_directory}/id_ed25519"
    deploy_public_key = f"{deploy_key}.pub"

    files.directory(
        name="Configure the deployment user's SSH directory",
        path=ssh_directory,
        user="topics-club-deploy",
        group="topics-club-deploy",
        mode="0700",
    )

    existing_deploy_key = host.get_fact(File, path=deploy_key)
    existing_deploy_public_key = host.get_fact(File, path=deploy_public_key)
    if existing_deploy_key is False:
        raise RuntimeError(f"{deploy_key} exists but is not a regular file")
    if existing_deploy_public_key is False:
        raise RuntimeError(f"{deploy_public_key} exists but is not a regular file")
    if existing_deploy_key is None and existing_deploy_public_key is not None:
        raise RuntimeError(f"{deploy_public_key} exists without its private key")
    if existing_deploy_key is None:
        server.shell(
            name="Generate the destination-only GitHub deploy key",
            commands=(
                "runuser -u topics-club-deploy -- "
                f"ssh-keygen -q -t ed25519 -N '' -C topics-club-deploy -f {deploy_key}"
            ),
        )
    elif existing_deploy_public_key is None:
        server.shell(
            name="Restore the GitHub deploy public key",
            commands=(
                f"ssh-keygen -y -f {deploy_key} | "
                f"sed 's/$/ topics-club-deploy/' > {deploy_public_key}"
            ),
        )

    files.file(
        name="Protect the GitHub deploy key",
        path=deploy_key,
        user="topics-club-deploy",
        group="topics-club-deploy",
        mode="0600",
    )
    files.file(
        name="Publish the GitHub deploy public key locally",
        path=deploy_public_key,
        user="topics-club-deploy",
        group="topics-club-deploy",
        mode="0644",
    )
    files.put(
        name="Pin GitHub's published Ed25519 host key",
        src=io.StringIO(
            "github.com ssh-ed25519 "
            "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n"
        ),
        dest=f"{ssh_directory}/known_hosts",
        user="topics-club-deploy",
        group="topics-club-deploy",
        mode="0644",
    )

database_environment_path = "/etc/topics-club/db.env"
if not host.get_fact(File, path=database_environment_path):
    raise RuntimeError(
        f"missing {database_environment_path}; run `bin/apptools provision-db` first"
    )
files.file(
    name=f"Verify {database_environment_path} metadata without reading its contents",
    path=database_environment_path,
    user="root",
    group="root",
    mode="0600",
    create_remote_dir=False,
)

for role in ("gateway", "wirekeeper", "engine"):
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
    name="Enable the TopicsClub Wirekeeper service without starting it",
    service="topics-club-wirekeeper.service",
    running=None,
    enabled=True,
)

systemd.service(
    name="Enable the TopicsClub engine service without starting it",
    service="topics-club-engine.service",
    running=None,
    enabled=True,
)
