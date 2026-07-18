#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from source_provenance import (  # noqa: E402
    ProvenanceError,
    classify_records,
    external_receipt_path,
    source_tree_digest,
    worktree_inventory,
)


def digest(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


class SourceProvenanceTests(unittest.TestCase):
    def test_roles_separate_base_overlay_implementation_and_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            files = {
                "AGENTS.md": b"same",
                "specs/base.yaml": b"changed",
                "DESIGN.md": b"overlay",
                "apps/web/main.ts": b"implementation",
                "verification/run.json": b"evidence",
            }
            for relative, content in files.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
            authority = {
                "AGENTS.md": digest(b"same"),
                "specs/base.yaml": digest(b"original"),
            }
            records = {record.path: record for record in classify_records(authority, worktree_inventory(root))}
            self.assertEqual((records["AGENTS.md"].status, records["AGENTS.md"].role), ("SAME", "BASE_AUTHORITY"))
            self.assertEqual((records["specs/base.yaml"].status, records["specs/base.yaml"].role), ("MODIFIED", "OVERLAY"))
            self.assertEqual(records["DESIGN.md"].role, "OVERLAY")
            self.assertEqual(records["apps/web/main.ts"].role, "IMPLEMENTATION")
            self.assertEqual(records["verification/run.json"].role, "EVIDENCE")

    def test_deleted_authority_member_is_explicit(self) -> None:
        records = classify_records({"missing.md": digest(b"expected")}, {})
        self.assertEqual(records[0].status, "DELETED")
        self.assertIsNone(records[0].source_sha256)

    def test_tree_digest_binds_path_size_and_bytes(self) -> None:
        first = {"a": (digest(b"one"), 3)}
        second = {"b": (digest(b"one"), 3)}
        third = {"a": (digest(b"two"), 3)}
        self.assertNotEqual(source_tree_digest(first), source_tree_digest(second))
        self.assertNotEqual(source_tree_digest(first), source_tree_digest(third))

    def test_symlink_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "target"
            target.write_text("value", encoding="utf-8")
            (root / "link").symlink_to(target)
            with self.assertRaises(ProvenanceError):
                worktree_inventory(root)

    def test_receipt_must_be_explicit_and_external(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "source"
            evidence = base / "evidence"
            root.mkdir()
            evidence.mkdir()
            with self.assertRaises(ProvenanceError):
                external_receipt_path(root, None)
            with self.assertRaises(ProvenanceError):
                external_receipt_path(root, root / "verification" / "receipt.json")
            self.assertEqual(
                external_receipt_path(root, evidence / "source-provenance.json"),
                evidence / "source-provenance.json",
            )

    def test_symlink_receipt_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "source"
            evidence = base / "evidence"
            root.mkdir()
            evidence.mkdir()
            target = evidence / "target.json"
            target.write_text("{}", encoding="utf-8")
            link = evidence / "receipt.json"
            link.symlink_to(target)
            with self.assertRaises(ProvenanceError):
                external_receipt_path(root, link)


if __name__ == "__main__":
    unittest.main()
