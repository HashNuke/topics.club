import base64
import contextlib
import io
import json
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parent))

import apptools  # noqa: E402
import split_acceptance  # noqa: E402
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
    def test_pseudo_vps_credentials_key_is_standard_base64(self) -> None:
        encoded = testvps.base64_secret()

        self.assertEqual(len(base64.b64decode(encoded, validate=True)), 32)

    def test_acceptance_control_fields_are_strict_integers(self) -> None:
        self.assertEqual(
            split_acceptance.parse_fields("active=1 registered=1"),
            {"active": 1, "registered": 1},
        )
        self.assertEqual(split_acceptance.parse_fields("active=unknown"), {})

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


def onepassword_document(values: dict[tuple[str, str], str]) -> dict[str, object]:
    field_types = dict(apptools.GENERATED_ONEPASSWORD_FIELDS)
    for key in apptools.COPIED_ONEPASSWORD_FIELDS:
        field_types.setdefault(key, "text")
    field_types[("gateway", "GOOGLE_CLIENT_SECRET")] = "password"

    return {
        "id": "item-id",
        "title": "topics-club-prod",
        "category": "SECURE_NOTE",
        "vault": {"id": "vault-id"},
        "sections": [
            {"id": "shared-id", "label": "shared"},
            {"id": "gateway-id", "label": "gateway"},
        ],
        "fields": [
            {
                "id": label.lower(),
                "label": label,
                "type": "CONCEALED" if field_type == "password" else "STRING",
                "value": values.get((section, label), ""),
                "section": {"id": f"{section}-id"},
            }
            for (section, label), field_type in field_types.items()
        ],
    }


