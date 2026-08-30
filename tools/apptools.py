#!/usr/bin/env python3
"""Small operator CLI for provisioning and deploying TopicsClub."""

from __future__ import annotations

import base64
import io
import json
import re
import secrets
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path
from urllib.parse import urlparse

import fire

from testvps import PRIVATE_KEY, VPS_SSH_PORT, VpsCommands


PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_REPOSITORY = "https://github.com/HashNuke/topics.club.git"
RELEASE_TAG = re.compile(r"^(\d{8})\.(\d+)$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
GITHUB_SSH_REPOSITORY = re.compile(
    r"^git@github\.com:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?$"
)
DNS_LABEL = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")


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


def onepassword_item(vault: str, item: str) -> dict[str, object]:
    try:
        document = json.loads(
            output(
                [
                    "op",
                    "item",
                    "get",
                    item,
                    "--vault",
                    vault,
                    "--format=json",
                    "--reveal",
                ]
            )
        )
    except FileNotFoundError as error:
        raise RuntimeError("1Password CLI (`op`) is not installed") from error
    except json.JSONDecodeError as error:
        raise RuntimeError("1Password CLI returned invalid item JSON") from error

    if not isinstance(document, dict):
        raise RuntimeError("1Password CLI returned an invalid item")
    return document


def onepassword_fields(document: dict[str, object]) -> dict[tuple[str, str], dict[str, object]]:
    raw_sections = document.get("sections", [])
    raw_fields = document.get("fields", [])
    if not isinstance(raw_sections, list) or not isinstance(raw_fields, list):
        raise RuntimeError("1Password item has invalid sections or fields")

    sections = {
        section.get("id"): section.get("label")
        for section in raw_sections
        if isinstance(section, dict)
        and isinstance(section.get("id"), str)
        and isinstance(section.get("label"), str)
    }
    indexed: dict[tuple[str, str], dict[str, object]] = {}
    for field in raw_fields:
        if not isinstance(field, dict) or not isinstance(field.get("label"), str):
            continue
        section = field.get("section")
        if not isinstance(section, dict):
            continue
        section_label = section.get("label") or sections.get(section.get("id"))
        if not isinstance(section_label, str):
            continue
        key = (section_label, field["label"])
        if key in indexed:
            raise RuntimeError(f"duplicate 1Password field: {section_label}.{field['label']}")
        indexed[key] = field
    return indexed


def populated(field: dict[str, object] | None) -> bool:
    if field is None:
        return False
    value = field.get("value")
    return isinstance(value, str) and bool(value.strip())


def vapid_keypair() -> tuple[str, str]:
    values: dict[str, str] = {}
    for line in output(["mix", "topics_club.gen_vapid_keys"]).splitlines():
        name, separator, value = line.strip().partition("=")
        if separator and name in {"VAPID_PUBLIC_KEY", "VAPID_PRIVATE_KEY"}:
            values[name] = value
    if not values.get("VAPID_PUBLIC_KEY") or not values.get("VAPID_PRIVATE_KEY"):
        raise RuntimeError("VAPID key generator did not return a complete keypair")
    return values["VAPID_PUBLIC_KEY"], values["VAPID_PRIVATE_KEY"]


GENERATED_ONEPASSWORD_FIELDS = {
    ("shared", "IRC_CREDENTIALS_KEY"): "password",
    ("shared", "RELEASE_COOKIE"): "password",
    ("gateway", "SECRET_KEY_BASE"): "password",
    ("gateway", "VAPID_PUBLIC_KEY"): "text",
    ("gateway", "VAPID_PRIVATE_KEY"): "password",
}

COPIED_ONEPASSWORD_FIELDS = [
    ("shared", "IRC_CREDENTIALS_KEY"),
    ("shared", "RELEASE_COOKIE"),
    ("gateway", "SECRET_KEY_BASE"),
    ("gateway", "GATEWAY_HOST"),
    ("gateway", "GOOGLE_CLIENT_ID"),
    ("gateway", "GOOGLE_CLIENT_SECRET"),
    ("gateway", "VAPID_PUBLIC_KEY"),
    ("gateway", "VAPID_PRIVATE_KEY"),
    ("gateway", "VAPID_SUBJECT"),
]


def generate_onepassword_secrets(vault: str, item: str) -> list[str]:
    document = onepassword_item(vault, item)
    fields = onepassword_fields(document)
    missing_fields = [key for key in GENERATED_ONEPASSWORD_FIELDS if key not in fields]
    if missing_fields:
        assignments = [
            f"{section}.{label}[{GENERATED_ONEPASSWORD_FIELDS[(section, label)]}]="
            for section, label in missing_fields
        ]
        run(
            ["op", "item", "edit", item, "--vault", vault, *assignments],
            quiet=True,
        )
        document = onepassword_item(vault, item)
        fields = onepassword_fields(document)

    public_field = fields.get(("gateway", "VAPID_PUBLIC_KEY"))
    private_field = fields.get(("gateway", "VAPID_PRIVATE_KEY"))
    if populated(public_field) != populated(private_field):
        raise RuntimeError(
            "VAPID_PUBLIC_KEY and VAPID_PRIVATE_KEY must both be empty or both have values"
        )

    generated: dict[tuple[str, str], str] = {}
    credentials_field = fields.get(("shared", "IRC_CREDENTIALS_KEY"))
    if not populated(credentials_field):
        generated[("shared", "IRC_CREDENTIALS_KEY")] = base64.b64encode(
            secrets.token_bytes(32)
        ).decode("ascii")

    cookie_field = fields.get(("shared", "RELEASE_COOKIE"))
    if not populated(cookie_field):
        generated[("shared", "RELEASE_COOKIE")] = secrets.token_hex(32)

    secret_key_field = fields.get(("gateway", "SECRET_KEY_BASE"))
    if not populated(secret_key_field):
        generated[("gateway", "SECRET_KEY_BASE")] = secrets.token_urlsafe(64)

    if not populated(public_field):
        public_key, private_key = vapid_keypair()
        generated[("gateway", "VAPID_PUBLIC_KEY")] = public_key
        generated[("gateway", "VAPID_PRIVATE_KEY")] = private_key

    if not generated:
        return []

    for key, value in generated.items():
        field = fields.get(key)
        if field is None:
            raise RuntimeError(f"1Password field was not created: {key[0]}.{key[1]}")
        field["value"] = value

    try:
        subprocess.run(
            ["op", "item", "edit", item, "--vault", vault],
            cwd=PROJECT_ROOT,
            check=True,
            text=True,
            input=json.dumps(document),
            stdout=subprocess.DEVNULL,
        )
    except FileNotFoundError as error:
        raise RuntimeError("1Password CLI (`op`) is not installed") from error

    return [f"{section}.{label}" for section, label in generated]


def dotenv_value(value: str, field: str) -> str:
    if any(character in value for character in "\x00\r\n"):
        raise RuntimeError(f"1Password field cannot be represented in an env file: {field}")
    if re.fullmatch(r"[A-Za-z0-9_./:@%+,=-]*", value):
        return value
    return f'"{value.replace("\\", "\\\\").replace(chr(34), "\\\"")}"'


def onepassword_dotenv(vault: str, item: str) -> str:
    fields = required_onepassword_fields(vault, item)

    lines = []
    for section, label in COPIED_ONEPASSWORD_FIELDS:
        value = fields[(section, label)]["value"]
        if not isinstance(value, str):
            raise RuntimeError(f"1Password field is not text: {section}.{label}")
        lines.append(f"{label}={dotenv_value(value, f'{section}.{label}')}")
    lines.append("ENABLE_DISCOVERY=false")
    return "\n".join(lines) + "\n"


def required_onepassword_fields(
    vault: str, item: str
) -> dict[tuple[str, str], dict[str, object]]:
    fields = onepassword_fields(onepassword_item(vault, item))
    missing = [
        f"{section}.{label}"
        for section, label in COPIED_ONEPASSWORD_FIELDS
        if not populated(fields.get((section, label)))
    ]
    if missing:
        raise RuntimeError(f"1Password fields are missing or empty: {', '.join(missing)}")
    return fields


def role_dotenv_documents(vault: str, item: str) -> dict[str, str]:
    fields = required_onepassword_fields(vault, item)

    def lines_for(keys: list[tuple[str, str]]) -> list[str]:
        lines = []
        for section, label in keys:
            value = fields[(section, label)]["value"]
            if not isinstance(value, str):
                raise RuntimeError(f"1Password field is not text: {section}.{label}")
            lines.append(f"{label}={dotenv_value(value, f'{section}.{label}')}")
        return lines

    shared = [("shared", "IRC_CREDENTIALS_KEY"), ("shared", "RELEASE_COOKIE")]
    gateway = lines_for(COPIED_ONEPASSWORD_FIELDS)
    gateway.extend(
        [
            "ENABLE_DISCOVERY=false",
            "RELEASE_NODE=topics_club_gateway@localhost",
        ]
    )
    engine = lines_for(shared)
    engine.append("RELEASE_NODE=topics_club_engine@localhost")
    return {
        "gateway.env": "\n".join(gateway) + "\n",
        "engine.env": "\n".join(engine) + "\n",
    }


def environment_archive(documents: dict[str, str]) -> bytes:
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode="w") as tar:
        for name, contents in documents.items():
            encoded = contents.encode("utf-8")
            info = tarfile.TarInfo(name)
            info.mode = 0o600
            info.size = len(encoded)
            tar.addfile(info, io.BytesIO(encoded))
    return archive.getvalue()


