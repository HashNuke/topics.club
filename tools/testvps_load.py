"""Connection-capacity runner for the deployed split releases in ``testvps``.

The runner deliberately provisions through local release RPC instead of exposing a
load-only HTTP endpoint. RPC is already restricted to the destination host and it
lets the harness drive the same ``EngineClient`` lifecycle used by the gateway.
"""

from __future__ import annotations

import datetime as dt
import json
import re
import time
from pathlib import Path
from typing import Any

import split_acceptance
from testvps import (
    POSTGRES_CONTAINER,
    PROJECT_ROOT,
    VPS_CONTAINER,
    VPS_MEMORY_BYTES,
    VPS_NETWORK,
    VpsCommands,
    docker_object_exists,
    output,
    run,
)


RESULTS_DIR = PROJECT_ROOT / ".load-tests"
IRC_CONTAINER = split_acceptance.IRC_CONTAINER
IRC_IMAGE = split_acceptance.IRC_IMAGE
IRC_SCRIPT = split_acceptance.IRC_SCRIPT
ENGINE_SERVICE = split_acceptance.ENGINE_SERVICE
GATEWAY_SERVICE = split_acceptance.GATEWAY_SERVICE
WIREKEEPER_SERVICE = split_acceptance.WIREKEEPER_SERVICE
RUN_ID_PATTERN = re.compile(r"[a-z0-9][a-z0-9-]{0,39}\Z")
SERVICE_PROPERTIES = (
    "ActiveState,MainPID,MemoryCurrent,MemoryPeak,CPUUsageNSec,TasksCurrent,NRestarts,"
    "LimitNOFILE,LimitNOFILESoft"
)


def parse_counts(value: str | tuple[object, ...] | list[object]) -> list[int]:
    items = value if isinstance(value, (tuple, list)) else value.split(",")
    counts = [int(str(item).strip().replace("_", "")) for item in items]
    if not counts or any(count <= 0 for count in counts):
        raise ValueError("counts must be positive comma-separated integers")
    if counts != sorted(set(counts)):
        raise ValueError("counts must be unique and strictly increasing")
    return counts


def validate_run_id(run_id: str) -> str:
    if not RUN_ID_PATTERN.fullmatch(run_id):
        raise ValueError("run_id must be 1-40 lowercase letters, digits, or hyphens")
    return run_id


def release_manifest(role: str) -> dict[str, str]:
    if role not in {"gateway", "wirekeeper", "engine"}:
        raise ValueError("release role must be gateway, wirekeeper, or engine")
    contents = output(
        [
            "docker",
            "exec",
            VPS_CONTAINER,
            "cat",
            f"/srv/topics-club/current-{role}/deploy-manifest",
        ]
    )
    manifest = dict(line.split("=", 1) for line in contents.splitlines() if "=" in line)
    expected_release = f"topics_club_{role}"
    if (
        manifest.get("release") != expected_release
        or not re.fullmatch(r"[0-9a-f]{40}", manifest.get("commit", ""))
        or not manifest.get("tag")
    ):
        raise RuntimeError(f"invalid deployed {role} release manifest: {manifest!r}")
    return manifest


def elixir_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=True)


def rpc_marker_json(role: str, marker: str, expression: str) -> dict[str, Any]:
    prefix = f"{marker}="
    response = split_acceptance.release_rpc(role, expression)
    for line in reversed(response.splitlines()):
        if line.startswith(prefix):
            payload = json.loads(line.removeprefix(prefix))
            if isinstance(payload, dict):
                return payload
    raise RuntimeError(f"{role} release RPC did not return {marker} JSON")