class OnePasswordSecretsTest(unittest.TestCase):
    @mock.patch.object(apptools.subprocess, "run")
    @mock.patch.object(apptools, "clipboard_command", return_value=["pbcopy"])
    @mock.patch.object(apptools, "onepassword_item")
    def test_copies_complete_dotenv_to_clipboard_through_stdin(
        self,
        item_mock: mock.Mock,
        _clipboard_mock: mock.Mock,
        subprocess_mock: mock.Mock,
    ) -> None:
        values = {
            key: f"value-{index}"
            for index, key in enumerate(apptools.COPIED_ONEPASSWORD_FIELDS)
        }
        item_mock.return_value = onepassword_document(values)

        apptools.copy_onepassword_secrets("app-secrets", "topics-club-prod")

        self.assertEqual(subprocess_mock.call_args.args[0], ["pbcopy"])
        contents = subprocess_mock.call_args.kwargs["input"]
        self.assertIn("IRC_CREDENTIALS_KEY=value-0\n", contents)
        self.assertIn("VAPID_SUBJECT=value-8\n", contents)
        self.assertTrue(contents.endswith("ENABLE_DISCOVERY=false\n"))
        self.assertNotIn("value-0", subprocess_mock.call_args.args[0])

    @mock.patch.object(apptools, "onepassword_item")
    def test_copy_refuses_an_incomplete_secret_note(self, item_mock: mock.Mock) -> None:
        item_mock.return_value = onepassword_document({})

        with self.assertRaisesRegex(RuntimeError, "fields are missing or empty"):
            apptools.onepassword_dotenv("app-secrets", "topics-club-prod")

    def test_dotenv_quotes_and_escapes_unsafe_values(self) -> None:
        self.assertEqual(apptools.dotenv_value("safe-Value_1=", "field"), "safe-Value_1=")
        self.assertEqual(apptools.dotenv_value("value with #", "field"), '"value with #"')
        self.assertEqual(
            apptools.dotenv_value('a\\b"c', "field"),
            '"a\\\\b\\"c"',
        )

    @mock.patch.object(apptools, "generate_onepassword_secrets", return_value=[])
    def test_create_secrets_selects_the_item_from_the_environment(
        self,
        generate_mock: mock.Mock,
    ) -> None:
        with contextlib.redirect_stdout(io.StringIO()):
            apptools.AppTools().create_secrets(env="prod")
        generate_mock.assert_called_once_with("app-secrets", "topics-club-prod")

        with self.assertRaisesRegex(ValueError, "env must be dev or prod"):
            apptools.AppTools().create_secrets(env="staging")

    @mock.patch.object(apptools, "vapid_keypair", return_value=("public-new", "private-new"))
    @mock.patch.object(apptools.subprocess, "run")
    @mock.patch.object(apptools, "onepassword_item")
    def test_generates_only_empty_fields_without_putting_values_in_arguments(
        self,
        item_mock: mock.Mock,
        subprocess_mock: mock.Mock,
        _vapid_mock: mock.Mock,
    ) -> None:
        item_mock.return_value = onepassword_document(
            {
                ("shared", "IRC_CREDENTIALS_KEY"): "existing-key",
                ("gateway", "SECRET_KEY_BASE"): "existing-secret",
            }
        )

        generated = apptools.generate_onepassword_secrets(
            "app-secrets", "topics-club-prod"
        )

        self.assertEqual(
            generated,
            [
                "shared.RELEASE_COOKIE",
                "gateway.VAPID_PUBLIC_KEY",
                "gateway.VAPID_PRIVATE_KEY",
            ],
        )
        command = subprocess_mock.call_args.args[0]
        self.assertEqual(
            command,
            [
                "op",
                "item",
                "edit",
                "topics-club-prod",
                "--vault",
                "app-secrets",
            ],
        )
        submitted = json.loads(subprocess_mock.call_args.kwargs["input"])
        submitted_fields = apptools.onepassword_fields(submitted)
        self.assertEqual(
            submitted_fields[("shared", "IRC_CREDENTIALS_KEY")]["value"],
            "existing-key",
        )
        self.assertEqual(
            submitted_fields[("gateway", "SECRET_KEY_BASE")]["value"],
            "existing-secret",
        )

    @mock.patch.object(apptools.subprocess, "run")
    @mock.patch.object(apptools, "onepassword_item")
    def test_refuses_to_replace_half_of_an_existing_vapid_pair(
        self,
        item_mock: mock.Mock,
        subprocess_mock: mock.Mock,
    ) -> None:
        item_mock.return_value = onepassword_document(
            {("gateway", "VAPID_PUBLIC_KEY"): "existing-public"}
        )

        with self.assertRaisesRegex(RuntimeError, "must both be empty"):
            apptools.generate_onepassword_secrets("app-secrets", "topics-club-prod")

        subprocess_mock.assert_not_called()

    @mock.patch.object(apptools, "vapid_keypair", return_value=("public-new", "private-new"))
    @mock.patch.object(apptools.subprocess, "run")
    @mock.patch.object(apptools, "run")
    @mock.patch.object(apptools, "onepassword_item")
    def test_creates_missing_fields_with_empty_assignments_before_populating(
        self,
        item_mock: mock.Mock,
        run_mock: mock.Mock,
        _subprocess_mock: mock.Mock,
        _vapid_mock: mock.Mock,
    ) -> None:
        empty_item = onepassword_document({})
        empty_item["fields"] = []
        item_mock.side_effect = [empty_item, onepassword_document({})]

        apptools.generate_onepassword_secrets("app-secrets", "topics-club-prod")

        field_command = run_mock.call_args.args[0]
        self.assertEqual(len(field_command[6:]), 5)
        self.assertTrue(all(argument.endswith("=") for argument in field_command[6:]))
        self.assertNotIn("public-new", field_command)
        self.assertNotIn("private-new", field_command)


class DeploySelectionTest(unittest.TestCase):
    @mock.patch.object(apptools, "run")
    def test_database_provisioning_uses_the_dedicated_pyinfra_deploy(
        self,
        run_mock: mock.Mock,
    ) -> None:
        apptools.AppTools().provision_db(host="root@db.example.test")

        command = run_mock.call_args.args[0]
        self.assertEqual(command[-2], "db.example.test")
        self.assertTrue(command[-1].endswith("/tools/deploy/database.py"))

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
