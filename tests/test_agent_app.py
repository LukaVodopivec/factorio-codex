from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
AGENT_APP = ROOT / "scripts" / "agent-app"


def load_agent_app():
    loader = SourceFileLoader("factorio_repo_agent_app", str(AGENT_APP))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def run_app(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(AGENT_APP), *arguments],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


class AgentAppContractTests(unittest.TestCase):
    def git(self, repository: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", "-C", str(repository), *arguments],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )

    def test_describe_declares_v2_scheduled_safe_quick_evidence(self) -> None:
        completed = run_app("describe", "--json")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(len(completed.stdout.splitlines()), 1)
        self.assertLess(len(completed.stdout), 32_768)
        payload = json.loads(completed.stdout)
        self.assertEqual(payload["schema"], "repo-agent-app-describe/v2")
        self.assertEqual(payload["resource_identity"], "factorio-codex")
        self.assertEqual(set(payload["profiles"]), {"focused", "quick", "full"})
        quick = payload["profiles"]["quick"]
        self.assertIs(quick["scheduled_safe"], True)
        self.assertEqual(quick["evidence_tier"], "readiness")
        self.assertEqual(
            quick["evidence_classes"],
            [
                "typescript-typecheck",
                "companion-unit-tests",
                "mod-lua-tests",
                "offline-mcp-smoke",
            ],
        )
        self.assertIn("live Factorio game and native client behavior", quick["not_exercised"])
        self.assertIn("live RCON, MCP clients, and network services", quick["not_exercised"])

    def test_describe_and_doctor_are_bounded_and_read_only(self) -> None:
        before = subprocess.run(
            ["git", "status", "--porcelain=v1", "--untracked-files=all"],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=True,
        ).stdout

        describe = run_app("describe", "--json")
        doctor = run_app("doctor", "--json")

        after = subprocess.run(
            ["git", "status", "--porcelain=v1", "--untracked-files=all"],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=True,
        ).stdout
        self.assertEqual(describe.returncode, 0, describe.stderr)
        self.assertIn(doctor.returncode, {0, 1}, doctor.stderr)
        self.assertEqual(len(doctor.stdout.splitlines()), 1)
        self.assertLess(len(doctor.stdout), 32_768)
        self.assertEqual(json.loads(doctor.stdout)["schema"], "repo-agent-app-doctor/v2")
        self.assertEqual(before, after)

    def test_profiles_use_only_the_declared_offline_commands(self) -> None:
        app = load_agent_app()
        self.assertEqual(
            app.PROFILE_COMMANDS["quick"],
            [
                ["npm", "run", "typecheck"],
                ["npm", "run", "test:unit"],
                ["npm", "run", "test:mod"],
                ["npm", "run", "test:mcp"],
            ],
        )
        self.assertEqual(
            app.PROFILE_COMMANDS["full"],
            [
                ["python3", "-m", "unittest", "tests/test_agent_app.py"],
                ["npm", "ls", "--all"],
                *app.PROFILE_COMMANDS["quick"],
                ["npm", "run", "test:mcp:readonly", "-w", "companion"],
                ["npm", "run", "build"],
                ["npm", "run", "test:mcp:built", "-w", "companion"],
                ["npm", "run", "test:package"],
            ],
        )

    def test_quick_executes_all_commands_from_prepared_snapshot(self) -> None:
        app = load_agent_app()
        prepared = ROOT / "prepared-snapshot"
        npm = (["/node", "/npm-cli.js"], Path("/npm-bin"))
        with (
            mock.patch.object(app, "resolve_native_root", return_value=ROOT),
            mock.patch.object(app, "resolve_npm_command", return_value=npm),
            mock.patch.object(app, "prepare_workspace", return_value=prepared),
            mock.patch.object(app, "execute_command", return_value=0) as execute,
        ):
            payload, code = app.verify_payload("quick", None)

        self.assertEqual(code, 0)
        self.assertEqual(payload["status"], "pass")
        self.assertEqual(
            [call.args[0] for call in execute.call_args_list],
            [[*npm[0], *command[1:]] for command in app.PROFILE_COMMANDS["quick"]],
        )
        self.assertEqual([call.args[2] for call in execute.call_args_list], [prepared] * 4)
        for call in execute.call_args_list:
            environment = call.args[1]
            self.assertEqual(environment["npm_config_offline"], "true")
            self.assertEqual(environment["MCP_SMOKE_OFFLINE"], "1")
            self.assertEqual(environment["PYTHONDONTWRITEBYTECODE"], "1")
            self.assertTrue(Path(environment["HOME"]).is_relative_to(Path(environment["TMPDIR"]).parent))

    def test_full_routes_checkout_checks_and_propagates_failures(self) -> None:
        app = load_agent_app()
        owner = ROOT / "owning-checkout"
        prepared = ROOT / "prepared-snapshot"
        npm = (["/node", "/npm-cli.js"], Path("/npm-bin"))
        for failing_index in (None, 0, 1):
            with self.subTest(failing_index=failing_index):
                exits = [0] * len(app.PROFILE_COMMANDS["full"])
                if failing_index is not None:
                    exits[failing_index] = 1
                with (
                    mock.patch.object(app, "resolve_native_root", return_value=owner),
                    mock.patch.object(app, "resolve_npm_command", return_value=npm),
                    mock.patch.object(app, "prepare_workspace", return_value=prepared) as prepare,
                    mock.patch.object(app, "execute_command", side_effect=exits) as execute,
                ):
                    payload, code = app.verify_payload("full", None)
                prepare.assert_called_once()
                self.assertEqual([call.args[2] for call in execute.call_args_list],
                                 [ROOT, owner, *([prepared] * 8)])
                self.assertEqual([call.args[0] for call in execute.call_args_list],
                                 [[*npm[0], *command[1:]] if command[0] == "npm" else command
                                  for command in app.PROFILE_COMMANDS["full"]])
                self.assertEqual(code, 0 if failing_index is None else 1)
                self.assertEqual(payload["status"], "pass" if failing_index is None else "fail")
                self.assertEqual(len(payload["checks"]), 10)
                for index, check in enumerate(payload["checks"]):
                    self.assertEqual(check["status"], "fail" if index == failing_index else "pass")

    def test_prepared_workspace_uses_exact_owner_deps_and_snapshot_source(self) -> None:
        app = load_agent_app()
        with tempfile.TemporaryDirectory() as temporary_name:
            temporary = Path(temporary_name)
            owner = temporary / "owner"
            snapshot = temporary / "snapshot"
            prepared = temporary / "prepared"
            (owner / "scripts").mkdir(parents=True)
            (owner / "companion").mkdir()
            (owner / "node_modules" / ".bin").mkdir(parents=True)
            for relative, contents in {
                "package.json": '{"name":"fixture"}\n',
                "package-lock.json": '{"lockfileVersion":3}\n',
                "companion/source.txt": "snapshot source\n",
                "scripts/agent-app": "fixture\n",
            }.items():
                path = owner / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents, encoding="utf-8")
            for executable in app.REQUIRED_DEPENDENCY_EXECUTABLES:
                path = owner / "node_modules" / ".bin" / executable
                path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                path.chmod(0o755)
            (owner / "node_modules" / "dependency").mkdir()
            (owner / "node_modules" / "dependency" / "marker").write_text("owner dep\n")
            (owner / "node_modules" / "factorio-codex").symlink_to("../companion")
            self.git(owner, "init", "-q", "--initial-branch=main")
            self.git(owner, "add", "package.json", "package-lock.json", "companion", "scripts")
            self.git(
                owner,
                "-c",
                "user.name=Agent App Test",
                "-c",
                "user.email=agent-app@example.invalid",
                "commit",
                "-qm",
                "fixture",
            )
            self.git(owner, "worktree", "add", "--quiet", "--detach", str(snapshot), "HEAD")
            (owner / "companion" / "source.txt").write_text("owner source\n", encoding="utf-8")
            prepared.mkdir()

            with mock.patch.object(app, "ROOT", snapshot):
                native = app.resolve_native_root()
                workspace = app.prepare_workspace(prepared, native)

            self.assertEqual(native, owner.resolve())
            self.assertEqual((workspace / "companion" / "source.txt").read_text(), "snapshot source\n")
            self.assertEqual((workspace / "node_modules" / "dependency" / "marker").read_text(), "owner dep\n")
            self.assertEqual(
                (workspace / "node_modules" / "factorio-codex").resolve(),
                (workspace / "companion").resolve(),
            )
            self.assertFalse((snapshot / "node_modules").exists())
            self.assertEqual(self.git(snapshot, "status", "--porcelain=v1").stdout, "")

    def test_each_dependency_descriptor_mismatch_blocks_reuse(self) -> None:
        app = load_agent_app()
        with tempfile.TemporaryDirectory() as temporary_name:
            temporary = Path(temporary_name)
            snapshot = temporary / "snapshot"
            owner = temporary / "owner"
            snapshot.mkdir()
            owner.mkdir()
            for relative in app.DEPENDENCY_DESCRIPTORS:
                (snapshot / relative).write_text("same\n", encoding="utf-8")
                (owner / relative).write_text("same\n", encoding="utf-8")
            with mock.patch.object(app, "ROOT", snapshot):
                self.assertTrue(app.dependency_descriptors_match(owner)[0])
                for relative in app.DEPENDENCY_DESCRIPTORS:
                    with self.subTest(relative=relative):
                        (owner / relative).write_text("different\n", encoding="utf-8")
                        matched, evidence = app.dependency_descriptors_match(owner)
                        self.assertFalse(matched)
                        self.assertIn(f"{relative}:missing-or-mismatch", evidence)
                        (owner / relative).write_text("same\n", encoding="utf-8")

    def test_targeted_verification_is_rejected_without_running_checks(self) -> None:
        for profile in ("focused", "quick", "full"):
            with self.subTest(profile=profile):
                completed = run_app("verify", "--profile", profile, "--target", "README.md")
                self.assertEqual(completed.returncode, 2, completed.stderr)
                payload = json.loads(completed.stdout)
                self.assertEqual(payload["status"], "fail")
                self.assertEqual(payload["checks"][0]["id"], "target")
        for target in ("missing", str(ROOT), "../outside"):
            with self.subTest(target=target):
                completed = run_app("verify", "--profile", "quick", "--target", target)
                self.assertEqual(completed.returncode, 2, completed.stderr)

    def test_doctor_skips_dependency_execution_on_descriptor_mismatch(self) -> None:
        app = load_agent_app()
        with tempfile.TemporaryDirectory() as temporary_name:
            snapshot = Path(temporary_name) / "snapshot"
            owner = Path(temporary_name) / "owner"
            snapshot.mkdir()
            owner.mkdir()
            for relative in app.DEPENDENCY_DESCRIPTORS:
                (snapshot / relative).write_text("snapshot\n", encoding="utf-8")
                (owner / relative).write_text("owner\n", encoding="utf-8")
            with (
                mock.patch.object(app, "ROOT", snapshot),
                mock.patch.object(app, "resolve_native_root", return_value=owner),
                mock.patch.object(app, "resolve_npm_command", return_value=None),
                mock.patch.object(app.shutil, "which", return_value=None),
            ):
                payload = app.doctor_payload()

        findings = {item["id"]: item for item in payload["checks"]}
        self.assertEqual(payload["status"], "fail")
        self.assertEqual(findings["dependency-descriptors"]["status"], "fail")
        self.assertEqual(findings["owner-node-dependencies"]["status"], "fail")

    def test_doctor_uses_the_sealed_verification_path(self) -> None:
        app = load_agent_app()
        seen_paths: list[str | None] = []

        def which(_command: str, *, path: str | None = None) -> None:
            seen_paths.append(path)
            return None

        with (
            mock.patch.object(app, "resolve_native_root", return_value=None),
            mock.patch.object(app, "resolve_npm_command", return_value=None),
            mock.patch.object(app.shutil, "which", side_effect=which),
        ):
            app.doctor_payload()

        self.assertTrue(seen_paths)
        self.assertEqual(set(seen_paths), {app.VERIFICATION_BASE_PATH})

    def test_cleanup_waits_for_descendants_after_group_leader_exits(self) -> None:
        app = load_agent_app()
        process = mock.Mock(pid=1234)
        process.wait.return_value = 143
        with (
            mock.patch.object(
                app.os,
                "killpg",
                side_effect=[None, None, None, ProcessLookupError],
            ) as kill_group,
            mock.patch.object(app.time, "sleep") as pause,
        ):
            cleaned = app.terminate_process_group(process)

        self.assertTrue(cleaned)
        self.assertEqual(
            kill_group.call_args_list,
            [
                mock.call(1234, app.signal.SIGTERM),
                mock.call(1234, 0),
                mock.call(1234, 0),
                mock.call(1234, 0),
            ],
        )
        self.assertEqual(pause.call_count, 2)

    def test_cleanup_kills_a_process_group_that_survives_the_grace_period(self) -> None:
        app = load_agent_app()
        process = mock.Mock(pid=1234)
        process.wait.return_value = 143
        with (
            mock.patch.object(
                app.os,
                "killpg",
                side_effect=[None, None, None, ProcessLookupError],
            ) as kill_group,
            mock.patch.object(app.time, "monotonic", side_effect=[0, 31, 31]),
        ):
            cleaned = app.terminate_process_group(process)

        self.assertTrue(cleaned)
        self.assertEqual(
            kill_group.call_args_list,
            [
                mock.call(1234, app.signal.SIGTERM),
                mock.call(1234, 0),
                mock.call(1234, app.signal.SIGKILL),
                mock.call(1234, 0),
            ],
        )
        self.assertEqual(process.wait.call_count, 2)

    def test_cleanup_reports_a_process_group_that_survives_sigkill(self) -> None:
        app = load_agent_app()
        process = mock.Mock(pid=1234)
        process.wait.return_value = 143
        with (
            mock.patch.object(app.os, "killpg"),
            mock.patch.object(app.time, "monotonic", side_effect=[0, 31, 31, 37]),
        ):
            cleaned = app.terminate_process_group(process)

        self.assertFalse(cleaned)

    def test_cleanup_bounds_a_leader_that_survives_sigkill(self) -> None:
        app = load_agent_app()
        process = mock.Mock(pid=1234)
        process.wait.side_effect = [
            subprocess.TimeoutExpired(["command"], 30),
            subprocess.TimeoutExpired(["command"], 5),
        ]
        with (
            mock.patch.object(app.os, "killpg"),
            mock.patch.object(app.time, "monotonic", side_effect=[0, 31, 31, 37]),
        ):
            cleaned = app.terminate_process_group(process)

        self.assertFalse(cleaned)
        self.assertEqual(
            [call.kwargs["timeout"] for call in process.wait.call_args_list],
            [30, 5],
        )

    def test_npm_resolution_requires_npx_on_the_verification_path(self) -> None:
        app = load_agent_app()
        with tempfile.TemporaryDirectory() as temporary_name:
            binary_directory = Path(temporary_name)
            for name in ("node", "npm", "npx"):
                executable = binary_directory / name
                executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                executable.chmod(0o755)
            with (
                mock.patch.object(app, "VERIFICATION_BASE_PATH", str(binary_directory)),
                mock.patch.object(app, "node_is_version_22", return_value=True),
            ):
                self.assertIsNotNone(app.resolve_npm_command())
                (binary_directory / "npx").unlink()
                self.assertIsNone(app.resolve_npm_command())


if __name__ == "__main__":
    unittest.main()