def provision_expression(
    run_id: str,
    start_sequence: int,
    count: int,
    concurrency: int,
) -> str:
    validate_run_id(run_id)
    if start_sequence <= 0 or count <= 0 or concurrency <= 0:
        raise ValueError("provision batch values must be positive")
    if count > 100:
        raise ValueError("one provisioning batch may contain at most 100 connections")
    if concurrency > 25:
        raise ValueError("provisioning concurrency may not exceed 25")

    return f"""
run_id = {elixir_string(run_id)}
results =
  {start_sequence}..{start_sequence + count - 1}
  |> Task.async_stream(
    fn sequence ->
      email = "testvps-load-#{{run_id}}-#{{sequence}}@example.test"
      user_result =
        case TopicsClub.Accounts.get_user_by_email(email) do
          nil -> TopicsClub.Accounts.register_user(%{{email: email}})
          user -> {{:ok, user}}
        end

      with {{:ok, user}} <- user_result,
           :ok <- TopicsClub.Accounts.touch_last_seen(user),
           {{:ok, connection}} <-
             TopicsClub.Chat.Connections.create_or_get(user, %{{
               "name" => "testvps load",
               "host" => "{IRC_CONTAINER}",
               "port" => 6667,
               "use_tls" => false,
               "nickname" => "load#{{sequence}}",
               "username" => "load#{{sequence}}",
               "realname" => "Test VPS load #{{sequence}}"
             }}),
           {{:ok, _reply}} <-
             TopicsClub.EngineClient.ensure_connection(
               user.id,
               connection.id,
               timeout: 40_000
             ) do
        {{:ok, connection.id}}
      else
        error -> {{:error, sequence, inspect(error, limit: 10)}}
      end
    end,
    max_concurrency: {concurrency},
    ordered: false,
    timeout: :infinity
  )

summary =
  Enum.reduce(results, %{{connected: 0, errors: []}}, fn
    {{:ok, {{:ok, _connection_id}}}}, summary ->
      Map.update!(summary, :connected, &(&1 + 1))

    {{:ok, {{:error, sequence, reason}}}}, summary ->
      Map.update!(summary, :errors, &[%%{{sequence: sequence, reason: reason}} | &1])

    {{:exit, reason}}, summary ->
      Map.update!(summary, :errors, &[%%{{sequence: nil, reason: inspect(reason)}} | &1])
  end)

IO.puts("LOAD_PROVISION_JSON=" <> Jason.encode!(summary))
""".replace("%%", "%")


def provision_batch(
    run_id: str,
    start_sequence: int,
    count: int,
    concurrency: int,
) -> dict[str, Any]:
    return rpc_marker_json(
        "gateway",
        "LOAD_PROVISION_JSON",
        provision_expression(run_id, start_sequence, count, concurrency),
    )


def stats_expression(run_id: str) -> str:
    validate_run_id(run_id)
    return f"""
import Ecto.Query
pattern = {elixir_string(f"testvps-load-{run_id}-%@example.test")}
users = from(user in TopicsClub.Accounts.User, where: like(user.email, ^pattern))
connections =
  from(connection in TopicsClub.Chat.ServerConnection,
    join: user in TopicsClub.Accounts.User,
    on: user.id == connection.user_id,
    where: like(user.email, ^pattern)
  )
payload = %{{
  users: TopicsClub.Repo.aggregate(users, :count),
  connections: TopicsClub.Repo.aggregate(connections, :count),
  total_connections: TopicsClub.Repo.aggregate(TopicsClub.Chat.ServerConnection, :count)
}}
IO.puts("LOAD_STATS_JSON=" <> Jason.encode!(payload))
"""


def run_stats(run_id: str) -> dict[str, Any]:
    return rpc_marker_json("gateway", "LOAD_STATS_JSON", stats_expression(run_id))


def cleanup_expression(run_id: str, batch_size: int, concurrency: int) -> str:
    validate_run_id(run_id)
    if batch_size <= 0 or concurrency <= 0:
        raise ValueError("cleanup batch values must be positive")
    if concurrency > 25:
        raise ValueError("cleanup concurrency may not exceed 25")

    return f"""
import Ecto.Query
pattern = {elixir_string(f"testvps-load-{run_id}-%@example.test")}
connection_query =
  from(connection in TopicsClub.Chat.ServerConnection,
    join: user in TopicsClub.Accounts.User,
    on: user.id == connection.user_id,
    where: like(user.email, ^pattern),
    order_by: [asc: connection.id]
  )

connections =
  connection_query
  |> limit({batch_size})
  |> select([connection, _user], {{connection.user_id, connection.id}})
  |> TopicsClub.Repo.all()

results =
  Task.async_stream(
    connections,
    fn {{user_id, connection_id}} ->
      case TopicsClub.EngineClient.delete_connection(
             user_id,
             connection_id,
             timeout: 40_000
           ) do
        {{:ok, %{{deleted: true}}}} -> :deleted
        error -> {{:error, connection_id, inspect(error, limit: 10)}}
      end
    end,
    max_concurrency: {concurrency},
    ordered: false,
    timeout: :infinity
  )
  |> Enum.to_list()

{{deleted, errors}} =
  Enum.reduce(results, {{0, []}}, fn
    {{:ok, :deleted}}, {{deleted, errors}} -> {{deleted + 1, errors}}
    {{:ok, {{:error, id, reason}}}}, {{deleted, errors}} ->
      {{deleted, [%%{{connection_id: id, reason: reason}} | errors]}}
    {{:exit, reason}}, {{deleted, errors}} ->
      {{deleted, [%%{{connection_id: nil, reason: inspect(reason)}} | errors]}}
  end)

remaining =
  connection_query
  |> exclude(:order_by)
  |> TopicsClub.Repo.aggregate(:count)
if remaining == 0 do
  from(user in TopicsClub.Accounts.User, where: like(user.email, ^pattern))
  |> TopicsClub.Repo.delete_all()
end
users_remaining =
  from(user in TopicsClub.Accounts.User, where: like(user.email, ^pattern))
  |> TopicsClub.Repo.aggregate(:count)

IO.puts("LOAD_CLEANUP_JSON=" <> Jason.encode!(%{{
  deleted: deleted,
  errors: errors,
  remaining: remaining,
  users_remaining: users_remaining
}}))
""".replace("%%", "%")


