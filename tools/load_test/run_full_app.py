#!/usr/bin/env python3
"""Run combined-release connection and authenticated HTTP load tests."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import time
from typing import Any

import run as engine_harness


RESULTS_DIR = engine_harness.RESULTS_DIR


def reset_stack(env: dict[str, str], connections: int) -> float:
    engine_harness.compose(["down", "--volumes", "--remove-orphans"], env=env, check=False)
    engine_harness.compose(["up", "--detach", "postgres", "irc"], env=env)
    engine_harness.wait_healthy(env, "postgres", 90)
    engine_harness.wait_healthy(env, "irc", 90)
    engine_harness.compose(
        ["--profile", "tools", "run", "--rm", "migrator"],
        env=env,
        capture=True,
    )
    engine_harness.compose(
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
        input_text=engine_harness.SEED_FILE.read_text(),
    )
    started = time.monotonic()
    engine_harness.compose(["up", "--detach", "app"], env=env)
    engine_harness.wait_healthy(env, "app", 120)
    return started


def app_rpc(env: dict[str, str], expression: str) -> str:
    result = engine_harness.compose(
        ["exec", "--no-TTY", "app", "/app/bin/topics_club", "rpc", expression],
        env=env,
        capture=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError((result.stderr or result.stdout).strip())
    return result.stdout


def diagnostics(env: dict[str, str]) -> dict[str, Any]:
    expression = (
        "data = %{diagnostics: TopicsClub.Engine.Diagnostics.snapshot(), "
        "memory: Map.new(:erlang.memory()), process_count: :erlang.system_info(:process_count), "
        "port_count: :erlang.system_info(:port_count), run_queue: :erlang.statistics(:run_queue)}; "
        'IO.puts("LOAD_JSON=" <> Jason.encode!(data))'
    )
    match = re.search(r"LOAD_JSON=(\{.*\})", app_rpc(env, expression))
    if not match:
        raise RuntimeError("combined release diagnostics did not return JSON")
    return json.loads(match.group(1))


def sample_container(env: dict[str, str], service: str) -> dict[str, Any]:
    container_id = engine_harness.compose(
        ["ps", "--quiet", service], env=env, capture=True
    ).stdout.strip()
    raw = engine_harness.output(
        ["docker", "stats", "--no-stream", "--format", "{{json .}}", container_id]
    )
    return json.loads(raw)


def wait_for_connections(
    env: dict[str, str], target: int, started: float, timeout: int
) -> tuple[bool, list[dict[str, Any]]]:
    deadline = time.monotonic() + timeout
    samples: list[dict[str, Any]] = []
    next_sample = 0.0
    while time.monotonic() < deadline:
        now = time.monotonic()
        irc = engine_harness.irc_control(env, "STATS")
        if now >= next_sample:
            sample = {
                "elapsed_seconds": round(now - started, 3),
                "irc": irc,
                "app": sample_container(env, "app"),
                "postgres": sample_container(env, "postgres"),
            }
            samples.append(sample)
            print(
                f"  {sample['elapsed_seconds']:7.1f}s "
                f"registered={engine_harness.field(irc, 'registered')}/{target}",
                flush=True,
            )
            next_sample = now + 10

        if (
            engine_harness.field(irc, "registered") >= target
            and engine_harness.field(irc, "active") >= target
        ):
            return True, samples

        app_id = engine_harness.compose(
            ["ps", "--quiet", "app"], env=env, capture=True
        ).stdout.strip()
        if not app_id:
            return False, samples
        time.sleep(1)
    return False, samples


def magic_token(env: dict[str, str]) -> str:
    expression = (
        "user = TopicsClub.Repo.get!(TopicsClub.Accounts.User, 1); "
        "{encoded, record} = TopicsClub.Accounts.UserToken.build_email_token(user, \"login\"); "
        "TopicsClub.Repo.insert!(record); IO.puts(\"LOAD_TOKEN=\" <> encoded)"
    )
    match = re.search(r"LOAD_TOKEN=([^\s]+)", app_rpc(env, expression))
    if not match:
        raise RuntimeError("could not issue local benchmark login token")
    return match.group(1)


def http_benchmark(env: dict[str, str], requests: int, concurrency: int) -> dict[str, Any]:
    run_env = {
        **env,
        "LOAD_MAGIC_TOKEN": magic_token(env),
        "LOAD_HTTP_REQUESTS": str(requests),
        "LOAD_HTTP_CONCURRENCY": str(concurrency),
    }
    result = engine_harness.compose(
        ["--profile", "tools", "run", "--rm", "client"],
        env=run_env,
        capture=True,
        check=False,
    )
    match = re.search(r"LOAD_HTTP_JSON=(\{.*\})", result.stdout)
    if not match:
        raise RuntimeError(f"HTTP client did not return results: {result.stdout}{result.stderr}")
    return json.loads(match.group(1))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--counts", type=engine_harness.parse_counts, default=[1_000, 4_000, 8_000])
    parser.add_argument("--startup-timeout", type=int, default=300)
    parser.add_argument("--steady-seconds", type=int, default=10)
    parser.add_argument("--http-requests", type=int, default=200)
    parser.add_argument("--http-concurrency", type=int, default=20)
    parser.add_argument("--app-memory", default="1536m")
    parser.add_argument("--app-cpus", type=float, default=2.0)
    parser.add_argument("--pool-size", type=int, default=10)
    parser.add_argument("--db-queue-target", type=int, default=5_000)
    parser.add_argument("--db-queue-interval", type=int, default=5_000)
    args = parser.parse_args()

    images = json.loads((RESULTS_DIR / "images.json").read_text())
    env = {
        "LOAD_COMBINED_IMAGE": images["combined"],
        "LOAD_ENGINE_IMAGE": images["engine"],
        "LOAD_APP_MEMORY": args.app_memory,
        "LOAD_APP_CPUS": str(args.app_cpus),
        "LOAD_POOL_SIZE": str(args.pool_size),
        "LOAD_DB_QUEUE_TARGET": str(args.db_queue_target),
        "LOAD_DB_QUEUE_INTERVAL": str(args.db_queue_interval),
    }
    payload: dict[str, Any] = {
        "environment": {
            "timestamp_utc": dt.datetime.now(dt.UTC).isoformat(),
            "images": images,
            "app_memory": args.app_memory,
            "app_cpus": args.app_cpus,
            "pool_size": args.pool_size,
            "db_queue_target": args.db_queue_target,
            "db_queue_interval": args.db_queue_interval,
            "docker_info": engine_harness.output(
                ["docker", "info", "--format", "CPUs={{.NCPU}} Memory={{.MemTotal}} Driver={{.Driver}}"]
            ),
        },
        "scenarios": [],
    }

    try:
        for count in args.counts:
            print(f"\n=== full app: {count} connections ===", flush=True)
            started = reset_stack(env, count)
            success, startup_samples = wait_for_connections(
                env, count, started, args.startup_timeout
            )
            scenario: dict[str, Any] = {
                "connections": count,
                "success": success,
                "startup_seconds": round(time.monotonic() - started, 3),
                "startup_samples": startup_samples,
                "irc": engine_harness.irc_control(env, "STATS"),
                "database": engine_harness.database_stats(env),
            }
            if success:
                time.sleep(args.steady_seconds)
                http = http_benchmark(env, args.http_requests, args.http_concurrency)
                post_http_irc = engine_harness.irc_control(env, "STATS")
                scenario.update(
                    {
                        "diagnostics": diagnostics(env),
                        "containers": {
                            service: sample_container(env, service)
                            for service in ("app", "postgres", "irc")
                        },
                        "http": http,
                        "post_http_irc": post_http_irc,
                    }
                )
                scenario["success"] = (
                    scenario["diagnostics"]["diagnostics"]["active_sessions"] == count
                    and engine_harness.field(post_http_irc, "registered") == count
                    and engine_harness.field(post_http_irc, "active") == count
                    and http["health"]["errors"] == 0
                    and http["bootstrap"]["errors"] == 0
                )
            payload["scenarios"].append(scenario)
            engine_harness.write_results(payload, "full-app-partial")
            if not success:
                break
        engine_harness.write_results(payload, "full-app")
    finally:
        engine_harness.compose(
            ["down", "--volumes", "--remove-orphans"], env=env, check=False
        )


if __name__ == "__main__":
    main()
