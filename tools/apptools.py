#!/usr/bin/env python3
"""Small operator CLI for provisioning and deploying TopicsClub."""

from __future__ import annotations

import json
import re
import secrets
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import urlparse

import fire


PROJECT_ROOT = Path(__file__).resolve().parent.parent
STATE_DIR = PROJECT_ROOT / ".apptools" / "vps"
STATE_FILE = STATE_DIR / "state.json"
PRIVATE_KEY = STATE_DIR / "id_ed25519"
PUBLIC_KEY = STATE_DIR / "id_ed25519.pub"

VPS_IMAGE = "topics-club-vps:ubuntu-26.04"
VPS_CONTAINER = "topics-club-vps"
POSTGRES_CONTAINER = "topics-club-vps-postgres"
POSTGRES_VOLUME = "topics-club-vps-postgres-data"
DOCKER_VOLUME = "topics-club-vps-docker-data"
VPS_NETWORK = "topics-club-vps"
VPS_SSH_PORT = 45_122
VPS_HTTP_PORT = 45_100
VPS_MEMORY_BYTES = 1_610_612_736
VPS_MEMORY_SWAP_BYTES = 5_905_580_032
DEFAULT_REPOSITORY = "https://github.com/HashNuke/topics.club.git"
RELEASE_TAG = re.compile(r"^(\d{8})\.(\d+)$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")


def run(
    command: list[str],
    *,
    cwd: Path = PROJECT_ROOT,
    capture: bool = False,
    quiet: bool = False,
) -> subprocess.CompletedProcess[str]:
    kwargs: dict[str, object] = {
        "cwd": cwd,
        "check": True,
        "text": True,
    }
    if capture:
        kwargs["stdout"] = subprocess.PIPE
    if quiet:
        kwargs["stdout"] = subprocess.DEVNULL
        kwargs["stderr"] = subprocess.DEVNULL
    return subprocess.run(command, **kwargs)  # type: ignore[arg-type]


def output(command: list[str], *, cwd: Path = PROJECT_ROOT) -> str:
    return run(command, cwd=cwd, capture=True).stdout.strip()


def docker_object_exists(kind: str, name: str) -> bool:
    result = subprocess.run(
        ["docker", kind, "inspect", name],
        cwd=PROJECT_ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0


def ensure_test_key() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    if PRIVATE_KEY.exists() and PUBLIC_KEY.exists():
        return
    run(
        [
            "ssh-keygen",
            "-q",
            "-t",
            "ed25519",
            "-N",
            "",
            "-C",
            "topics-club-pseudo-vps",
            "-f",
            str(PRIVATE_KEY),
        ]
    )
    PRIVATE_KEY.chmod(0o600)


def remove_exact_container(name: str) -> None:
    if docker_object_exists("container", name):
        run(["docker", "rm", "--force", name])


def remove_exact_volume(name: str) -> None:
    if docker_object_exists("volume", name):
        run(["docker", "volume", "rm", name])


def remove_exact_network(name: str) -> None:
    if docker_object_exists("network", name):
        run(["docker", "network", "rm", name])


def write_test_environment(state: dict[str, str]) -> None:
    gateway = "\n".join(
        [
            f"DATABASE_URL={state['database_url']}",
            f"IRC_CREDENTIALS_KEY={state['credentials_key']}",
            f"SECRET_KEY_BASE={state['secret_key_base']}",
            "PHX_HOST=localhost",
            "PORT=4000",
            "POOL_SIZE=5",
            "RELEASE_NODE=topics_club_gateway@localhost",
            f"RELEASE_COOKIE={state['release_cookie']}",
            "TOPICS_CLUB_ENGINE_NODE=topics_club_engine@localhost",
            "",
        ]
    )
    engine = "\n".join(
        [
            f"DATABASE_URL={state['database_url']}",
            f"IRC_CREDENTIALS_KEY={state['credentials_key']}",
            "POOL_SIZE=5",
            "RELEASE_NODE=topics_club_engine@localhost",
            f"RELEASE_COOKIE={state['release_cookie']}",
            "",
        ]
    )

    run(
        ["docker", "exec", VPS_CONTAINER, "install", "-d", "-m", "0755", "/etc/topics-club"]
    )
    for name, contents in (("gateway.env", gateway), ("engine.env", engine)):
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8") as temporary:
            temporary.write(contents)
            temporary.flush()
            run(
                [
                    "docker",
                    "cp",
                    temporary.name,
                    f"{VPS_CONTAINER}:/etc/topics-club/{name}",
                ]
            )
        run(
            [
                "docker",
                "exec",
                VPS_CONTAINER,
                "chmod",
                "0600",
                f"/etc/topics-club/{name}",
            ]
        )


def split_host(host: str, ssh_port: int | None, ssh_key: str | None) -> tuple[str, str, int, str | None]:
    if "," in host or any(character.isspace() for character in host):
        raise ValueError("exactly one SSH host is supported")

    ssh_user = "root"
    inventory_host = host
    if "@" in host:
        ssh_user, inventory_host = host.rsplit("@", 1)

    if not ssh_user or not inventory_host:
        raise ValueError("host must be an IP/hostname or user@IP")

    pseudo = inventory_host in {"127.0.0.1", "localhost"}
    resolved_port = ssh_port if ssh_port is not None else (VPS_SSH_PORT if pseudo else 22)
    resolved_key = ssh_key
    if resolved_key is None and pseudo:
        resolved_key = str(PRIVATE_KEY)

    return inventory_host, ssh_user, resolved_port, resolved_key


def validate_repository(repository: str) -> None:
    if repository == "file:///mnt/topics-club.git":
        return
    parsed = urlparse(repository)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or not parsed.path
        or parsed.query
        or parsed.fragment
        or any(character.isspace() for character in repository)
    ):
        raise ValueError("repository must be one HTTPS URL")


