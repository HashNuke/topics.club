#!/usr/bin/env python3
"""Run isolated TopicsClub engine load tests with Docker Compose."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import time
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[2]
COMPOSE_FILE = PROJECT_ROOT / "docker-compose.load-test.yml"
SEED_FILE = Path(__file__).with_name("seed.sql")
DIRECT_THREADS_SEED_FILE = Path(__file__).with_name("seed_direct_threads.sql")
RESULTS_DIR = PROJECT_ROOT / ".load-tests"
PROJECT_NAME = "topics-club-loadtest"
DEFAULT_COUNTS = [100, 250, 500, 1_000, 2_000, 4_000, 8_000]


def run(
    command: list[str],
    *,
    env: dict[str, str] | None = None,
    input_text: str | None = None,
    capture: bool = False,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)

    return subprocess.run(
        command,
        cwd=PROJECT_ROOT,
        env=merged_env,
        input=input_text,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        text=True,
        check=check,
    )


def output(command: list[str], *, env: dict[str, str] | None = None) -> str:
    return run(command, env=env, capture=True).stdout.strip()


def compose(arguments: list[str], *, env: dict[str, str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
    return run(
        [
            "docker",
            "compose",
            "--project-name",
            PROJECT_NAME,
            "--file",
            str(COMPOSE_FILE),
            *arguments,
        ],
        env=env,
        **kwargs,
    )


def build_images() -> dict[str, str]:
    revision = output(["git", "rev-parse", "HEAD"])
    source_digest = source_tree_digest()
    tag = f"{revision[:12]}-{source_digest[:12]}"
    builder = f"topics-club-load-builder:{tag}"
    combined = f"topics-club-load-combined:{tag}"
    engine = f"topics-club-load-engine:{tag}"

    run(
        [
            "docker",
            "build",
            "--target",
            "builder",
            "--tag",
            builder,
            "--build-arg",
            f"SOURCE_REVISION={revision}",
            ".",
        ]
    )
    run(
        [
            "docker",
            "build",
            "--tag",
            combined,
            "--build-arg",
            f"SOURCE_REVISION={revision}",
            ".",
        ]
    )
    run(
        [
            "docker",
            "build",
            "--file",
            "tools/load_test/engine.dockerfile",
            "--tag",
            engine,
            "--build-arg",
            f"BUILDER_IMAGE={builder}",
            "--build-arg",
            f"SOURCE_REVISION={revision}",
            ".",
        ]
    )

    return {
        "revision": revision,
        "source_digest": source_digest,
        "builder": builder,
        "combined": combined,
        "engine": engine,
    }


def source_tree_digest() -> str:
    digest = hashlib.sha256()
    paths = output(["git", "ls-files", "--cached", "--others", "--exclude-standard"]).splitlines()
    for relative in sorted(paths):
        path = PROJECT_ROOT / relative
        if path.is_file():
            digest.update(relative.encode())
            digest.update(b"\0")
            digest.update(path.read_bytes())
            digest.update(b"\0")
    return digest.hexdigest()


def scenario_env(images: dict[str, str], args: argparse.Namespace) -> dict[str, str]:
    return {
        "LOAD_COMBINED_IMAGE": images["combined"],
        "LOAD_ENGINE_IMAGE": images["engine"],
        "LOAD_ENGINE_MEMORY": args.engine_memory,
        "LOAD_ENGINE_CPUS": str(args.engine_cpus),
        "LOAD_POOL_SIZE": str(args.pool_size),
        "LOAD_DB_QUEUE_TARGET": str(args.db_queue_target),
        "LOAD_DB_QUEUE_INTERVAL": str(args.db_queue_interval),
    }


def reset_stack(
    env: dict[str, str], connections: int, *, direct_threads: bool = False
) -> float:
    compose(["down", "--volumes", "--remove-orphans"], env=env, check=False)
    compose(["up", "--detach", "postgres", "irc"], env=env)
    wait_healthy(env, "postgres", 90)
    wait_healthy(env, "irc", 90)
    compose(
        ["--profile", "tools", "run", "--rm", "migrator"],
        env=env,
        capture=True,
    )

    compose(
        [
            "exec",
            "--no-TTY",
            "postgres",
            "psql",
            "--username",
            "postgres",
            "--dbname",
            "topics_club_load",
            "--variable",
            f"load_connections={connections}",
        ],
        env=env,
        input_text=SEED_FILE.read_text(),
    )

    if direct_threads:
        compose(
            [
                "exec",
                "--no-TTY",
                "postgres",
                "psql",
                "--username",
                "postgres",
                "--dbname",
                "topics_club_load",
            ],
            env=env,
            input_text=DIRECT_THREADS_SEED_FILE.read_text(),
        )

    started = time.monotonic()
    compose(["up", "--detach", "engine"], env=env)
    return started


def wait_healthy(env: dict[str, str], service: str, timeout: int) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        container_id = compose(["ps", "--quiet", service], env=env, capture=True).stdout.strip()
        if container_id:
            status = output(
                ["docker", "inspect", "--format", "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}", container_id]
            )
            if status == "healthy":
                return
            if status in {"exited", "dead", "unhealthy"}:
                raise RuntimeError(f"{service} entered {status}")
        time.sleep(1)
    raise TimeoutError(f"{service} did not become healthy within {timeout}s")


def irc_control(env: dict[str, str], command: str) -> dict[str, int] | str:
    shell = (
        "exec 3<>/dev/tcp/127.0.0.1/8080\n"
        f"printf '%s\\n' {shell_quote(command)} >&3\n"
        "read -r reply <&3\n"
        "printf '%s\\n' \"$reply\""
    )
    response = compose(
        ["exec", "--no-TTY", "irc", "bash", "-c", shell],
        env=env,
        capture=True,
    ).stdout.strip()
    fields = parse_fields(response)
    return fields if fields else response


def shell_quote(value: str) -> str:
    return "'" + value.replace("'", "'\\''") + "'"


def parse_fields(value: str) -> dict[str, int]:
    fields: dict[str, int] = {}
    for item in value.split():
        if "=" not in item:
            return {}
        key, raw = item.split("=", 1)
        if not re.fullmatch(r"-?\d+", raw):
            return {}
        fields[key] = int(raw)
    return fields


def database_stats(env: dict[str, str]) -> dict[str, int]:
    sql = """