INSTALL_ENV_COMMAND = r"""
set -eu
umask 077
install -d -m 0755 /etc/topics-club
stage=$(mktemp -d /etc/topics-club/.env-install.XXXXXX)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
tar -xf - -C "$stage"
for role in gateway engine; do
  install -m 0600 "$stage/$role.env" "/etc/topics-club/$role.env.new"
  if id "topics-club-$role" >/dev/null 2>&1; then
    chown "topics-club-$role:topics-club-$role" "/etc/topics-club/$role.env.new"
  else
    chown root:root "/etc/topics-club/$role.env.new"
  fi
done
deploy_key=/srv/topics-club/build-home/.ssh/id_ed25519
deploy_public_key="$deploy_key.pub"
deploy_key_comment=$(cat "$stage/deploy-key-comment")
install -d -m 0755 /srv/topics-club
install -d -m 0700 /srv/topics-club/build-home
install -d -m 0700 /srv/topics-club/build-home/.ssh
if [ -e "$deploy_key" ] && [ ! -f "$deploy_key" ]; then
  echo 'deploy private-key path is not a regular file' >&2
  exit 1
fi
if [ -e "$deploy_public_key" ] && [ ! -f "$deploy_public_key" ]; then
  echo 'deploy public-key path is not a regular file' >&2
  exit 1
fi
if [ ! -e "$deploy_key" ] && [ -e "$deploy_public_key" ]; then
  echo 'deploy public key exists without its private key' >&2
  exit 1
fi
if [ ! -e "$deploy_key" ]; then
  ssh-keygen -q -t ed25519 -N '' -C "$deploy_key_comment" -f "$deploy_key"
elif [ ! -e "$deploy_public_key" ]; then
  ssh-keygen -y -f "$deploy_key" | sed "s/$/ $deploy_key_comment/" > "$deploy_public_key"
fi
chmod 0600 "$deploy_key"
chmod 0644 "$deploy_public_key"
if id topics-club-deploy >/dev/null 2>&1; then
  chown topics-club-deploy:topics-club-deploy /srv/topics-club/build-home/.ssh
  chown topics-club-deploy:topics-club-deploy \
    "$deploy_key" "$deploy_public_key"
else
  chown root:root "$deploy_key" "$deploy_public_key"
fi
mv /etc/topics-club/gateway.env.new /etc/topics-club/gateway.env
mv /etc/topics-club/engine.env.new /etc/topics-club/engine.env
printf 'DEPLOY_PUBLIC_KEY=%s\n' "$(cat "$deploy_public_key")"
""".strip()


