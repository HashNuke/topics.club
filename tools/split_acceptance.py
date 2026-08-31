"""Explicit pseudo-VPS acceptance test for the complete split releases."""

from __future__ import annotations

import json
import subprocess
import sys
import time
from collections.abc import Callable
from typing import Any

from testvps import (
    POSTGRES_CONTAINER,
    PROJECT_ROOT,
    VPS_CONTAINER,
    VPS_NETWORK,
    docker_object_exists,
)


IRC_CONTAINER = "topics-club-vps-irc"
IRC_IMAGE = (
    "docker.io/hexpm/elixir:1.19.5-erlang-28.5-debian-trixie-20260505-slim"
    "@sha256:133fa7e54ceb2d812e9f79e33e827019c3df2c1f8e89b6ae37d605d78d4d17cb"
)
IRC_SCRIPT = PROJECT_ROOT / "tools" / "load_test" / "irc_server.exs"
GATEWAY_SERVICE = "topics-club-gateway.service"
WIREKEEPER_SERVICE = "topics-club-wirekeeper.service"
ENGINE_SERVICE = "topics-club-engine.service"
CHANNEL = "#acceptance"


def run(
    command: list[str],
    *,
    capture: bool = False,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=PROJECT_ROOT,
        check=check,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def output(command: list[str]) -> str:
    return run(command, capture=True).stdout.strip()


def container_running(name: str) -> bool:
    if not docker_object_exists("container", name):
        return False
    return output(["docker", "inspect", "--format", "{{.State.Running}}", name]) == "true"


def service_active(service: str) -> bool:
    result = run(
        ["docker", "exec", VPS_CONTAINER, "systemctl", "is-active", "--quiet", service],
        capture=True,
        check=False,
    )
    return result.returncode == 0


def service_main_pid(service: str) -> int:
    value = output(
        [
            "docker",
            "exec",
            VPS_CONTAINER,
            "systemctl",
            "show",
            "--property",
            "MainPID",
            "--value",
            service,
        ]
    )
    pid = int(value)
    if pid <= 0:
        raise RuntimeError(f"{service} has no running main process")
    return pid


def manage_service(action: str, service: str) -> None:
    if action not in {"start", "stop"}:
        raise ValueError("service action must be start or stop")
    run(["docker", "exec", VPS_CONTAINER, "systemctl", action, service])


def ensure_ready() -> None:
    missing = [
        name
        for name in (VPS_CONTAINER, POSTGRES_CONTAINER)
        if not container_running(name)
    ]
    if missing:
        raise RuntimeError(
            "pseudo-VPS is not ready; run `bin/apptools testvps create`, provision it, "
            "then deploy Wirekeeper once and the gateway/engine roles"
        )

    inactive = [
        service
        for service in (GATEWAY_SERVICE, WIREKEEPER_SERVICE, ENGINE_SERVICE)
        if not service_active(service)
    ]
    if inactive:
        raise RuntimeError(
            "all deployed pseudo-VPS services must be active before acceptance: "
            + ", ".join(inactive)
        )


def remove_irc_container() -> None:
    if docker_object_exists("container", IRC_CONTAINER):
        run(["docker", "rm", "--force", IRC_CONTAINER], capture=True)


def start_irc_container() -> None:
    remove_irc_container()
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
            "256m",
            "--cpus",
            "0.5",
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
    wait_until("synthetic IRC control port", 30, lambda: irc_control("PING") == "PONG")


def parse_fields(value: str) -> dict[str, int]:
    fields: dict[str, int] = {}
    for item in value.split():
        if "=" not in item:
            return {}
        key, raw = item.split("=", 1)
        try:
            fields[key] = int(raw)
        except ValueError:
            return {}
    return fields


def irc_control(command: str) -> dict[str, int] | str:
    shell = (
        "exec 3<>/dev/tcp/127.0.0.1/8080\n"
        "printf '%s\\n' \"$1\" >&3\n"
        "read -r reply <&3\n"
        "printf '%s\\n' \"$reply\""
    )
    result = run(
        [
            "docker",
            "exec",
            IRC_CONTAINER,
            "bash",
            "-c",
            shell,
            "acceptance-control",
            command,
        ],
        capture=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError((result.stderr or result.stdout).strip())
    response = result.stdout.strip()
    return parse_fields(response) or response


def release_rpc(role: str, expression: str) -> str:
    if role not in {"gateway", "wirekeeper", "engine"}:
        raise ValueError("release role must be gateway, wirekeeper, or engine")

    release = f"topics_club_{role}"
    user = f"topics-club-{role}"
    home = f"/var/lib/topics-club/{role}"
    script = f"""set -a
. /etc/topics-club/{role}.env
set +a
export HOME={home}
export RELEASE_TMP={home}/tmp
export ERL_EPMD_ADDRESS=127.0.0.1
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export ELIXIR_ERL_OPTIONS=+fnu
exec runuser --user {user} --preserve-environment -- \
  /srv/topics-club/current-{role}/bin/{release} rpc "$1"
"""
    result = run(
        [
            "docker",
            "exec",
            VPS_CONTAINER,
            "bash",
            "-c",
            script,
            "acceptance-rpc",
            expression,
        ],
        capture=True,
        check=False,
    )
    if result.returncode != 0:
        details = (result.stderr + result.stdout).strip()
        raise RuntimeError(f"{role} release RPC failed: {details}")
    return result.stdout


def rpc_json(role: str, expression: str) -> dict[str, Any]:
    for line in reversed(release_rpc(role, expression).splitlines()):
        if line.startswith("ACCEPTANCE_JSON="):
            payload = json.loads(line.removeprefix("ACCEPTANCE_JSON="))
            if isinstance(payload, dict):
                return payload
    raise RuntimeError(f"{role} release RPC did not return acceptance JSON")


def elixir_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=True)


def wait_until(label: str, timeout: int, probe: Callable[[], Any]) -> Any:
    deadline = time.monotonic() + timeout
    last: Any = None
    while time.monotonic() < deadline:
        try:
            last = probe()
            if last:
                return last
        except (RuntimeError, OSError) as error:
            last = error
        time.sleep(1)
    raise TimeoutError(f"timed out waiting for {label}; last result: {last!r}")


def wait_gateway_health() -> dict[str, Any]:
    def probe() -> dict[str, Any] | None:
        result = run(
            [
                "docker",
                "exec",
                VPS_CONTAINER,
                "curl",
                "--fail",
                "--silent",
                "--show-error",
                "--max-time",
                "2",
                "http://127.0.0.1:4000/health",
            ],
            capture=True,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError((result.stderr or result.stdout).strip())

        payload = json.loads(result.stdout)
        if (
            payload.get("status") == "ok"
            and payload.get("engine", {}).get("status") == "connected"
        ):
            return payload
        return None

    return wait_until("gateway end-to-end health", 45, probe)


def seed_connection(token: str) -> dict[str, Any]:
    email = f"split-acceptance-{token}@example.test"
    nickname = f"accept{token[:8]}"
    expression = f"""
email = {elixir_string(email)}
{{:ok, user}} = TopicsClub.Accounts.register_user(%{{email: email}})
user =
  user
  |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now(:second))
  |> TopicsClub.Repo.update!()
{{:ok, connection}} = TopicsClub.Chat.Connections.create(user, %{{
  "name" => "split acceptance",
  "host" => {elixir_string(IRC_CONTAINER)},
  "port" => 6667,
  "use_tls" => false,
  "nickname" => {elixir_string(nickname)},
  "username" => {elixir_string(nickname)},
  "realname" => "Split acceptance"
}})
case TopicsClub.EngineClient.join_channel(
       user.id,
       connection.id,
       {elixir_string(CHANNEL)},
       timeout: 40_000
     ) do
  {{:ok, %{{membership: membership, status: status}}}} ->
    IO.puts("ACCEPTANCE_JSON=" <> Jason.encode!(%{{
      user_id: user.id,
      connection_id: connection.id,
      membership_id: membership.id,
      join_status: status
    }}))
  other ->
    raise "could not start acceptance connection: #{{inspect(other)}}"
end
"""
    return rpc_json("gateway", expression)


def gateway_connection_ready(
    user_id: int, connection_id: int, membership_id: int
) -> dict[str, Any] | None:
    expression = f"""
connection = TopicsClub.EngineClient.connection_info(
  {user_id},
  {connection_id},
  timeout: 10_000
)
membership = TopicsClub.Repo.get!(TopicsClub.Chat.ChannelMembership, {membership_id})
registered = match?({{:ok, %{{connection_info: %{{registered?: true}}}}}}, connection)
payload = %{{registered: registered, membership_status: membership.status}}
IO.puts("ACCEPTANCE_JSON=" <> Jason.encode!(payload))
"""
    payload = rpc_json("gateway", expression)
    if payload == {"registered": True, "membership_status": "joined"}:
        return payload
    return None


def send_outbound(user_id: int, connection_id: int, membership_id: int, body: str) -> None:
    expression = f"""
case TopicsClub.EngineClient.send_channel_message(
       {user_id},
       {connection_id},
       {membership_id},
       {elixir_string(body)},
       timeout: 40_000
     ) do
  {{:ok, %{{message: message}}}} ->
    IO.puts("ACCEPTANCE_JSON=" <> Jason.encode!(%{{body: message.body}}))
  other ->
    raise "outbound acceptance message failed: #{{inspect(other)}}"
end
"""
    payload = rpc_json("gateway", expression)
    if payload.get("body") != body:
        raise RuntimeError(f"unexpected outbound reply: {payload!r}")


def message_persisted(role: str, connection_id: int, body: str) -> bool:
    expression = f"""
message = TopicsClub.Repo.get_by(
  TopicsClub.Chat.Message,
  server_connection_id: {connection_id},
  body: {elixir_string(body)}
)
IO.puts("ACCEPTANCE_JSON=" <> Jason.encode!(%{{persisted: not is_nil(message)}}))
"""
    return rpc_json(role, expression).get("persisted") is True


def wirekeeper_connection(connection_id: int) -> dict[str, int | bool] | None:
    expression = f"""
case TopicsClub.Wirekeeper.info({connection_id}) do
  {{:ok, info}} ->
    IO.puts(
      "WIREKEEPER_INFO=" <>
        "attached=#{{info.attached?}} buffered=#{{info.buffered_records}} " <>
        "dropped=#{{info.dropped_records}}"
    )
  {{:error, reason}} ->
    IO.puts("WIREKEEPER_ERROR=" <> inspect(reason))
end
"""
    output = release_rpc("wirekeeper", expression)
    for line in reversed(output.splitlines()):
        if not line.startswith("WIREKEEPER_INFO="):
            continue
        fields: dict[str, int | bool] = {}
        for item in line.removeprefix("WIREKEEPER_INFO=").split():
            key, raw = item.split("=", 1)
            if raw in {"true", "false"}:
                fields[key] = raw == "true"
            else:
                fields[key] = int(raw)
        return fields
    return None


def gateway_history_contains(
    user_id: int,
    connection_id: int,
    membership_id: int,
    body: str,
) -> bool:
    expression = f"""
user = TopicsClub.Repo.get!(TopicsClub.Accounts.User, {user_id})
found = TopicsClub.Chat.MessageHistory.list_messages(user, {membership_id})
  |> Enum.any?(&(&1.body == {elixir_string(body)}))
connected = match?(
  {{:ok, %{{connection_info: %{{registered?: true}}}}}},
  TopicsClub.EngineClient.connection_info(user.id, {connection_id}, timeout: 10_000)
)
IO.puts("ACCEPTANCE_JSON=" <> Jason.encode!(%{{
  found: found,
  gateway_connected: connected
}}))
"""
    payload = rpc_json("gateway", expression)
    return payload == {"found": True, "gateway_connected": True}


def cleanup_test_data(user_id: int, connection_id: int) -> None:
    expression = f"""
delete_result = TopicsClub.EngineClient.delete_connection(
  {user_id},
  {connection_id},
  timeout: 40_000
)
case TopicsClub.Repo.get(TopicsClub.Accounts.User, {user_id}) do
  nil -> :ok
  user -> TopicsClub.Repo.delete!(user)
end
IO.puts("ACCEPTANCE_JSON=" <> Jason.encode!(%{{deleted: inspect(delete_result)}}))
"""
    rpc_json("gateway", expression)


def acceptance_stats() -> dict[str, int]:
    stats = irc_control("STATS")
    if not isinstance(stats, dict):
        raise RuntimeError(f"synthetic IRC server returned invalid stats: {stats!r}")
    return stats


def run_acceptance() -> None:
    ensure_ready()
    token = f"{int(time.time())}-{time.monotonic_ns() % 1_000_000:06d}"
    ids: dict[str, Any] | None = None
    engine_stopped = False
    wirekeeper_stopped = False
    irc_started = False
    succeeded = False

    try:
        print("Starting temporary local IRC sidecar (no published ports).")
        start_irc_container()
        irc_started = True
        engine_pid = service_main_pid(ENGINE_SERVICE)
        wirekeeper_pid = service_main_pid(WIREKEEPER_SERVICE)
        ids = seed_connection(token)
        user_id = int(ids["user_id"])
        connection_id = int(ids["connection_id"])
        membership_id = int(ids["membership_id"])

        wait_until(
            "one registered local IRC connection",
            45,
            lambda: (
                stats
                if (stats := acceptance_stats()).get("active") == 1
                and stats.get("registered") == 1
                and stats.get("accepted_total") == 1
                else None
            ),
        )
        wait_until(
            "gateway-visible registered connection and joined channel",
            45,
            lambda: gateway_connection_ready(user_id, connection_id, membership_id),
        )

        outbound = f"split-acceptance-out-{token}"
        send_outbound(user_id, connection_id, membership_id, outbound)
        wait_until(
            "outbound PRIVMSG at the local IRC server",
            15,
            lambda: (
                stats
                if (stats := acceptance_stats()).get("privmsgs_received", 0) >= 1
                else None
            ),
        )

        before_restart = acceptance_stats()
        print("Stopping the engine while Wirekeeper continues to own the IRC socket.")
        manage_service("stop", ENGINE_SERVICE)
        engine_stopped = True
        if not service_active(WIREKEEPER_SERVICE) or service_main_pid(
            WIREKEEPER_SERVICE
        ) != wirekeeper_pid:
            raise RuntimeError("engine stop changed the Wirekeeper service process")

        wait_until(
            "Wirekeeper consumer detachment",
            30,
            lambda: (
                info
                if (info := wirekeeper_connection(connection_id))
                and info.get("attached") is False
                else None
            ),
        )

        inbound = f"split-acceptance-in-{token}"
        sent = irc_control(f"PRIVMSG {CHANNEL} {inbound}")
        if not isinstance(sent, dict) or sent.get("sent") != 1 or sent.get("errors") != 0:
            raise RuntimeError(f"could not inject inbound IRC message: {sent!r}")
        wait_until(
            "Wirekeeper buffering while the engine is stopped",
            30,
            lambda: (
                info
                if (info := wirekeeper_connection(connection_id))
                and int(info.get("buffered", 0)) >= 1
                and int(info.get("dropped", 0)) == 0
                else None
            ),
        )

        print("Starting the engine and checking replay on the original IRC socket.")
        manage_service("start", ENGINE_SERVICE)
        wait_gateway_health()
        engine_stopped = False

        restarted_engine_pid = service_main_pid(ENGINE_SERVICE)
        if restarted_engine_pid == engine_pid:
            raise RuntimeError("engine restart unexpectedly reused its prior process")
        engine_pid = restarted_engine_pid
        if service_main_pid(WIREKEEPER_SERVICE) != wirekeeper_pid:
            raise RuntimeError("engine restart changed the Wirekeeper service process")

        wait_until(
            "engine persistence after Wirekeeper replay",
            30,
            lambda: message_persisted("engine", connection_id, inbound),
        )
        wait_until(
            "Wirekeeper replay acknowledgement",
            30,
            lambda: (
                info
                if (info := wirekeeper_connection(connection_id))
                and info.get("attached") is True
                and int(info.get("buffered", 0)) == 0
                else None
            ),
        )

        after_restart = acceptance_stats()
        for key in ("accepted_total", "active", "registered"):
            if after_restart.get(key) != before_restart.get(key):
                raise RuntimeError(
                    f"engine restart changed IRC {key}: "
                    f"{before_restart.get(key)} -> {after_restart.get(key)}"
                )

        wait_until(
            "gateway history recovery after restart",
            30,
            lambda: gateway_history_contains(
                user_id,
                connection_id,
                membership_id,
                inbound,
            ),
        )

        before_wirekeeper_restart = acceptance_stats()
        print("Restarting Wirekeeper and checking that the live engine reconnects its session.")
        manage_service("stop", WIREKEEPER_SERVICE)
        wirekeeper_stopped = True

        wait_until(
            "IRC socket closure after Wirekeeper stop",
            30,
            lambda: (
                stats
                if (stats := acceptance_stats()).get("active") == 0
                else None
            ),
        )

        manage_service("start", WIREKEEPER_SERVICE)
        wirekeeper_stopped = False
        wait_gateway_health()

        if service_main_pid(WIREKEEPER_SERVICE) == wirekeeper_pid:
            raise RuntimeError("Wirekeeper restart unexpectedly reused its prior process")
        if service_main_pid(ENGINE_SERVICE) != engine_pid:
            raise RuntimeError("Wirekeeper restart changed the engine service process")

        wait_until(
            "engine IRC reconnect after Wirekeeper replacement",
            45,
            lambda: (
                stats
                if (stats := acceptance_stats()).get("active") == 1
                and stats.get("registered") == 1
                and stats.get("accepted_total", 0)
                == before_wirekeeper_restart.get("accepted_total", 0) + 1
                else None
            ),
        )

        after_wirekeeper = f"wirekeeper-restart-in-{token}"
        sent = irc_control(f"PRIVMSG {CHANNEL} {after_wirekeeper}")
        if not isinstance(sent, dict) or sent.get("sent") != 1 or sent.get("errors") != 0:
            raise RuntimeError(f"could not inject post-Wirekeeper IRC message: {sent!r}")

        wait_until(
            "engine persistence after Wirekeeper replacement",
            30,
            lambda: message_persisted("engine", connection_id, after_wirekeeper),
        )
        wait_until(
            "gateway history after Wirekeeper replacement",
            30,
            lambda: gateway_history_contains(
                user_id,
                connection_id,
                membership_id,
                after_wirekeeper,
            ),
        )

        cleanup_test_data(user_id, connection_id)
        ids = None
        succeeded = True

        print(
            "Split acceptance passed: real gateway and engine releases exchanged local IRC "
            "traffic; engine stop/start preserved the Wirekeeper PID and original IRC socket; "
            "the engine persisted traffic replayed after it returned; and Wirekeeper replacement "
            "made the unchanged engine reconnect instead of retaining a stale handle."
        )
    finally:
        if wirekeeper_stopped:
            try:
                manage_service("start", WIREKEEPER_SERVICE)
            except Exception as error:
                print(
                    f"warning: could not restore the Wirekeeper service: {error}",
                    file=sys.stderr,
                )

        if engine_stopped:
            try:
                manage_service("start", ENGINE_SERVICE)
                wait_gateway_health()
            except Exception as error:
                print(f"warning: could not restore the engine service: {error}", file=sys.stderr)

        if (
            ids is not None
            and service_active(GATEWAY_SERVICE)
            and service_active(ENGINE_SERVICE)
        ):
            try:
                cleanup_test_data(int(ids["user_id"]), int(ids["connection_id"]))
            except Exception as error:
                print(f"warning: could not remove acceptance records: {error}", file=sys.stderr)

        if not succeeded and irc_started and docker_object_exists("container", IRC_CONTAINER):
            logs = run(
                ["docker", "logs", "--tail", "100", IRC_CONTAINER],
                capture=True,
                check=False,
            )
            if logs.stdout or logs.stderr:
                print("Synthetic IRC diagnostics:", file=sys.stderr)
                print((logs.stdout + logs.stderr).strip(), file=sys.stderr)
        remove_irc_container()