SELECT json_build_object(
  'connections', (SELECT count(*) FROM server_connections),
  'connected', (SELECT count(*) FROM server_connections WHERE status = 'connected'),
  'messages', (SELECT count(*) FROM messages),
  'inbound_messages', (
    SELECT count(*) FROM messages WHERE body LIKE 'synthetic-load-message-%'
  ),
  'outbound_messages', (
    SELECT count(*) FROM messages WHERE body = 'synthetic-outbound-message'
  )
)::text;
"""
    value = compose(
        [
            "exec",
            "--no-TTY",
            "postgres",
            "psql",
            "--tuples-only",
            "--no-align",
            "--username",
            "postgres",
            "--dbname",
            "topics_club_load",
        ],
        env=env,
        input_text=sql,
        capture=True,
    ).stdout.strip()
    return json.loads(value)


def engine_diagnostics(env: dict[str, str]) -> dict[str, Any]:
    expression = (
        "data = %{diagnostics: TopicsClub.Engine.Diagnostics.snapshot(), "
        "memory: Map.new(:erlang.memory()), process_count: :erlang.system_info(:process_count), "
        "port_count: :erlang.system_info(:port_count), run_queue: :erlang.statistics(:run_queue)}; "
        "IO.puts(\"LOAD_JSON=\" <> Jason.encode!(data))"
    )
    result = compose(
        ["exec", "--no-TTY", "engine", "/app/bin/topics_club_engine", "rpc", expression],
        env=env,
        capture=True,
        check=False,
    )
    match = re.search(r"LOAD_JSON=(\{.*\})", result.stdout)
    if not match:
        return {"error": (result.stderr or result.stdout).strip(), "returncode": result.returncode}
    return json.loads(match.group(1))


def docker_sample(env: dict[str, str]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for service in ("engine", "postgres", "irc"):
        container_id = compose(["ps", "--quiet", service], env=env, capture=True).stdout.strip()
        if not container_id:
            result[service] = {"state": "absent"}
            continue
        raw = output(["docker", "stats", "--no-stream", "--format", "{{json .}}", container_id])
        result[service] = json.loads(raw)
    return result


def wait_for_connections(
    env: dict[str, str],
    target: int,
    started: float,
    timeout: int,
    *,
    minimum_accepted: int | None = None,
) -> tuple[bool, list[dict[str, Any]]]:
    samples: list[dict[str, Any]] = []
    deadline = time.monotonic() + timeout
    next_sample = 0.0
    minimum_accepted = minimum_accepted or target

    while time.monotonic() < deadline:
        now = time.monotonic()
        irc = irc_control(env, "STATS")
        database = database_stats(env)
        if now >= next_sample:
            sample = {
                "elapsed_seconds": round(now - started, 3),
                "irc": irc,
                "database": database,
                "containers": docker_sample(env),
            }
            samples.append(sample)
            print(
                f"  {sample['elapsed_seconds']:7.1f}s "
                f"registered={field(irc, 'registered')}/{target} "
                f"active={field(irc, 'active')} "
                f"accepted={field(irc, 'accepted_total')}/{minimum_accepted}",
                flush=True,
            )
            next_sample = now + 10

        if (
            field(irc, "registered") >= target
            and field(irc, "active") >= target
            and field(irc, "accepted_total") >= minimum_accepted
        ):
            return True, samples

        engine_id = compose(["ps", "--quiet", "engine"], env=env, capture=True).stdout.strip()
        if not engine_id:
            return False, samples
        state = output(["docker", "inspect", "--format", "{{.State.Status}}", engine_id])
        if state != "running":
            return False, samples
        time.sleep(1)

    return False, samples


def field(stats: dict[str, int] | str, key: str) -> int:
    return stats.get(key, 0) if isinstance(stats, dict) else 0


def steady_samples(env: dict[str, str], seconds: int) -> list[dict[str, Any]]:
    samples = []
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        samples.append(
            {
                "at_seconds": round(seconds - max(0, deadline - time.monotonic()), 3),
                "irc": irc_control(env, "STATS"),
                "database": database_stats(env),
                "containers": docker_sample(env),
            }
        )
        time.sleep(min(5, max(0, deadline - time.monotonic())))
    return samples


def run_capacity_scenario(
    env: dict[str, str], args: argparse.Namespace, connections: int
) -> dict[str, Any]:
    print(f"\n=== capacity: {connections} connections ===", flush=True)
    started = reset_stack(env, connections)
    success, startup_samples = wait_for_connections(
        env, connections, started, args.startup_timeout
    )
    startup_seconds = round(time.monotonic() - started, 3)
    steady = steady_samples(env, args.steady_seconds) if success else []
    success = success and all(
        field(sample["irc"], "registered") >= connections
        and field(sample["irc"], "active") >= connections
        for sample in steady
    )

    result: dict[str, Any] = {
        "connections": connections,
        "success": success,
        "startup_seconds": startup_seconds,
        "startup_samples": startup_samples,
        "irc": irc_control(env, "STATS"),
        "database": database_stats(env),
        "engine": engine_diagnostics(env),
        "steady_samples": steady,
        "engine_logs": compose(
            ["logs", "--no-color", "--tail", "200", "engine"],
            env=env,
            capture=True,
            check=False,
        ).stdout,
    }
    return result


def run_workload_scenario(
    env: dict[str, str], args: argparse.Namespace, connections: int
) -> dict[str, Any]:
    print(f"\n=== workload: {connections} connections ===", flush=True)
    started = reset_stack(env, connections, direct_threads=True)
    success, startup_samples = wait_for_connections(
        env, connections, started, args.startup_timeout
    )
    result: dict[str, Any] = {
        "connections": connections,
        "success": success,
        "startup_seconds": round(time.monotonic() - started, 3),
        "startup_samples": startup_samples,
    }
    if not success:
        return result

    outbound_started = time.monotonic()
    outbound = run_outbound_messages(env, args.outbound_concurrency)
    outbound_irc = irc_control(env, "STATS")
    result.update(
        {
            "outbound": outbound,
            "outbound_seconds": round(time.monotonic() - outbound_started, 3),
            "outbound_irc": outbound_irc,
            "outbound_success": outbound.get("sent") == connections
            and field(outbound_irc, "privmsgs_received") >= connections,
        }
    )

    baseline_stats = database_stats(env)
    baseline = baseline_stats["messages"]
    baseline_inbound = baseline_stats["inbound_messages"]
    burst_started = time.monotonic()
    burst = irc_control(
        env,
        "BURST_PACED "
        f"{args.messages_per_connection} {args.inbound_batch_size} {args.inbound_pause_ms}",
    )
    expected = baseline + connections * args.messages_per_connection
    expected_inbound = baseline_inbound + connections * args.messages_per_connection
    deadline = time.monotonic() + args.message_timeout
    while (
        time.monotonic() < deadline
        and database_stats(env)["inbound_messages"] < expected_inbound
    ):
        time.sleep(0.25)
    message_stats = database_stats(env)

    result.update(
        {
            "baseline_messages": baseline,
            "baseline_inbound_messages": baseline_inbound,
            "burst": burst,
            "expected_messages": expected,
            "expected_inbound_messages": expected_inbound,
            "message_ingestion_seconds": round(time.monotonic() - burst_started, 3),
            "message_stats": message_stats,
            "message_ingestion_success": (
                message_stats["messages"] >= expected
                and message_stats["inbound_messages"] >= expected_inbound
            ),
            "after_burst_engine": engine_diagnostics(env),
            "after_burst_containers": docker_sample(env),
        }
    )

    restart_started = time.monotonic()
    compose(["restart", "engine"], env=env)
    restart_success, restart_samples = wait_for_connections(
        env,
        connections,
        restart_started,
        args.startup_timeout,
        minimum_accepted=connections * 2,
    )
    result.update(
        {
            "restart_success": restart_success,
            "restart_seconds": round(time.monotonic() - restart_started, 3),
            "restart_samples": restart_samples,
            "after_restart_engine": engine_diagnostics(env),
        }
    )

    drop = irc_control(env, "DROP")
    drop_started = time.monotonic()
    drop_recovery_success, drop_recovery_samples = wait_for_connections(
        env,
        connections,
        drop_started,
        args.drop_recovery_timeout,
        minimum_accepted=connections * 3,
    )
    result.update(
        {
            "network_drop": drop,
            "drop_recovery_success": drop_recovery_success,
            "drop_recovery_seconds": round(time.monotonic() - drop_started, 3),
            "drop_recovery_samples": drop_recovery_samples,
            "after_drop_recovery_irc": irc_control(env, "STATS"),
            "after_drop_recovery_database": database_stats(env),
            "after_drop_recovery_engine": engine_diagnostics(env),
            "engine_logs": compose(
                ["logs", "--no-color", "--tail", "400", "engine"],
                env=env,
                capture=True,
                check=False,
            ).stdout,
        }
    )
    result["success"] = all(
        [
            result["success"],
            result["outbound_success"],
            result["message_ingestion_success"],
            result["restart_success"],
            result["drop_recovery_success"],
        ]
    )
    return result


def run_outbound_messages(env: dict[str, str], max_concurrency: int) -> dict[str, Any]:
    expression = (
        "threads = TopicsClub.Repo.all(TopicsClub.Chat.DirectMessageThread); "
        "started = System.monotonic_time(); "
        "counts = Task.async_stream(threads, fn thread -> "
        "connection = TopicsClub.Repo.get!(TopicsClub.Chat.ServerConnection, thread.server_connection_id); "
        "case TopicsClub.Irc.Session.privmsg_thread(connection, thread.id, \"synthetic-outbound-message\") do "
        "{:ok, _sent} -> :sent; error -> {:error, inspect(error)} end end, "
        f"max_concurrency: {max_concurrency}, ordered: false, timeout: :infinity) "
        "|> Enum.reduce(%{sent: 0, errors: 0}, fn "
        "{:ok, :sent}, counts -> Map.update!(counts, :sent, &(&1 + 1)); "
        "_error, counts -> Map.update!(counts, :errors, &(&1 + 1)) end); "
        "elapsed_ms = System.monotonic_time() - started "
        "|> System.convert_time_unit(:native, :millisecond); "
        "IO.puts(\"LOAD_JSON=\" <> Jason.encode!(Map.put(counts, :elapsed_ms, elapsed_ms)))"
    )
    result = compose(
        ["exec", "--no-TTY", "engine", "/app/bin/topics_club_engine", "rpc", expression],
        env=env,
        capture=True,
        check=False,
    )
    match = re.search(r"LOAD_JSON=(\{.*\})", result.stdout)
    if not match:
        return {"error": (result.stderr or result.stdout).strip(), "returncode": result.returncode}
    return json.loads(match.group(1))


def environment_record(images: dict[str, str], args: argparse.Namespace) -> dict[str, Any]:
    return {
        "timestamp_utc": dt.datetime.now(dt.UTC).isoformat(),
        "images": images,
        "engine_memory": args.engine_memory,
        "engine_cpus": args.engine_cpus,
        "pool_size": args.pool_size,
        "db_queue_target": args.db_queue_target,
        "db_queue_interval": args.db_queue_interval,
        "docker_version": output(["docker", "version", "--format", "{{.Server.Version}}"]),
        "docker_info": output(
            ["docker", "info", "--format", "CPUs={{.NCPU}} Memory={{.MemTotal}} Driver={{.Driver}}"]
        ),
        "host_kernel": output(["uname", "-srmo"]),
    }


def write_results(payload: dict[str, Any], label: str) -> Path:
    RESULTS_DIR.mkdir(exist_ok=True)
    timestamp = dt.datetime.now(dt.UTC).strftime("%Y%m%dT%H%M%SZ")
    path = RESULTS_DIR / f"{timestamp}-{label}.json"
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    print(f"Raw results: {path.relative_to(PROJECT_ROOT)}", flush=True)
    return path


def parse_counts(value: str) -> list[int]:
    counts = [int(item.replace("_", "")) for item in value.split(",")]
    if not counts or any(count <= 0 for count in counts):
        raise argparse.ArgumentTypeError("counts must be positive comma-separated integers")
    return counts


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--engine-memory", default="1536m")
    result.add_argument("--engine-cpus", type=float, default=2.0)
    result.add_argument("--pool-size", type=int, default=10)
    result.add_argument("--db-queue-target", type=int, default=5_000)
    result.add_argument("--db-queue-interval", type=int, default=5_000)
    result.add_argument("--startup-timeout", type=int, default=300)
    result.add_argument("--steady-seconds", type=int, default=20)
    result.add_argument("--skip-build", action="store_true")

    commands = result.add_subparsers(dest="command", required=True)
    capacity = commands.add_parser("capacity")
    capacity.add_argument("--counts", type=parse_counts, default=DEFAULT_COUNTS)

    workload = commands.add_parser("workload")
    workload.add_argument("--connections", type=int, required=True)
    workload.add_argument("--messages-per-connection", type=int, default=1)
    workload.add_argument("--message-timeout", type=int, default=300)
    workload.add_argument("--drop-recovery-timeout", type=int, default=120)
    workload.add_argument("--outbound-concurrency", type=int, default=50)
    workload.add_argument("--inbound-batch-size", type=int, default=10)
    workload.add_argument("--inbound-pause-ms", type=int, default=10)
    return result


def main() -> None:
    args = parser().parse_args()
    images_file = RESULTS_DIR / "images.json"

    if args.skip_build:
        images = json.loads(images_file.read_text())
    else:
        images = build_images()
        RESULTS_DIR.mkdir(exist_ok=True)
        images_file.write_text(json.dumps(images, indent=2) + "\n")

    env = scenario_env(images, args)
    payload = {"environment": environment_record(images, args), "scenarios": []}

    try:
        if args.command == "capacity":
            for connections in args.counts:
                scenario = run_capacity_scenario(env, args, connections)
                payload["scenarios"].append(scenario)
                write_results(payload, "capacity-partial")
                if not scenario["success"]:
                    break
            write_results(payload, "capacity")
        else:
            payload["scenarios"].append(
                run_workload_scenario(env, args, args.connections)
            )
            write_results(payload, "workload")
    finally:
        compose(["down", "--volumes", "--remove-orphans"], env=env, check=False)


if __name__ == "__main__":
    main()
