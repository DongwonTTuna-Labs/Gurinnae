#!/usr/bin/env python3
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from archive_manifest import (  # noqa: E402
    ArchiveManifestError,
    collect_entries,
    verify_archive_manifest,
)
from create_source_archive import excluded  # noqa: E402


def write_manifest(root: Path, archive_root: str = "source") -> None:
    entries = collect_entries(root)
    checksum = "".join(f"{entry.sha256}  {entry.relative}\n" for entry in entries)
    (root / "MANIFEST.sha256").write_text(checksum, encoding="utf-8")
    total = sum(entry.size for entry in entries)
    (root / "MANIFEST.md").write_text(
        "\n".join(
            (
                "# Test archive manifest",
                "",
                f"- Archive root: `{archive_root}/`",
                f"- Manifested files: **{len(entries)}**",
                f"- Manifested bytes: **{total}**",
                "- Hash algorithm: **SHA-256**",
                "",
            )
        ),
        encoding="utf-8",
    )


class ArchiveManifestTests(unittest.TestCase):
    def test_archive_local_manifest_covers_exact_regular_file_set(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "nested").mkdir()
            (root / "alpha.txt").write_text("alpha\n", encoding="utf-8")
            (root / "nested/beta.bin").write_bytes(b"beta")
            write_manifest(root)

            entries = verify_archive_manifest(root, "source")

            self.assertEqual(
                [entry.relative for entry in entries],
                ["alpha.txt", "nested/beta.bin"],
            )

    def test_checksum_tampering_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payload = root / "payload.txt"
            payload.write_text("before\n", encoding="utf-8")
            write_manifest(root)
            payload.write_text("after\n", encoding="utf-8")

            with self.assertRaisesRegex(ArchiveManifestError, "manifest checksum differs"):
                verify_archive_manifest(root, "source")

    def test_unlisted_archive_member_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "payload.txt").write_text("payload\n", encoding="utf-8")
            write_manifest(root)
            (root / "late.txt").write_text("not listed\n", encoding="utf-8")

            with self.assertRaisesRegex(ArchiveManifestError, "manifest member set differs"):
                verify_archive_manifest(root, "source")

    def test_archive_output_directories_are_not_copied(self) -> None:
        self.assertTrue(excluded(Path(".fable-sol/cache/result")))
        self.assertTrue(excluded(Path("artifacts/source.tar.gz")))


if __name__ == "__main__":
    unittest.main()
