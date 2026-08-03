from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from run_acceptance import (
    AcceptanceRunError,
    ExclusiveRunDirectory,
    archive_override_is_complete,
    automatic_run_id,
    ensure_external_directory,
    ensure_evidence_file,
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
