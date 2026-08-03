from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from run_acceptance import (
    AcceptanceRunError,
    EffectiveScenarioCounts,
    ExclusiveRunDirectory,
    RuntimePrerequisiteLease,
    _expected_prerequisite_container,
    _finish_prerequisite_process,
    _parse_prerequisite_ready,
    _redact_database_urls,
    _remove_prerequisite_container,
    _validate_prerequisite_container,
    archive_override_is_complete,
    automatic_run_id,
    ensure_external_directory,
    ensure_evidence_file,
    effective_scenario_counts,
    git_binding,
    git_head,
    prepare_evidence_directory,
    source_inventory_without_evidence,
    validate_extraction_receipt_artifacts,
    validate_extraction_receipt_shape,
    validate_verified_extraction_receipt,
)


ROOT = Path(__file__).resolve().parents[2]


class AcceptanceMutationBoundaryTests(unittest.TestCase):
    def test_r6e_lease_environment_is_role_scoped_and_url_redacted(self) -> None:
        lease = RuntimePrerequisiteLease(
            process=None,
            scenario_id="AC-BUSINESS_MODEL-047",
            host="127.0.0.1",
            port=55432,
            database="gurine_r6e_monetization",
            container="gurine-r6e-monetization-123",
        )
        environment = lease.child_environment(
            {"TEST_DATABASE_URL": "postgresql://stale.invalid/db"}
        )
        self.assertIn("BILLING_DATABASE_URL", environment)
        self.assertIn("PROJECTOR_DATABASE_URL", environment)
        self.assertNotIn("ECONOMICS_DATABASE_URL", environment)
        self.assertNotIn("TEST_DATABASE_URL", environment)
        self.assertIn("gurine_control_api", environment["GURINNAE_DATABASE_URL"])
        output = (
            f"before {environment['BILLING_DATABASE_URL']} after"
        ).encode("utf-8")
        redacted = _redact_database_urls(output, environment)
        self.assertNotIn(b"postgresql://", redacted)
        self.assertIn(b"[REDACTED_DATABASE_URL]", redacted)

    def test_r6e_ready_response_is_closed_and_scenario_bound(self) -> None:
        payload = (
            b'{"container":"gurine-r6e-monetization-123",'
            b'"database":"gurine_r6e_monetization","host":"127.0.0.1",'
            b'"port":55432,"scenario_id":"AC-BUSINESS_MODEL-042",'
            b'"schema_version":1,"status":"READY"}'
        )
        parsed = _parse_prerequisite_ready(payload, "AC-BUSINESS_MODEL-042")
        self.assertEqual(parsed["port"], 55432)
        with self.assertRaisesRegex(AcceptanceRunError, "identity differs"):
            _parse_prerequisite_ready(payload, "AC-BUSINESS_MODEL-043")
        with self.assertRaisesRegex(AcceptanceRunError, "keys differ"):
            _parse_prerequisite_ready(payload[:-1] + b',"url":"secret"}', "AC-BUSINESS_MODEL-042")

    def test_r6e_ready_container_is_exactly_child_pid_derived(self) -> None:
        class Process:
            pid = 123

        ready = {
            "container": "gurine-r6e-monetization-123",
        }
        self.assertEqual(
            _expected_prerequisite_container(Process()),
            "gurine-r6e-monetization-123",
        )
        self.assertEqual(
            _validate_prerequisite_container(ready, Process()),
            "gurine-r6e-monetization-123",
        )
        ready["container"] = "gurine-r6e-monetization-124"
        with self.assertRaisesRegex(AcceptanceRunError, "container differs"):
            _validate_prerequisite_container(ready, Process())

    @patch("run_acceptance.subprocess.run")
    def test_r6e_container_finalizer_targets_only_exact_name(self, run: Mock) -> None:
        run.side_effect = [
            subprocess.CompletedProcess([], 1),
            subprocess.CompletedProcess([], 0, stdout=b""),
        ]
        container = "gurine-r6e-monetization-123"
        self.assertIsNone(_remove_prerequisite_container(container))
        remove_argv = run.call_args_list[0].args[0]
        inventory_argv = run.call_args_list[1].args[0]
        self.assertEqual(
            remove_argv,
            ["docker", "container", "rm", "--force", container],
        )
        self.assertEqual(inventory_argv[-2:], ["--filter", f"name=^/{container}$"])

    @patch("run_acceptance.subprocess.run")
    def test_r6e_container_finalizer_rejects_invalid_or_residual_target(
        self, run: Mock
    ) -> None:
        self.assertIsNotNone(_remove_prerequisite_container("other-container"))
        run.assert_not_called()
        run.side_effect = [
            subprocess.CompletedProcess([], 0),
            subprocess.CompletedProcess(
                [], 0, stdout=b"gurine-r6e-monetization-123\n"
            ),
        ]
        self.assertIsNotNone(
            _remove_prerequisite_container("gurine-r6e-monetization-123")
        )

    @patch("run_acceptance._remove_prerequisite_container", return_value=None)
    def test_cleanup_failure_overrides_success_only(self, remove: Mock) -> None:
        class FailedCleanup:
            returncode = 1

            @staticmethod
            def communicate(*, input: bytes | None = None, timeout: int | None = None):
                return b"", b"redacted"

        successful = RuntimePrerequisiteLease(
            FailedCleanup(),
            "AC-BUSINESS_MODEL-042",
            "127.0.0.1",
            55432,
            "gurine_r6e_monetization",
            "gurine-r6e-monetization-123",
        )
        with self.assertRaisesRegex(AcceptanceRunError, "cleanup failed"):
            successful.close(successful=True)

        already_failed = RuntimePrerequisiteLease(
            FailedCleanup(),
            "AC-BUSINESS_MODEL-042",
            "127.0.0.1",
            55432,
            "gurine_r6e_monetization",
            "gurine-r6e-monetization-124",
        )
        already_failed.close(successful=False)
        self.assertEqual(remove.call_count, 2)

    @patch("run_acceptance._remove_prerequisite_container", return_value=None)
    def test_cleanup_timeout_kills_child_and_runs_exact_finalizer(
        self, remove: Mock
    ) -> None:
        class TimedOutCleanup:
            pid = 123
            returncode = -9
            killed = False

            def communicate(
                self, *, input: bytes | None = None, timeout: int | None = None
            ) -> tuple[bytes, bytes]:
                if input is not None:
                    raise subprocess.TimeoutExpired("prerequisite", timeout)
                return b"", b""

            def kill(self) -> None:
                self.killed = True

        process = TimedOutCleanup()
        error = _finish_prerequisite_process(
            process,
            "AC-BUSINESS_MODEL-042",
            "gurine-r6e-monetization-123",
        )
        self.assertTrue(process.killed)
        self.assertIsNotNone(error)
        remove.assert_called_once_with("gurine-r6e-monetization-123")

    def test_runner_derives_effective_counts_from_registry_rows(self) -> None:
        base_count = 2
        supplemental_count = 3
        registry = {
            "counts": {
                "base_scenarios": base_count,
                "supplemental_scenarios": supplemental_count,
                "effective_scenarios": base_count + supplemental_count,
            },
            "scenarios": [
                *({"origin": "BASE_V13"} for _ in range(base_count)),
                *(
                    {"origin": "SUPPLEMENTAL_V1"}
                    for _ in range(supplemental_count)
                ),
            ],
        }
        self.assertEqual(
            effective_scenario_counts(registry),
            EffectiveScenarioCounts(
                base=base_count,
                supplemental=supplemental_count,
                effective=base_count + supplemental_count,
            ),
        )

    def test_runner_rejects_registry_count_mismatch(self) -> None:
        registry = {
            "counts": {
                "base_scenarios": 1,
                "supplemental_scenarios": 1,
                "effective_scenarios": 2,
            },
            "scenarios": [{"origin": "BASE_V13"}],
        }
        with self.assertRaisesRegex(AcceptanceRunError, "count mismatch"):
            effective_scenario_counts(registry)

    def test_acceptance_cli_exposes_defaults_without_required_release_flags(self) -> None:
        completed = subprocess.run(
            [sys.executable, "-B", "scripts/run_acceptance.py", "--help"],
            cwd=ROOT,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("<root>/artifacts/acceptance", completed.stdout)
        self.assertIn("default: current git HEAD", completed.stdout)
        self.assertIn("release archive override", completed.stdout)
        self.assertIn("receipt options", completed.stdout)

    def test_cli_has_no_free_command_or_assertion_count(self) -> None:
        completed = subprocess.run(
            [sys.executable, "-B", "scripts/run_acceptance_assertion_mutations.py", "--help"],
            cwd=ROOT,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("--scenario-id", completed.stdout)
        self.assertNotIn("--command", completed.stdout)
        self.assertNotIn("--assertion-count", completed.stdout)

    def test_run_directory_is_create_exclusive(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ExclusiveRunDirectory(root, "mutation-run-0001")
            with self.assertRaisesRegex(AcceptanceRunError, "already exists"):
                ExclusiveRunDirectory(root, "mutation-run-0001")

    def test_non_ignored_evidence_root_cannot_be_inside_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source"
            evidence = source / "evidence"
            evidence.mkdir(parents=True)
            subprocess.run(["git", "init", "--quiet", str(source)], check=True)
            with self.assertRaisesRegex(AcceptanceRunError, "Git-ignored"):
                ensure_external_directory(evidence, source)

    def test_git_ignored_evidence_root_and_receipt_are_allowed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source"
            evidence = source / "artifacts" / "acceptance"
            evidence.mkdir(parents=True)
            subprocess.run(["git", "init", "--quiet", str(source)], check=True)
            (source / ".gitignore").write_text("artifacts/\n", encoding="utf-8")
            receipt = evidence / "receipt.json"
            receipt.write_text("{}\n", encoding="utf-8")
            self.assertEqual(ensure_external_directory(evidence, source), evidence)
            self.assertEqual(
                ensure_evidence_file(receipt, source, "receipt"), receipt
            )

    def test_evidence_root_rejects_symlink_ancestor(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            source = base / "source"
            source.mkdir()
            subprocess.run(["git", "init", "--quiet", str(source)], check=True)
            (source / ".gitignore").write_text("artifacts/\n", encoding="utf-8")
            target = base / "target"
            (target / "acceptance").mkdir(parents=True)
            (source / "artifacts").symlink_to(target, target_is_directory=True)
            with self.assertRaisesRegex(AcceptanceRunError, "symlink-free"):
                ensure_external_directory(source / "artifacts" / "acceptance", source)
            with self.assertRaisesRegex(AcceptanceRunError, "symlink-free"):
                prepare_evidence_directory(
                    source / "artifacts" / "acceptance", source, create=False
                )

    def test_external_evidence_root_remains_allowed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            source = base / "source"
            evidence = base / "evidence"
            source.mkdir()
            evidence.mkdir()
            self.assertEqual(ensure_external_directory(evidence, source), evidence)

    def test_automatic_run_ids_are_valid_and_distinct(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            first = automatic_run_id(evidence)
            (evidence / first).mkdir()
            second = automatic_run_id(evidence)
            self.assertNotEqual(first, second)
            self.assertRegex(first, r"^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$")
            self.assertRegex(second, r"^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$")

    def test_archive_override_is_all_or_none(self) -> None:
        self.assertFalse(archive_override_is_complete(None, None, None))
        self.assertTrue(
            archive_override_is_complete(
                Path("source.tar.gz"), Path("receipt.json"), "a" * 64
            )
        )
        with self.assertRaisesRegex(AcceptanceRunError, "must be supplied together"):
            archive_override_is_complete(Path("source.tar.gz"), None, None)

    def test_git_head_is_derived_and_dirty_tree_remains_forbidden(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "--quiet", str(root)], check=True)
            subprocess.run(
                ["git", "-C", str(root), "config", "user.name", "Acceptance Test"],
                check=True,
            )
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(root),
                    "config",
                    "user.email",
                    "acceptance@example.invalid",
                ],
                check=True,
            )
            payload = root / "payload.txt"
            payload.write_text("clean\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(root), "add", "payload.txt"], check=True)
            subprocess.run(
                ["git", "-C", str(root), "commit", "--quiet", "-m", "fixture"],
                check=True,
            )
            commit = git_head(root)
            git_binding(root, commit)
            payload.write_text("dirty\n", encoding="utf-8")
            with self.assertRaisesRegex(AcceptanceRunError, "clean source tree"):
                git_binding(root, commit)

    def test_internal_evidence_does_not_change_source_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source"
            evidence = source / "ignored-evidence"
            evidence.mkdir(parents=True)
            (source / "payload.txt").write_text("payload\n", encoding="utf-8")
            before = source_inventory_without_evidence(source, evidence)
            (evidence / "run.json").write_text("{}\n", encoding="utf-8")
            after = source_inventory_without_evidence(source, evidence)
            self.assertEqual(before, after)

    def test_synthetic_receipt_cannot_replace_actual_clean_verification(self) -> None:
        digest = "a" * 64
        receipt = {
            "schema_version": 1,
            "receipt_kind": "CLEAN_SOURCE_ARCHIVE_EXTRACTION",
            "status": "PASSED",
            "verified_at": "2026-07-27T00:00:00Z",
            "archive_sha256": digest,
            "source_tree_sha256": digest,
            "design_bundle_sha256": digest,
            "member_manifest_sha256": digest,
            "manifest_sha256": digest,
            "archive_member_count": 1,
            "extracted_member_count": 1,
            "residue_paths": [],
            "verification_argv": ["make", "verify-final"],
            "artifacts": [
                {
                    "path": "logs/verify-final.log",
                    "sha256": digest,
                    "size": 1,
                    "media_type": "text/plain",
                }
            ],
        }
        actual_verification = {
            "manifest_sha256": digest,
            "archive_member_count": 2,
            "extracted_member_count": 2,
            "residue_paths": [],
            "verification_argv": ["make", "verify-final"],
        }
        validate_extraction_receipt_shape(ROOT, receipt)
        with self.assertRaisesRegex(
            AcceptanceRunError, "differs from actual clean verification"
        ):
            validate_verified_extraction_receipt(
                receipt,
                actual_verification,
                digest,
                digest,
                {"bundle_sha256": digest, "member_manifest_sha256": digest},
            )

    def test_synthetic_receipt_artifact_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            source = base / "source"
            evidence = base / "evidence"
            receipt_parent = base / "release"
            source.mkdir()
            evidence.mkdir()
            receipt_parent.mkdir()
            receipt = {
                "artifacts": [
                    {
                        "path": "logs/nonexistent.log",
                        "sha256": "a" * 64,
                        "size": 1,
                        "media_type": "text/plain",
                    }
                ]
            }
            with self.assertRaisesRegex(
                AcceptanceRunError, "artifact is missing or differs"
            ):
                validate_extraction_receipt_artifacts(
                    receipt, receipt_parent, evidence, source
                )


if __name__ == "__main__":
    unittest.main()
