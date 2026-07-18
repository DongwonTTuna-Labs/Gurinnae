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
    ensure_external_directory,
)


ROOT = Path(__file__).resolve().parents[2]


class AcceptanceMutationBoundaryTests(unittest.TestCase):
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

    def test_evidence_root_cannot_be_inside_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source"
            evidence = source / "evidence"
            evidence.mkdir(parents=True)
            with self.assertRaisesRegex(AcceptanceRunError, "outside source"):
                ensure_external_directory(evidence, source)


if __name__ == "__main__":
    unittest.main()