def cleanup_batch(run_id: str, batch_size: int, concurrency: int) -> dict[str, Any]:
    return rpc_marker_json(
        "gateway",
        "LOAD_CLEANUP_JSON",
        cleanup_expression(run_id, batch_size, concurrency),
    )


def start_irc_container() -> None:
    if docker_object_exists("container", IRC_CONTAINER):
        raise RuntimeError(
            "synthetic IRC container already exists; finish acceptance or remove it first"
        )
    run(
        [
            "docker",
            "run",
            "--detach",
            "--name",
            IRC_CONTAINER,
            "--network",
            VPS_NETWORK,
            "--memory",
            "768m",
            "--cpus",
            "1.0",
            "--ulimit",
            "nofile=65536:65536",
            "--mount",
            f"type=bind,src={IRC_SCRIPT},dst=/load-test/irc_server.exs,readonly",
            "--env",
            "IRC_PORT=6667",
            "--env",
            "CONTROL_PORT=8080",
            IRC_IMAGE,
            "elixir",
            "/load-test/irc_server.exs",
        ],
        capture=True,
    )
    try:
        split_acceptance.wait_until(
            "synthetic IRC control port",
            30,
            lambda: split_acceptance.irc_control("PING") == "PONG",
        )
    except BaseException:
        split_acceptance.remove_irc_container()
        raise


def release_metrics(role: str, expression: str) -> dict[str, Any]:
    try:
        return rpc_marker_json(role, "LOAD_METRICS_JSON", expression)
    except RuntimeError as error:
        return {"error": str(error)}


def engine_metrics() -> dict[str, Any]:
    expression = """
payload = %{
  diagnostics: TopicsClub.Engine.Diagnostics.snapshot(),
  memory: Map.new(:erlang.memory()),
  process_count: :erlang.system_info(:process_count),
  port_count: :erlang.system_info(:port_count),
  run_queue: :erlang.statistics(:run_queue)
}
IO.puts("LOAD_METRICS_JSON=" <> Jason.encode!(payload))
"""
    return release_metrics("engine", expression)


def wirekeeper_metrics() -> dict[str, Any]:
    expression = """
case TopicsClub.Wirekeeper.diagnostics() do
  {:ok, diagnostics} ->
    payload = %{
      diagnostics: diagnostics,
      memory: Map.new(:erlang.memory()),
      process_count: :erlang.system_info(:process_count),
      port_count: :erlang.system_info(:port_count),
      run_queue: :erlang.statistics(:run_queue)
    }
    IO.puts("LOAD_METRICS_JSON=" <> Jason.encode!(payload))
  error ->
    raise "Wirekeeper diagnostics failed: #{inspect(error)}"
end
"""
    return release_metrics("wirekeeper", expression)


def gateway_metrics() -> dict[str, Any]:
    expression = """
payload = %{
  memory: Map.new(:erlang.memory()),
  process_count: :erlang.system_info(:process_count),
  port_count: :erlang.system_info(:port_count),
  run_queue: :erlang.statistics(:run_queue)
}
IO.puts("LOAD_METRICS_JSON=" <> Jason.encode!(payload))
"""
    return release_metrics("gateway", expression)