def install_onepassword_secrets(
    vault: str,
    item: str,
    host: str,
    ssh_port: int | None,
    ssh_key: str | None,
) -> str:
    documents = role_dotenv_documents(vault, item)
    documents["deploy-key-comment"] = f"{item}-deploy-key\n"
    inventory_host, ssh_user, resolved_port, resolved_key = split_host(
        host, ssh_port, ssh_key
    )
    command = [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-p",
        str(resolved_port),
    ]
    if resolved_key:
        command.extend(["-i", str(Path(resolved_key).expanduser())])
    command.extend([f"{ssh_user}@{inventory_host}", INSTALL_ENV_COMMAND])
    try:
        completed = subprocess.run(
            command,
            cwd=PROJECT_ROOT,
            check=True,
            input=environment_archive(documents),
            stdout=subprocess.PIPE,
        )
    except FileNotFoundError as error:
        raise RuntimeError("SSH client (`ssh`) is not installed") from error

    output_lines = completed.stdout.decode("utf-8").splitlines()
    public_keys = [
        line.removeprefix("DEPLOY_PUBLIC_KEY=")
        for line in output_lines
        if line.startswith("DEPLOY_PUBLIC_KEY=")
    ]
    if len(public_keys) != 1 or not public_keys[0].startswith("ssh-ed25519 "):
        raise RuntimeError("destination did not return one Ed25519 deploy public key")
    return public_keys[0]


