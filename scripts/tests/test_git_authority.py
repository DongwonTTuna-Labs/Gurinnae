#!/usr/bin/env python3
from __future__ import annotations

import base64
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))

import git_authority  # noqa: E402
from git_authority import (  # noqa: E402
    AUTHORITY_COMMIT_OID,
    AUTHORITY_MANIFEST_FILE,
    AUTHORITY_MANIFEST_SHA256,
    AUTHORITY_PATH_COUNT,
    AUTHORITY_TREE_OID,
    BASE_ACCEPTANCE_LOCK,
    GitAuthorityError,
    authority_archive,
    authority_file,
    authority_paths,
    render_authority_manifest,
    resolve_authority,
)


class GitAuthorityFallbackTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.manifest = render_authority_manifest(ROOT)

    def write_gitless_root(self, root: Path, content: bytes | None = None) -> None:
        payload = self.manifest if content is None else content
        (root / AUTHORITY_MANIFEST_FILE).write_bytes(payload)

    def test_valid_gitless_fallback_serves_index_and_embedded_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.write_gitless_root(root)

            identity = resolve_authority(root)
            paths = authority_paths(root)
            lock = authority_file(BASE_ACCEPTANCE_LOCK, root)

            self.assertEqual(identity.commit_oid, AUTHORITY_COMMIT_OID)
            self.assertEqual(identity.tree_oid, AUTHORITY_TREE_OID)
            self.assertEqual(len(paths), AUTHORITY_PATH_COUNT)
            self.assertIn(BASE_ACCEPTANCE_LOCK, paths)
            self.assertTrue(lock.startswith(b"schema_version: 1\n"))
            with self.assertRaisesRegex(GitAuthorityError, "does not embed path"):
                authority_file("AGENTS.md", root)

    def test_one_byte_manifest_tamper_fails_at_raw_digest_pin(self) -> None:
        tampered = bytearray(self.manifest)
        tampered[0] ^= 1
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.write_gitless_root(root, bytes(tampered))

            with self.assertRaisesRegex(
                GitAuthorityError, "archive authority manifest SHA-256 differs"
            ) as raised:
                authority_paths(root)
            self.assertIn("make source-archive", str(raised.exception))

    def test_git_entry_with_unavailable_tag_never_uses_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / ".git").mkdir()
            self.write_gitless_root(root)

            with self.assertRaises(GitAuthorityError) as raised:
                resolve_authority(root)

            message = str(raised.exception)
            self.assertIn("archive fallback is disabled", message)
            self.assertIn("git fetch origin tag authority-v13-frozen", message)
            self.assertIn("git fetch --tags --force", message)
            self.assertIn("CI checkout must fetch tags", message)
            self.assertIn("git push origin authority-v13-frozen", message)

    def test_gitless_authority_archive_is_explicitly_unsupported(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.write_gitless_root(root)

            with self.assertRaisesRegex(GitAuthorityError, "unsupported"):
                authority_archive(root)

    def test_gitless_root_without_manifest_has_regeneration_action(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(GitAuthorityError) as raised:
                authority_paths(Path(temporary))

            message = str(raised.exception)
            self.assertIn("make source-archive", message)
            self.assertIn("pinned tag authority-v13-frozen", message)

    def test_manifest_renderer_matches_hardcoded_digest(self) -> None:
        self.assertEqual(
            hashlib.sha256(self.manifest).hexdigest(),
            AUTHORITY_MANIFEST_SHA256,
        )

    def test_duplicate_json_keys_are_rejected_after_digest_check(self) -> None:
        raw = b'{"schema_version":1,"schema_version":1}\n'
        digest = hashlib.sha256(raw).hexdigest()
        with patch.object(git_authority, "AUTHORITY_MANIFEST_SHA256", digest):
            with self.assertRaisesRegex(GitAuthorityError, "duplicate.*JSON key"):
                git_authority._parse_authority_manifest(raw)

    def test_embedded_byte_change_reaches_git_blob_oid_check(self) -> None:
        document = json.loads(self.manifest)
        embedded = document["embedded_files"][0]
        content = bytearray(base64.b64decode(embedded["content_base64"]))
        content[0] ^= 1
        embedded["content_base64"] = base64.b64encode(content).decode("ascii")
        raw = git_authority._canonical_json(document)
        digest = hashlib.sha256(raw).hexdigest()

        with patch.object(git_authority, "AUTHORITY_MANIFEST_SHA256", digest):
            with self.assertRaisesRegex(GitAuthorityError, "Git blob OID differs"):
                git_authority._parse_authority_manifest(raw)

    def test_authority_file_rejects_bytes_that_differ_from_declared_oid(self) -> None:
        declared_content = b"declared frozen bytes\n"
        returned_content = b"different returned bytes\n"
        declared_oid = git_authority._git_blob_oid(declared_content)
        identity = git_authority.AuthorityIdentity(
            git_authority.AUTHORITY_TAG,
            AUTHORITY_COMMIT_OID,
            AUTHORITY_TREE_OID,
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / ".git").mkdir()
            with (
                patch.object(
                    git_authority,
                    "_resolve_git_authority",
                    return_value=identity,
                ) as resolve,
                patch.object(
                    git_authority,
                    "_resolve_oid",
                    return_value=declared_oid,
                ) as rev_parse,
                patch.object(
                    git_authority,
                    "_run_git",
                    return_value=returned_content,
                ) as show,
            ):
                with self.assertRaisesRegex(
                    GitAuthorityError, "Git blob bytes differ for AGENTS.md"
                ):
                    authority_file("AGENTS.md", root)

            rev_parse.assert_called_once_with(
                root.resolve(), f"{AUTHORITY_COMMIT_OID}:AGENTS.md"
            )
            show.assert_called_once_with(
                root.resolve(), ["show", f"{AUTHORITY_COMMIT_OID}:AGENTS.md"]
            )
            self.assertEqual(resolve.call_count, 2)


if __name__ == "__main__":
    unittest.main()