def service_metrics(service: str) -> dict[str, Any]:
    result = run(
        [
            "docker",
            "exec",
            VPS_CONTAINER,
            "systemctl",
            "show",
            service,
            f"--property={SERVICE_PROPERTIES}",
        ],
        capture=True,
    )
    payload: dict[str, Any] = {}
    for line in result.stdout.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        payload[key] = int(value) if value.isdigit() else value
    return payload


def container_cgroup() -> Path:
    pid = int(output(["docker", "inspect", "--format", "{{.State.Pid}}", VPS_CONTAINER]))
    cgroup_line = next(
        line for line in Path(f"/proc/{pid}/cgroup").read_text().splitlines() if line.startswith("0::")
    )
    current = Path("/sys/fs/cgroup") / cgroup_line.removeprefix("0::").lstrip("/")
    for candidate in (current, *current.parents):
        memory_max = candidate / "memory.max"
        if memory_max.is_file() and memory_max.read_text().strip() == str(VPS_MEMORY_BYTES):
            return candidate
    raise RuntimeError("could not locate the pseudo-VPS 2 GiB cgroup")


def cgroup_metrics() -> dict[str, Any]:
    cgroup = container_cgroup()

    def value(name: str) -> int | str:
        raw = (cgroup / name).read_text().strip()
        return int(raw) if raw.isdigit() else raw

    events = {
        key: int(raw)
        for key, raw in (
            line.split(maxsplit=1) for line in (cgroup / "memory.events").read_text().splitlines()
        )
    }
    return {
        "memory_current": value("memory.current"),
        "memory_peak": value("memory.peak"),
        "memory_max": value("memory.max"),
        "swap_current": value("memory.swap.current"),
        "swap_max": value("memory.swap.max"),
        "memory_events": events,
    }


def reset_cgroup_memory_peak() -> str:
    """Start the runtime measurement after any destination-side release build peaks."""
    peak_file = container_cgroup() / "memory.peak"

    if peak_file.stat().st_mode & 0o200:
        run(
            [
                "docker",
                "exec",
                VPS_CONTAINER,
                "bash",
                "-c",
                'printf 0 > "$1"',
                "load-cgroup-peak-reset",
                str(peak_file),
            ]
        )
        return "memory.peak write"

    # Linux 6.8 exposes memory.peak as read-only. Recreating this exact disposable
    # container's cgroup clears the build peak while preserving its release and DB volumes.
    run(["docker", "restart", VPS_CONTAINER], capture=True)
    split_acceptance.wait_gateway_health()
    return "pseudo-VPS cgroup restart"


def docker_metrics(container: str) -> dict[str, Any]:
    if not docker_object_exists("container", container):
        return {"state": "absent"}
    return json.loads(
        output(["docker", "stats", "--no-stream", "--format", "{{json .}}", container])
    )


def health_metrics() -> dict[str, Any]:
    result = run(
        [
            "docker",
            "exec",
            VPS_CONTAINER,
            "curl",
            "--silent",
            "--show-error",
            "--output",
            "/dev/null",
            "--write-out",
            "%{http_code} %{time_total}",
            "--max-time",
            "5",
            "http://127.0.0.1:4000/health",
        ],
        capture=True,
    )
    status, seconds = result.stdout.strip().split()
    return {"status": int(status), "elapsed_ms": round(float(seconds) * 1_000, 3)}


def sample(run_id: str) -> dict[str, Any]:
    return {
        "timestamp_utc": dt.datetime.now(dt.UTC).isoformat(),
        "cgroup": cgroup_metrics(),
        "containers": {
            "app_host": docker_metrics(VPS_CONTAINER),
            "postgres_external": docker_metrics(POSTGRES_CONTAINER),
            "irc_external": docker_metrics(IRC_CONTAINER),
        },
        "services": {
            "gateway": service_metrics(GATEWAY_SERVICE),
            "wirekeeper": service_metrics(WIREKEEPER_SERVICE),
            "engine": service_metrics(ENGINE_SERVICE),
        },
        "gateway": gateway_metrics(),
        "wirekeeper": wirekeeper_metrics(),
        "engine": engine_metrics(),
        "database": run_stats(run_id),
        "irc": split_acceptance.acceptance_stats(),
        "health": health_metrics(),
    }


