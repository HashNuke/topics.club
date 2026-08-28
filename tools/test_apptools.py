import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parent))

import apptools  # noqa: E402
import testvps  # noqa: E402


class ReleaseTagTest(unittest.TestCase):
    def test_release_tags_sort_by_numeric_sequence(self) -> None:
        self.assertGreater(
            apptools.release_tag_key("20260828.10"),
            apptools.release_tag_key("20260828.9"),
        )

    def test_fire_arguments_preserve_release_tags_as_strings(self) -> None:
        self.assertEqual(
            apptools.preserve_release_tag_arguments(
                ["deploy", "gateway", "--tag", "20260828.10"]
            ),
            ["deploy", "gateway", "--tag", '"20260828.10"'],
        )
        self.assertEqual(
            apptools.preserve_release_tag_arguments(
                ["deploy", "--tag=20260828.10"]
            ),
            ["deploy", '--tag="20260828.10"'],
        )

    @mock.patch.object(apptools, "remote_release_tags")
    @mock.patch.object(apptools.subprocess, "run")
    def test_latest_resolves_to_the_highest_remote_release_tag(
        self,
        run_mock: mock.Mock,
        remote_tags_mock: mock.Mock,
    ) -> None:
        older = "a" * 40
        latest = "b" * 40
        remote_tags_mock.return_value = {
            "20260828.9": older,
            "20260828.10": latest,
            "not-a-release": "c" * 40,
        }
        run_mock.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=f"{latest}\n"
        )

        self.assertEqual(
            apptools.resolve_release_tag("latest"),
            ("20260828.10", latest),
        )

    @mock.patch.object(
        apptools,
        "remote_release_tags",
        return_value={"20260828.1": "a" * 40},
    )
    @mock.patch.object(apptools.subprocess, "run")
    def test_local_release_tag_must_match_origin(
        self,
        run_mock: mock.Mock,
        _remote_tags_mock: mock.Mock,
    ) -> None:
        run_mock.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=f"{'b' * 40}\n"
        )

        with self.assertRaisesRegex(RuntimeError, "local and origin"):
            apptools.resolve_release_tag("20260828.1")


class ValidationTest(unittest.TestCase):
    def test_only_one_ssh_host_is_accepted(self) -> None:
        with self.assertRaisesRegex(ValueError, "exactly one"):
            apptools.split_host("root@one,root@two", None, None)

    def test_pseudo_vps_defaults_do_not_rename_target_resources(self) -> None:
        host, user, port, key = apptools.split_host("root@127.0.0.1", None, None)

        self.assertEqual((host, user, port), ("127.0.0.1", "root", 45_122))
        self.assertEqual(key, str(apptools.PRIVATE_KEY))
        self.assertEqual(testvps.STATE_DIR.name, "vps")
        self.assertEqual(testvps.VPS_CONTAINER, "topics-club-vps")
        self.assertIsInstance(apptools.AppTools.testvps, testvps.VpsCommands)

    def test_repository_rejects_credentials_and_non_https_remotes(self) -> None:
        apptools.validate_repository("https://github.com/HashNuke/topics.club.git")
        apptools.validate_repository("file:///mnt/topics-club.git")

        for repository in [
            "git@github.com:HashNuke/topics.club.git",
            "https://user:secret@example.com/topics.club.git",
            "https://example.com/topics.club.git?token=secret",
        ]:
            with self.subTest(repository=repository):
                with self.assertRaises(ValueError):
                    apptools.validate_repository(repository)

    def test_health_url_must_use_loopback_http(self) -> None:
        apptools.validate_health_url("http://127.0.0.1:4000/health")

        for health_url in [
            "https://127.0.0.1:4000/health",
            "http://localhost:4000/health",
            "http://127.0.0.1:70000/health",
            "http://127.0.0.1:4000/health#fragment",
        ]:
            with self.subTest(health_url=health_url):
                with self.assertRaises(ValueError):
                    apptools.validate_health_url(health_url)


class DeploySelectionTest(unittest.TestCase):
    @mock.patch.object(apptools, "resolve_release_tag", return_value=("20260828.1", "d" * 40))
    @mock.patch.object(apptools, "run")
    def test_combined_command_deploys_gateway_then_engine(
        self,
        run_mock: mock.Mock,
        _resolve_mock: mock.Mock,
    ) -> None:
        apptools.AppTools().deploy()

        components = [
            next(argument for argument in call.args[0] if argument.startswith("component="))
            for call in run_mock.call_args_list
        ]
        self.assertEqual(components, ['component="gateway"', 'component="engine"'])

    @mock.patch.object(apptools, "resolve_release_tag", return_value=("20260828.1", "d" * 40))
    @mock.patch.object(apptools, "run")
    def test_component_command_selects_only_that_component(
        self,
        run_mock: mock.Mock,
        _resolve_mock: mock.Mock,
    ) -> None:
        apptools.AppTools().deploy("gateway")

        self.assertEqual(run_mock.call_count, 1)
        self.assertIn('component="gateway"', run_mock.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
