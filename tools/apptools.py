#!/usr/bin/env python3
"""Small operator CLI for provisioning and deploying TopicsClub."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse

import fire

from testvps import PRIVATE_KEY, VPS_SSH_PORT, VpsCommands


PROJECT_ROOT = Path(__file__).resolve().parent.parent
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