def nested(payload: dict[str, Any], *keys: str, default: Any = 0) -> Any:
    value: Any = payload
    for key in keys:
        if not isinstance(value, dict) or key not in value:
            return default
        value = value[key]
    return value


def ready(sampled: dict[str, Any], target: int) -> bool:
    irc = sampled["irc"]
    return bool(
        isinstance(irc, dict)
        and irc.get("active") == target
        and irc.get("registered") == target
        and irc.get("send_errors") == 0
        and nested(sampled, "database", "users") == target
        and nested(sampled, "database", "connections") == target
        and nested(sampled, "engine", "diagnostics", "active_sessions") == target
        and nested(sampled, "wirekeeper", "diagnostics", "total_connections") == target
        and nested(sampled, "wirekeeper", "diagnostics", "open_connections") == target
        and nested(sampled, "wirekeeper", "diagnostics", "attached_connections") == target
        and nested(sampled, "wirekeeper", "diagnostics", "detached_connections") == 0
        and nested(sampled, "wirekeeper", "diagnostics", "dropped_records") == 0
        and nested(sampled, "wirekeeper", "diagnostics", "dropped_bytes") == 0
        and nested(sampled, "cgroup", "swap_current") == 0
        and nested(sampled, "cgroup", "memory_events", "oom_kill") == 0
        and nested(sampled, "health", "status") == 200
        and all(
            nested(sampled, "services", service, "ActiveState") == "active"
            for service in ("gateway", "wirekeeper", "engine")
        )
    )


