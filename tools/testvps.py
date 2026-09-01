"""Resettable Docker environment for production-like deployment rehearsals."""

from __future__ import annotations

import base64
import json
import secrets
import subprocess
import tempfile
import time
from pathlib import Path


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
VPS_MEMORY_BYTES = 2_147_483_648
VPS_BUILD_MEMORY_SWAP_BYTES = 6_442_450_944


def base64_secret() -> str:
    """Return the standard Base64 form expected by Elixir's Base.decode64/1."""
    return base64.b64encode(secrets.token_bytes(32)).decode("ascii")


def run(
    command: list[str],
    *,
    capture: bool = False,
) -> subprocess.CompletedProcess[str]:
    kwargs: dict[str, object] = {
        "cwd": PROJECT_ROOT,
        "check": True,
        "text": True,
    }
    if capture:
        kwargs["stdout"] = subprocess.PIPE
    return subprocess.run(command, **kwargs)  # type: ignore[arg-type]


def output(command: list[str]) -> str:
    return run(command, capture=True).stdout.strip()


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
    database = "\n".join([f"DATABASE_URL={state['database_url']}", ""])
    gateway = "\n".join(
        [
            f"IRC_CREDENTIALS_KEY={state['credentials_key']}",
            f"SECRET_KEY_BASE={state['secret_key_base']}",
            "GATEWAY_HOST=localhost",
            "PORT=4000",
            "POOL_SIZE=5",
            "RELEASE_NODE=topics_club_gateway@localhost",
            f"RELEASE_COOKIE={state['release_cookie']}",
            "",
        ]
    )
    engine = "\n".join(
        [
            f"IRC_CREDENTIALS_KEY={state['credentials_key']}",
            "POOL_SIZE=5",
            "RELEASE_NODE=topics_club_engine@localhost",
            f"RELEASE_COOKIE={state['release_cookie']}",
            "TOPICS_CLUB_IRC_TRANSPORT=wirekeeper",
            "TOPICS_CLUB_WIREKEEPER_NODE=topics_club_wirekeeper@localhost",
            "",
        ]
    )
    wirekeeper = "\n".join(
        [
            "RELEASE_NODE=topics_club_wirekeeper@localhost",
            f"RELEASE_COOKIE={state['release_cookie']}",
            "",
        ]
    )

    run(
        ["docker", "exec", VPS_CONTAINER, "install", "-d", "-m", "0755", "/etc/topics-club"]
    )
    for name, contents in (
        ("db.env", database),
        ("gateway.env", gateway),
        ("engine.env", engine),
        ("wirekeeper.env", wirekeeper),
    ):
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


class VpsCommands:
    """Manage the resettable Ubuntu 26.04 pseudo-VPS."""

    def create(self) -> None:
        """Create the 2 GiB systemd/SSH app VPS and external PostgreSQL sidecar."""
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
        credentials_key = base64_secret()
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
            environment.write(
                f"POSTGRES_PASSWORD={database_password}\nPOSTGRES_DB=topics_club_prod\n"
            )
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
                "2048m",
                "--memory-swap",
                "6144m",
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
            "Pseudo-VPS is ready: Ubuntu 26.04, 2 GiB aggregate app-host limit, "
            "4 GiB build swap, external 384 MiB PostgreSQL sidecar, "
            f"SSH 127.0.0.1:{VPS_SSH_PORT}, HTTP 127.0.0.1:{VPS_HTTP_PORT}."
        )

    def destroy(self) -> None:
        """Destroy only the named pseudo-VPS containers, network, volumes, and test state."""
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
        """Show container state and verify the aggregate app-host memory limit."""
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
            "2 GiB" if int(memory) == VPS_MEMORY_BYTES else f"unexpected: {memory} bytes"
        )
        if int(memory_swap) == VPS_BUILD_MEMORY_SWAP_BYTES:
            swap_note = "4 GiB build swap enabled"
        elif int(memory_swap) == VPS_MEMORY_BYTES:
            swap_note = "runtime swap disabled"
        else:
            swap_note = f"unexpected memory+swap limit: {memory_swap} bytes"
        print(f"Pseudo-VPS: {status}; memory={memory_note}; swap={swap_note}; image={image}")

    def build_limits(self) -> None:
        """Enable the extra 4 GiB swap allowance used only while building releases."""
        self._set_memory_swap(VPS_BUILD_MEMORY_SWAP_BYTES)
        print("Pseudo-VPS build limits enabled: 2 GiB memory plus 4 GiB build swap.")

    def runtime_limits(self) -> None:
        """Enforce the 2 GiB no-swap limit used for runtime capacity measurements."""
        self._set_memory_swap(VPS_MEMORY_BYTES)
        print("Pseudo-VPS runtime limits enabled: 2 GiB aggregate memory, swap disabled.")

    def load(
        self,
        counts: str = "100,500,1000,2000,3000,4000",
        batch_size: int = 100,
        provision_concurrency: int = 10,
        steady_seconds: int = 300,
        sample_interval: int = 5,
        startup_timeout: int = 600,
        restart_engine: bool = True,
        drop_recovery: bool = True,
        cleanup: bool = True,
    ) -> None:
        """Run the split-release/Wirekeeper connection load test on the pseudo-VPS."""
        from testvps_load import run_load

        run_load(
            counts=counts,
            batch_size=batch_size,
            provision_concurrency=provision_concurrency,
            steady_seconds=steady_seconds,
            sample_interval=sample_interval,
            startup_timeout=startup_timeout,
            restart_engine=restart_engine,
            drop_recovery=drop_recovery,
            cleanup=cleanup,
        )

    def load_cleanup(
        self,
        run_id: str,
        batch_size: int = 100,
        concurrency: int = 10,
    ) -> None:
        """Lifecycle-clean one interrupted split-release load run by its run ID."""
        from testvps_load import cleanup_existing_run

        cleanup_existing_run(run_id, batch_size, concurrency)

    def acceptance(self) -> None:
        """Run the explicit split-release/local-IRC acceptance scenario."""
        from split_acceptance import run_acceptance

        run_acceptance()

    def _set_memory_swap(self, memory_swap_bytes: int) -> None:
        if not docker_object_exists("container", VPS_CONTAINER):
            raise RuntimeError("pseudo-VPS is absent; run `bin/apptools testvps create`")

        run(
            [
                "docker",
                "update",
                "--memory",
                str(VPS_MEMORY_BYTES),
                "--memory-swap",
                str(memory_swap_bytes),
                VPS_CONTAINER,
            ]
        )

        actual = output(
            [
                "docker",
                "inspect",
                "--format",
                "{{.HostConfig.Memory}} {{.HostConfig.MemorySwap}}",
                VPS_CONTAINER,
            ]
        )
        memory, memory_swap = (int(value) for value in actual.split())
        if memory != VPS_MEMORY_BYTES or memory_swap != memory_swap_bytes:
            raise RuntimeError(
                "Docker did not apply the requested pseudo-VPS memory and swap limits"
            )