def clipboard_command() -> list[str]:
    candidates = [
        ["pbcopy"],
        ["wl-copy"],
        ["xclip", "-selection", "clipboard"],
        ["xsel", "--clipboard", "--input"],
    ]
    for command in candidates:
        if shutil.which(command[0]):
            return command
    raise RuntimeError("no clipboard command found; install pbcopy, wl-copy, xclip, or xsel")


def copy_onepassword_secrets(vault: str, item: str) -> None:
    contents = onepassword_dotenv(vault, item)
    subprocess.run(
        clipboard_command(),
        check=True,
        text=True,
        input=contents,
        stdout=subprocess.DEVNULL,
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
    if GITHUB_SSH_REPOSITORY.fullmatch(repository):
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
        raise ValueError(
            "repository must be one HTTPS URL or a git@github.com:OWNER/REPO.git URL"
        )


def validate_gateway_host(gateway_host: str) -> None:
    if not gateway_host:
        return
    labels = gateway_host.split(".")
    if (
        len(gateway_host) > 253
        or len(labels) < 2
        or gateway_host != gateway_host.lower()
        or any(DNS_LABEL.fullmatch(label) is None for label in labels)
    ):
        raise ValueError("gateway_host must be one lower-case DNS hostname")


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

    def copy_secrets(
        self,
        env: str,
        vault: str = "app-secrets",
    ) -> None:
        """Copy a complete TopicsClub dotenv document from 1Password."""
        if env not in {"dev", "prod"}:
            raise ValueError("env must be dev or prod")
        item = f"topics-club-{env}"
        copy_onepassword_secrets(vault, item)
        print(f"Copied secrets from {vault}/{item} to the clipboard.")

    def create_secrets(
        self,
        env: str,
        vault: str = "app-secrets",
    ) -> None:
        """Generate only empty TopicsClub cryptographic fields in 1Password."""
        if env not in {"dev", "prod"}:
            raise ValueError("env must be dev or prod")
        item = f"topics-club-{env}"
        generated = generate_onepassword_secrets(vault, item)
        if generated:
            print(f"Generated {', '.join(generated)} in {vault}/{item}.")
        else:
            print(f"All generated fields in {vault}/{item} already have values; no changes made.")

    def provision_db(
        self,
        host: str = "root@127.0.0.1",
        ssh_port: int | None = None,
        ssh_key: str | None = None,
    ) -> None:
        """Provision PostgreSQL and generate /etc/topics-club/db.env remotely."""
        run(
            pyinfra_command(
                "database.py",
                host=host,
                ssh_port=ssh_port,
                ssh_key=ssh_key,
                data={},
            )
        )

    def provision(
        self,
        host: str = "root@127.0.0.1",
        ssh_port: int | None = None,
        ssh_key: str | None = None,
        repository: str = DEFAULT_REPOSITORY,
        gateway_host: str = "",
    ) -> None:
        """Converge one Ubuntu 26.04 destination host with pyinfra."""
        validate_repository(repository)
        validate_gateway_host(gateway_host)
        resolved_ssh_port = split_host(host, ssh_port, ssh_key)[2]
        run(
            pyinfra_command(
                "provision.py",
                host=host,
                ssh_port=ssh_port,
                ssh_key=ssh_key,
                data={
                    "repo_url": repository,
                    "gateway_host": gateway_host,
                    "ssh_port": str(resolved_ssh_port),
                },
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
        env: str = "prod",
        vault: str = "app-secrets",
    ) -> None:
        """Deploy roles, or install role env files and a destination deploy key."""
        if component == "install-secrets":
            if env not in {"dev", "prod"}:
                raise ValueError("env must be dev or prod")
            item = f"topics-club-{env}"
            public_key = install_onepassword_secrets(
                vault, item, host, ssh_port, ssh_key
            )
            print(f"Installed secrets from {vault}/{item} on {host}.")
            print("Add this read-only deploy key to the GitHub repository:")
            print(public_key)
            return
        if component not in {"all", "gateway", "engine"}:
            raise ValueError(
                "component must be all, gateway, engine, or install-secrets"
            )
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
