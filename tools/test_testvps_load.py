import os
import shutil
import socket
import subprocess
import sys
import time
import unittest
from pathlib import Path
from unittest import mock


TOOLS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS_DIR))

import testvps  # noqa: E402
import testvps_load  # noqa: E402


class TestVpsLimitsTest(unittest.TestCase):
    @mock.patch.object(testvps, "output")
    @mock.patch.object(testvps, "run")
    @mock.patch.object(testvps, "docker_object_exists", return_value=True)
    def test_runtime_limits_disable_swap_at_the_two_gibibyte_limit(
        self,
        _exists_mock: mock.Mock,
        run_mock: mock.Mock,
        output_mock: mock.Mock,
    ) -> None:
        output_mock.return_value = (
            f"{testvps.VPS_MEMORY_BYTES} {testvps.VPS_MEMORY_BYTES}"
        )

        testvps.VpsCommands().runtime_limits()

        self.assertEqual(
            run_mock.call_args.args[0],
            [
                "docker",
                "update",
                "--memory",
                str(2 * 1024**3),
                "--memory-swap",
                str(2 * 1024**3),
                testvps.VPS_CONTAINER,
            ],
        )

    @mock.patch.object(testvps, "output")
    @mock.patch.object(testvps, "run")
    @mock.patch.object(testvps, "docker_object_exists", return_value=True)
    def test_build_limits_restore_exactly_four_gibibytes_of_extra_swap(
        self,
        _exists_mock: mock.Mock,
        run_mock: mock.Mock,
        output_mock: mock.Mock,
    ) -> None:
        output_mock.return_value = (
            f"{testvps.VPS_MEMORY_BYTES} {testvps.VPS_BUILD_MEMORY_SWAP_BYTES}"
        )

        testvps.VpsCommands().build_limits()

        command = run_mock.call_args.args[0]
        self.assertEqual(command[3], str(2 * 1024**3))
        self.assertEqual(command[5], str(6 * 1024**3))


class TestVpsLoadExpressionTest(unittest.TestCase):
    def test_counts_are_strictly_increasing(self) -> None:
        self.assertEqual(testvps_load.parse_counts("100,500,1_000"), [100, 500, 1_000])
        with self.assertRaisesRegex(ValueError, "strictly increasing"):
            testvps_load.parse_counts("100,100")
        with self.assertRaisesRegex(ValueError, "strictly increasing"):
            testvps_load.parse_counts("500,100")

    def test_provisioning_is_bounded_and_pins_the_local_irc_sidecar(self) -> None:
        expression = testvps_load.provision_expression("safe-run", 1, 100, 10)

        self.assertIn('"host" => "topics-club-vps-irc"', expression)
        self.assertIn('"port" => 6667', expression)
        self.assertIn('"use_tls" => false', expression)
        self.assertIn("TopicsClub.EngineClient.ensure_connection", expression)
        self.assertIn("max_concurrency: 10", expression)

        with self.assertRaisesRegex(ValueError, "at most 100"):
            testvps_load.provision_expression("safe-run", 1, 101, 10)
        with self.assertRaisesRegex(ValueError, "may not exceed 25"):
            testvps_load.provision_expression("safe-run", 1, 100, 26)

    def test_cleanup_uses_the_engine_connection_lifecycle_before_user_deletion(self) -> None:
        expression = testvps_load.cleanup_expression("safe-run", 100, 10)

        lifecycle = expression.index("TopicsClub.EngineClient.delete_connection")
        user_delete = expression.index("TopicsClub.Repo.delete_all()")
        self.assertLess(lifecycle, user_delete)
        self.assertIn("remaining == 0", expression)

    def test_run_ids_cannot_change_the_email_query_or_elixir_expression(self) -> None:
        for invalid in ("UPPER", "has space", "percent%", 'quote"'):
            with self.subTest(invalid=invalid):
                with self.assertRaises(ValueError):
                    testvps_load.stats_expression(invalid)

    @mock.patch.object(testvps_load, "output")
    def test_deployed_release_manifest_is_recorded_and_validated(
        self, output_mock: mock.Mock
    ) -> None:
        output_mock.return_value = (
            "tag=20260901.1\n"
            f"commit={'a' * 40}\n"
            "release=topics_club_gateway"
        )

        manifest = testvps_load.release_manifest("gateway")

        self.assertEqual(manifest["tag"], "20260901.1")
        self.assertEqual(manifest["commit"], "a" * 40)
        with self.assertRaises(ValueError):
            testvps_load.release_manifest("unknown")

    def test_capacity_summary_uses_cgroup_peak_and_rejects_service_restarts(self) -> None:
        baseline = {"gateway": 0, "wirekeeper": 0, "engine": 0}
        sample = {
            "cgroup": {"memory_current": 100, "memory_peak": 200},
            "services": {
                "gateway": {"NRestarts": 0},
                "wirekeeper": {"NRestarts": 0},
                "engine": {"NRestarts": 1},
            },
        }

        summary = testvps_load.scenario_summary(100, True, [sample], baseline)

        self.assertEqual(summary["peak_memory_bytes"], 200)
        self.assertFalse(summary["functional_success"])
        self.assertFalse(summary["planning_success"])


class SyntheticIrcConfigurationTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which("elixir"), "Elixir is required for the IRC harness test")
    def test_named_environment_variables_override_both_listener_ports(self) -> None:
        irc_port = self._unused_port()
        control_port = self._unused_port()
        while control_port == irc_port:
            control_port = self._unused_port()

        environment = {
            **os.environ,
            "IRC_PORT": str(irc_port),
            "CONTROL_PORT": str(control_port),
        }
        process = subprocess.Popen(
            ["elixir", str(TOOLS_DIR / "load_test" / "irc_server.exs")],
            cwd=TOOLS_DIR.parent,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    output = process.stdout.read() if process.stdout else ""
                    self.fail(f"synthetic IRC server exited early: {output}")
                try:
                    with socket.create_connection(("127.0.0.1", control_port), timeout=0.5) as client:
                        client.sendall(b"PING\n")
                        self.assertEqual(client.recv(32), b"PONG\n")
                    with socket.create_connection(("127.0.0.1", irc_port), timeout=0.5):
                        return
                except OSError:
                    time.sleep(0.1)
            self.fail("synthetic IRC server did not bind the configured ports")
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            if process.stdout:
                process.stdout.close()

    @staticmethod
    def _unused_port() -> int:
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            return listener.getsockname()[1]


if __name__ == "__main__":
    unittest.main()