def validate_health_url(health_url: str) -> None:
    try:
        parsed = urlparse(health_url)
        port = parsed.port
    except ValueError as error:
        raise ValueError("health_url must be loopback HTTP with a valid port") from error

    if (
        parsed.scheme != "http"
        or parsed.hostname != "127.0.0.1"
        or parsed.username is not None
        or parsed.password is not None
        or port is None
        or not 1 <= port <= 65_535
        or not parsed.path.startswith("/")
        or parsed.fragment
        or any(character.isspace() for character in health_url)
    ):
        raise ValueError("health_url must be loopback HTTP with a valid port")


def pyinfra_command(
    deploy_file: str,
    *,
    host: str,
    ssh_port: int | None,
    ssh_key: str | None,
    data: dict[str, str],
) -> list[str]:
    inventory_host, ssh_user, resolved_port, resolved_key = split_host(host, ssh_port, ssh_key)
    command = [
        "uv",
        "run",
        "pyinfra",
        "--yes",
        "--ssh-user",
        ssh_user,
        "--ssh-port",
        str(resolved_port),
    ]
    if resolved_key:
        command.extend(["--ssh-key", str(Path(resolved_key).expanduser())])
    if inventory_host in {"127.0.0.1", "localhost"}:
        data = {
            **data,
            "ssh_known_hosts_file": "/dev/null",
            "ssh_strict_host_key_checking": "no",
        }
    for key, value in data.items():
        # pyinfra parses CLI data as JSON; quoting prevents date-like tags from
        # becoming floats (for example, 20260828.1).
        command.extend(["--data", f"{key}={json.dumps(value)}"])
    command.extend([inventory_host, str(PROJECT_ROOT / "tools" / "deploy" / deploy_file)])
    return command


def remote_release_tags() -> dict[str, str]:
    lines = output(["git", "ls-remote", "--tags", "origin"]).splitlines()
    direct: dict[str, str] = {}
    peeled: dict[str, str] = {}
    for line in lines:
        object_id, reference = line.split(maxsplit=1)
        if not reference.startswith("refs/tags/"):
            continue
        name = reference.removeprefix("refs/tags/")
        if name.endswith("^{}"):
            peeled[name.removesuffix("^{}")] = object_id
        else:
            direct[name] = object_id
    return {name: peeled.get(name, object_id) for name, object_id in direct.items()}


def release_tag_key(tag: str) -> tuple[int, int]:
    match = RELEASE_TAG.fullmatch(tag)
    if not match:
        raise ValueError(f"invalid release tag: {tag}")
    return int(match.group(1)), int(match.group(2))


def preserve_release_tag_arguments(arguments: list[str]) -> list[str]:
    """Prevent Fire from parsing YYYYMMDD.N tags as lossy floating-point values."""
    preserved = arguments.copy()
    for index, argument in enumerate(preserved):
        if argument == "--tag" and index + 1 < len(preserved):
            value = preserved[index + 1]
            if RELEASE_TAG.fullmatch(value):
                preserved[index + 1] = json.dumps(value)
        elif argument.startswith("--tag="):
            value = argument.removeprefix("--tag=")
            if RELEASE_TAG.fullmatch(value):
                preserved[index] = f"--tag={json.dumps(value)}"
    return preserved