def wait_for(
    label: str,
    run_id: str,
    timeout: int,
    predicate: Any,
    sample_interval: int,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    deadline = time.monotonic() + timeout
    samples: list[dict[str, Any]] = []
    last: dict[str, Any] | None = None
    while time.monotonic() < deadline:
        last = sample(run_id)
        samples.append(last)
        if predicate(last):
            return last, samples
        time.sleep(sample_interval)
    raise TimeoutError(f"timed out waiting for {label}; last sample: {last!r}")


def steady_hold(
    run_id: str, target: int, seconds: int, sample_interval: int
) -> tuple[bool, list[dict[str, Any]]]:
    deadline = time.monotonic() + seconds
    samples: list[dict[str, Any]] = []
    success = True
    while time.monotonic() < deadline:
        current = sample(run_id)
        samples.append(current)
        success = ready(current, target) and success
        remaining = max(0.0, deadline - time.monotonic())
        if remaining > 0:
            time.sleep(min(sample_interval, remaining))
    return success, samples


def engine_restart_phase(
    run_id: str, target: int, timeout: int, sample_interval: int
) -> dict[str, Any]:
    before = sample(run_id)
    accepted_before = nested(before, "irc", "accepted_total")
    split_acceptance.manage_service("stop", ENGINE_SERVICE)
    engine_stopped = True
    try:
        detached, detached_samples = wait_for(
            "Wirekeeper detachment at load",
            run_id,
            timeout,
            lambda current: (
                nested(current, "wirekeeper", "diagnostics", "open_connections") == target
                and nested(current, "wirekeeper", "diagnostics", "detached_connections") == target
                and nested(current, "irc", "active") == target
            ),
            sample_interval,
        )
        burst = split_acceptance.irc_control(f"BURST_PACED 1 {min(target, 10_000)} 0")
        if not isinstance(burst, dict) or burst.get("errors") != 0 or burst.get("sent") != target:
            raise RuntimeError(f"detached IRC burst failed: {burst!r}")
        buffered, buffered_samples = wait_for(
            "Wirekeeper buffering at load",
            run_id,
            timeout,
            lambda current: nested(
                current, "wirekeeper", "diagnostics", "buffered_records"
            )
            >= target,
            sample_interval,
        )
        split_acceptance.manage_service("start", ENGINE_SERVICE)
        engine_stopped = False
        split_acceptance.wait_gateway_health()
        resumed, resume_samples = wait_for(
            "engine load reattachment",
            run_id,
            timeout,
            lambda current: ready(current, target)
            and nested(current, "wirekeeper", "diagnostics", "buffered_records") == 0,
            sample_interval,
        )
        accepted_after = nested(resumed, "irc", "accepted_total")
        return {
            "success": accepted_after == accepted_before,
            "accepted_before": accepted_before,
            "accepted_after": accepted_after,
            "burst": burst,
            "detached": detached,
            "buffered": buffered,
            "resumed": resumed,
            "samples": detached_samples + buffered_samples + resume_samples,
        }
    finally:
        if engine_stopped:
            split_acceptance.manage_service("start", ENGINE_SERVICE)
            split_acceptance.wait_gateway_health()


def drop_recovery_phase(
    run_id: str, target: int, timeout: int, sample_interval: int
) -> dict[str, Any]:
    before = sample(run_id)
    accepted_before = nested(before, "irc", "accepted_total")
    drop = split_acceptance.irc_control("DROP")
    if not isinstance(drop, dict) or drop.get("dropped") != target:
        raise RuntimeError(f"synthetic IRC server did not drop exactly {target} sockets: {drop!r}")
    recovered, samples = wait_for(
        "upstream load reconnect",
        run_id,
        timeout,
        lambda current: ready(current, target)
        and nested(current, "irc", "accepted_total") == accepted_before + target,
        sample_interval,
    )
    return {
        "success": True,
        "drop": drop,
        "accepted_before": accepted_before,
        "accepted_after": nested(recovered, "irc", "accepted_total"),
        "samples": samples,
    }


def service_restart_counts(sampled: dict[str, Any]) -> dict[str, int]:
    return {
        service: nested(sampled, "services", service, "NRestarts", default=-1)
        for service in ("gateway", "wirekeeper", "engine")
    }


def scenario_summary(
    target: int,
    functional_success: bool,
    samples: list[dict[str, Any]],
    restart_baseline: dict[str, int],
) -> dict[str, Any]:
    memory_values = [
        max(
            nested(item, "cgroup", "memory_current"),
            nested(item, "cgroup", "memory_peak"),
        )
        for item in samples
        if isinstance(nested(item, "cgroup", "memory_current"), int)
        and isinstance(nested(item, "cgroup", "memory_peak"), int)
    ]
    peak_memory = max(memory_values, default=0)
    peak_fraction = peak_memory / VPS_MEMORY_BYTES
    observed_restarts = {
        service: max(
            (
                nested(item, "services", service, "NRestarts", default=-1)
                for item in samples
            ),
            default=-1,
        )
        for service in restart_baseline
    }
    restart_free = observed_restarts == restart_baseline
    functional_success = functional_success and restart_free
    return {
        "connections": target,
        "functional_success": functional_success,
        "planning_success": functional_success and peak_fraction <= 0.8,
        "peak_memory_bytes": peak_memory,
        "peak_memory_fraction": round(peak_fraction, 4),
        "service_restart_baseline": restart_baseline,
        "service_restart_observed_max": observed_restarts,
        "samples": samples,
    }


def write_results(payload: dict[str, Any], run_id: str) -> Path:
    RESULTS_DIR.mkdir(exist_ok=True)
    path = RESULTS_DIR / f"{run_id}-testvps-load.json"
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    return path


def ensure_clean(run_id: str) -> dict[str, Any]:
    split_acceptance.ensure_ready()
    split_acceptance.wait_gateway_health()
    current = sample(run_id)
    if nested(current, "database", "total_connections") != 0:
        raise RuntimeError("testvps database already has server connections; clean or reset it first")
    if nested(current, "engine", "diagnostics", "active_sessions") != 0:
        raise RuntimeError("testvps engine already has active Sessions; clean or reset it first")
    if nested(current, "wirekeeper", "diagnostics", "total_connections") != 0:
        raise RuntimeError("testvps Wirekeeper already has retained connections; clean or reset it first")
    if nested(current, "irc", "active") != 0:
        raise RuntimeError("synthetic IRC sidecar was not empty at load start")
    return current


def ensure_capacity_prerequisites(baseline: dict[str, Any], maximum_target: int) -> None:
    required_open_files = maximum_target + 1_024
    soft_limit = nested(
        baseline,
        "services",
        "wirekeeper",
        "LimitNOFILESoft",
        default=0,
    )
    if not isinstance(soft_limit, int) or soft_limit < required_open_files:
        raise RuntimeError(
            "deployed Wirekeeper open-file limit is too low for this capacity run: "
            f"need at least {required_open_files}, found {soft_limit}; reprovision the "
            "testvps service units before deploying and measuring"
        )


def cleanup_run(run_id: str, batch_size: int, concurrency: int) -> list[dict[str, Any]]:
    batches: list[dict[str, Any]] = []
    while True:
        result = cleanup_batch(run_id, batch_size, concurrency)
        batches.append(result)
        if result["remaining"] == 0 and result["users_remaining"] == 0:
            return batches
        if result["deleted"] == 0:
            raise RuntimeError(f"load cleanup made no progress: {result!r}")


def cleanup_existing_run(run_id: str, batch_size: int = 100, concurrency: int = 10) -> None:
    validate_run_id(run_id)
    if not 1 <= batch_size <= 100:
        raise ValueError("batch_size must be between 1 and 100")
    if not 1 <= concurrency <= 25:
        raise ValueError("concurrency must be between 1 and 25")
    split_acceptance.ensure_ready()
    split_acceptance.wait_gateway_health()
    before = run_stats(run_id)
    if before["users"] == 0 and before["connections"] == 0:
        raise RuntimeError(f"testvps has no data for load run {run_id}")
    if before["total_connections"] != before["connections"]:
        raise RuntimeError("testvps contains connections outside the requested load run")
    results = cleanup_run(run_id, batch_size, concurrency)
    retained = nested(wirekeeper_metrics(), "diagnostics", "total_connections", default=-1)
    if retained != 0:
        raise RuntimeError(f"Wirekeeper still retains {retained} connections after cleanup")
    if docker_object_exists("container", IRC_CONTAINER):
        split_acceptance.remove_irc_container()
    VpsCommands().build_limits()
    print(f"Lifecycle cleanup completed for testvps load run {run_id}: {results[-1]}")


def run_load(
    *,
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
    targets = parse_counts(counts)
    if not 1 <= batch_size <= 100:
        raise ValueError("batch_size must be between 1 and 100")
    if not 1 <= provision_concurrency <= 25:
        raise ValueError("provision_concurrency must be between 1 and 25")
    if sample_interval <= 0 or startup_timeout <= 0:
        raise ValueError("concurrency, sample interval, and timeout must be positive")
    if steady_seconds < 0:
        raise ValueError("steady_seconds cannot be negative")

    run_id = dt.datetime.now(dt.UTC).strftime("%Y%m%dt%H%M%Sz").lower()
    validate_run_id(run_id)
    limits = VpsCommands()
    payload: dict[str, Any] = {
        "run_id": run_id,
        "started_at_utc": dt.datetime.now(dt.UTC).isoformat(),
        "source_revision": output(["git", "rev-parse", "HEAD"]),
        "configuration": {
            "counts": targets,
            "batch_size": batch_size,
            "provision_concurrency": provision_concurrency,
            "steady_seconds": steady_seconds,
            "sample_interval": sample_interval,
            "startup_timeout": startup_timeout,
            "restart_engine": restart_engine,
            "drop_recovery": drop_recovery,
            "app_host_memory_bytes": VPS_MEMORY_BYTES,
            "app_host_swap_bytes": 0,
            "included_in_app_host_limit": [
                "Ubuntu/systemd runtime",
                "gateway BEAM",
                "Wirekeeper BEAM and IRC sockets",
                "engine BEAM",
                "target-side Docker daemon and filesystem cache",
            ],
            "excluded_from_app_host_limit": [
                "external 384 MiB test PostgreSQL sidecar",
                "external 768 MiB synthetic IRC sidecar",
            ],
            "provisioning": "local gateway release RPC; no load-test HTTP endpoint",
        },
        "scenarios": [],
    }
    current_count = 0
    irc_started = False
    runtime_limits_enabled = False
    prepared = False

    try:
        start_irc_container()
        irc_started = True
        limits.runtime_limits()
        runtime_limits_enabled = True
        payload["memory_peak_reset"] = reset_cgroup_memory_peak()
        payload["baseline"] = ensure_clean(run_id)
        ensure_capacity_prerequisites(payload["baseline"], targets[-1])
        payload["deployed_releases"] = {
            role: release_manifest(role) for role in ("gateway", "wirekeeper", "engine")
        }
        restart_baseline = service_restart_counts(payload["baseline"])
        prepared = True
        write_results(payload, run_id)

        for target in targets:
            provision_results = []
            provision_started = time.monotonic()
            while current_count < target:
                count = min(batch_size, target - current_count)
                result = provision_batch(
                    run_id,
                    current_count + 1,
                    count,
                    provision_concurrency,
                )
                provision_results.append(result)
                if result["errors"] or result["connected"] != count:
                    raise RuntimeError(f"load provisioning batch failed: {result!r}")
                current_count += count

            provision_seconds = round(time.monotonic() - provision_started, 3)
            ready_started = time.monotonic()
            ready_sample, startup_samples = wait_for(
                f"{target} split-release IRC connections",
                run_id,
                startup_timeout,
                lambda current: ready(current, target),
                sample_interval,
            )
            connection_ready_seconds = round(time.monotonic() - ready_started, 3)
            hold_success, hold_samples = steady_hold(
                run_id, target, steady_seconds, sample_interval
            )
            scenario_samples = startup_samples + hold_samples
            functional_success = ready(ready_sample, target) and hold_success
            restart = None
            if restart_engine and functional_success:
                restart = engine_restart_phase(
                    run_id, target, startup_timeout, sample_interval
                )
                scenario_samples += restart["samples"]
                functional_success = functional_success and restart["success"]

            scenario = scenario_summary(
                target,
                functional_success,
                scenario_samples,
                restart_baseline,
            )
            scenario.update(
                {
                    "provision_seconds": provision_seconds,
                    "connection_ready_seconds": connection_ready_seconds,
                    "provision_batches": provision_results,
                }
            )
            if restart is not None:
                scenario["engine_restart"] = {
                    key: value for key, value in restart.items() if key != "samples"
                }

            payload["scenarios"].append(scenario)
            write_results(payload, run_id)
            if not scenario["functional_success"]:
                break

        if drop_recovery and payload["scenarios"] and payload["scenarios"][-1]["functional_success"]:
            drop_result = drop_recovery_phase(
                run_id, current_count, startup_timeout, sample_interval
            )
            drop_details = {
                key: value for key, value in drop_result.items() if key != "samples"
            }
            payload["drop_recovery"] = drop_details
            final_scenario = payload["scenarios"][-1]
            final_samples = final_scenario["samples"] + drop_result["samples"]
            final_summary = scenario_summary(
                current_count,
                final_scenario["functional_success"] and drop_result["success"],
                final_samples,
                restart_baseline,
            )
            final_scenario.update(final_summary)
            final_scenario["drop_recovery"] = drop_details
            write_results(payload, run_id)
    finally:
        if cleanup and prepared:
            if not split_acceptance.service_active(ENGINE_SERVICE):
                split_acceptance.manage_service("start", ENGINE_SERVICE)
                split_acceptance.wait_gateway_health()
            try:
                payload["cleanup"] = cleanup_run(
                    run_id, batch_size, provision_concurrency
                )
            except BaseException as error:
                payload["cleanup"] = {
                    "error": str(error),
                    "warning": "IRC sidecar and no-swap runtime limit remain active",
                }
                payload["finished_at_utc"] = dt.datetime.now(dt.UTC).isoformat()
                path = write_results(payload, run_id)
                print(
                    "Testvps load cleanup failed; resources remain active and results are at "
                    f"{path.relative_to(PROJECT_ROOT)}"
                )
                raise
            else:
                if irc_started:
                    split_acceptance.remove_irc_container()
                if runtime_limits_enabled:
                    limits.build_limits()
                payload["finished_at_utc"] = dt.datetime.now(dt.UTC).isoformat()
                path = write_results(payload, run_id)
                print(f"Testvps load results: {path.relative_to(PROJECT_ROOT)}")
        elif cleanup:
            if irc_started:
                split_acceptance.remove_irc_container()
            if runtime_limits_enabled:
                limits.build_limits()
            payload["cleanup"] = {"skipped": True, "reason": "load preparation did not complete"}
            payload["finished_at_utc"] = dt.datetime.now(dt.UTC).isoformat()
            path = write_results(payload, run_id)
            print(f"Testvps load did not start; diagnostics are at {path.relative_to(PROJECT_ROOT)}")
        else:
            payload["cleanup"] = {
                "skipped": True,
                "warning": "IRC sidecar and no-swap runtime limit remain active",
            }
            path = write_results(payload, run_id)
            print(f"Testvps load left resources active; results: {path.relative_to(PROJECT_ROOT)}")


__all__ = [
    "cleanup_expression",
    "cleanup_existing_run",
    "parse_counts",
    "provision_expression",
    "run_load",
    "stats_expression",
]