def resolve_release_tag(requested: str) -> tuple[str, str]:
    tags = {tag: commit for tag, commit in remote_release_tags().items() if RELEASE_TAG.fullmatch(tag)}
    if not tags:
        raise RuntimeError("origin has no YYYYMMDD.N release tags")

    tag = max(tags, key=release_tag_key) if requested == "latest" else requested
    if not RELEASE_TAG.fullmatch(tag):
        raise ValueError("tag must be `latest` or use the YYYYMMDD.N release format")
    if tag not in tags:
        raise RuntimeError(f"release tag {tag} is not present on origin")

    remote_commit = tags[tag]
    local = subprocess.run(
        ["git", "rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}"],
        cwd=PROJECT_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    if local.returncode == 0:
        local_commit = local.stdout.strip()
    else:
        run(["git", "fetch", "origin", f"refs/tags/{tag}:refs/tags/{tag}"])
        local_commit = output(["git", "rev-parse", f"refs/tags/{tag}^{{commit}}"])

    if local_commit != remote_commit:
        raise RuntimeError(f"local and origin definitions of release tag {tag} differ")
    if not COMMIT.fullmatch(local_commit):
        raise RuntimeError(f"could not resolve {tag} to a full commit ID")
    return tag, local_commit


class VpsCommands:
    """Manage the resettable Ubuntu 26.04 pseudo-VPS."""

    def create(self) -> None:
        """Create the 1.5 GB systemd/SSH app VPS and PostgreSQL sidecar."""
        if docker_object_exists("container", VPS_CONTAINER) or docker_object_exists(
            "container", POSTGRES_CONTAINER
        ):
            raise RuntimeError(
                "pseudo-VPS containers already exist; use `bin/apptools testvps reset`"
            )

        ensure_test_key()
        public_key = PUBLIC_KEY.read_text().strip()
        run(
            [
                "docker",
                "build",
                "--file",
                str(PROJECT_ROOT / "tools" / "vps.dockerfile"),
                "--build-arg",
                f"SSH_PUBLIC_KEY={public_key}",
                "--tag",
                VPS_IMAGE,
                ".",
            ]
        )

        if not docker_object_exists("network", VPS_NETWORK):
            run(["docker", "network", "create", VPS_NETWORK])
        if not docker_object_exists("volume", POSTGRES_VOLUME):
            run(["docker", "volume", "create", POSTGRES_VOLUME])
        if not docker_object_exists("volume", DOCKER_VOLUME):
            run(["docker", "volume", "create", DOCKER_VOLUME])

        database_password = secrets.token_hex(24)
        credentials_key = secrets.token_urlsafe(32)[:43] + "="
        secret_key_base = secrets.token_urlsafe(64)
        release_cookie = secrets.token_hex(32)
        database_url = (
            "ecto://postgres:"
            f"{database_password}@{POSTGRES_CONTAINER}/topics_club_prod"
        )
        state = {
            "database_password": database_password,
            "database_url": database_url,
            "credentials_key": credentials_key,
            "secret_key_base": secret_key_base,
            "release_cookie": release_cookie,
        }
        STATE_FILE.write_text(json.dumps(state, indent=2) + "\n")
        STATE_FILE.chmod(0o600)

        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8") as environment:
            environment.write(f"POSTGRES_PASSWORD={database_password}\nPOSTGRES_DB=topics_club_prod\n")
            environment.flush()
            run(
                [
                    "docker",
                    "run",
                    "--detach",
                    "--name",
                    POSTGRES_CONTAINER,
                    "--network",
                    VPS_NETWORK,
                    "--memory",
                    "384m",
                    "--env-file",
                    environment.name,
                    "--volume",
                    f"{POSTGRES_VOLUME}:/var/lib/postgresql/data",
                    "postgres:16-alpine",
                ]
            )

        run(
            [
                "docker",
                "run",
                "--detach",
                "--name",
                VPS_CONTAINER,
                "--hostname",
                VPS_CONTAINER,
                "--network",
                VPS_NETWORK,
                "--memory",
                "1536m",
                "--memory-swap",
                "5632m",
                "--privileged",
                "--cgroupns=host",
                "--volume",
                "/sys/fs/cgroup:/sys/fs/cgroup:rw",
                "--volume",
                f"{PROJECT_ROOT / '.git'}:/mnt/topics-club.git:ro",
                "--volume",
                f"{DOCKER_VOLUME}:/var/lib/docker",
                "--tmpfs",
                "/run",
                "--tmpfs",
                "/run/lock",
                "--publish",
                f"127.0.0.1:{VPS_SSH_PORT}:22",
                "--publish",
                f"127.0.0.1:{VPS_HTTP_PORT}:4000",
                VPS_IMAGE,
            ]
        )

        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            result = subprocess.run(
                [
                    "ssh",
                    "-i",
                    str(PRIVATE_KEY),
                    "-p",
                    str(VPS_SSH_PORT),
                    "-o",
                    "StrictHostKeyChecking=no",
                    "-o",
                    "UserKnownHostsFile=/dev/null",
                    "-o",
                    "LogLevel=ERROR",
                    "-o",
                    "ConnectTimeout=2",
                    "root@127.0.0.1",
                    "true",
                ],
                check=False,
            )
            if result.returncode == 0:
                break
            time.sleep(1)
        else:
            raise RuntimeError("SSH did not become ready in the pseudo-VPS")

        write_test_environment(state)
        print(
            "Pseudo-VPS is ready: Ubuntu 26.04, 1.5 GB app limit, "
            f"SSH 127.0.0.1:{VPS_SSH_PORT}, HTTP 127.0.0.1:{VPS_HTTP_PORT}."
        )

    def destroy(self) -> None:
        """Destroy only the named pseudo-VPS containers, network, volume, and test secrets."""
        remove_exact_container(VPS_CONTAINER)
        remove_exact_container(POSTGRES_CONTAINER)
        remove_exact_volume(POSTGRES_VOLUME)
        remove_exact_volume(DOCKER_VOLUME)
        remove_exact_network(VPS_NETWORK)
        for test_state_path in (STATE_FILE, PRIVATE_KEY, PUBLIC_KEY):
            if test_state_path.exists():
                test_state_path.unlink()
        try:
            STATE_DIR.rmdir()
        except OSError:
            # Preserve any unexpected file instead of broadening deletion scope.
            pass
        print("Destroyed the resettable pseudo-VPS and its PostgreSQL/build data volumes.")

    def reset(self) -> None:
        """Destroy and recreate the pseudo-VPS from scratch."""
        self.destroy()
        self.create()

    def status(self) -> None:
        """Show container state and verify the app container memory limit."""
        if not docker_object_exists("container", VPS_CONTAINER):
            print("Pseudo-VPS is absent.")
            return
        state = output(
            [
                "docker",
                "inspect",
                "--format",
                "{{.State.Status}} {{.HostConfig.Memory}} {{.HostConfig.MemorySwap}} {{.Config.Image}}",
                VPS_CONTAINER,
            ]
        )
        status, memory, memory_swap, image = state.split(maxsplit=3)
        memory_note = (
            "1.5 GB" if int(memory) == VPS_MEMORY_BYTES else f"unexpected: {memory} bytes"
        )
        swap_note = (
            "4 GB build swap"
            if int(memory_swap) == VPS_MEMORY_SWAP_BYTES
            else f"unexpected memory+swap limit: {memory_swap} bytes"
        )
        print(f"Pseudo-VPS: {status}; memory={memory_note}; swap={swap_note}; image={image}")


class AppTools:
    """Provision and deploy TopicsClub to one SSH-accessible app host."""

    testvps = VpsCommands()

    def provision(
        self,
        host: str = "root@127.0.0.1",
        ssh_port: int | None = None,
        ssh_key: str | None = None,
        repository: str = DEFAULT_REPOSITORY,
    ) -> None:
        """Converge one Ubuntu 26.04 destination host with pyinfra."""
        validate_repository(repository)
        run(
            pyinfra_command(
                "provision.py",
                host=host,
                ssh_port=ssh_port,
                ssh_key=ssh_key,
                data={"repo_url": repository},
            )
        )

    def deploy(
        self,
        component: str = "all",
        tag: str = "latest",
        host: str = "root@127.0.0.1",
        ssh_port: int | None = None,
        ssh_key: str | None = None,
        health_url: str = "http://127.0.0.1:4000/health",
    ) -> None:
        """Deploy all roles, or explicitly deploy only gateway or engine."""
        if component not in {"all", "gateway", "engine"}:
            raise ValueError("component must be all, gateway, or engine")
        validate_health_url(health_url)
        resolved_tag, commit = resolve_release_tag(tag)
        # Gateway migrations must land while the old engine is still running.
        components = ["gateway", "engine"] if component == "all" else [component]
        for selected in components:
            run(
                pyinfra_command(
                    "deploy.py",
                    host=host,
                    ssh_port=ssh_port,
                    ssh_key=ssh_key,
                    data={
                        "component": selected,
                        "tag": resolved_tag,
                        "commit": commit,
                        "health_url": health_url,
                    },
                )
            )

    def rollback(
        self,
        component: str = "gateway",
        host: str = "root@127.0.0.1",
        ssh_port: int | None = None,
        ssh_key: str | None = None,
        health_url: str = "http://127.0.0.1:4000/health",
    ) -> None:
        """Atomically restore and health-check the prior role release."""
        if component not in {"gateway", "engine"}:
            raise ValueError("component must be gateway or engine")
        validate_health_url(health_url)
        run(
            pyinfra_command(
                "rollback.py",
                host=host,
                ssh_port=ssh_port,
                ssh_key=ssh_key,
                data={"component": component, "health_url": health_url},
            )
        )


if __name__ == "__main__":
    fire.Fire(AppTools, command=preserve_release_tag_arguments(sys.argv[1:]))
