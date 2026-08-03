#!/usr/bin/env python3
"""Create and verify deterministic manifests that live only inside archives."""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

from git_authority import AUTHORITY_MANIFEST_FILE
from verify_migrations import verify_migrations


CHECKSUM_MANIFEST = "MANIFEST.sha256"
DOCUMENT_MANIFEST = "MANIFEST.md"
MANIFEST_METADATA = frozenset({CHECKSUM_MANIFEST, DOCUMENT_MANIFEST})
SOURCE_TREE_DOMAIN = b"GURINNAE-SOURCE-PROVENANCE-V1\0"
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")


class ArchiveManifestError(RuntimeError):
    """The archive-local manifest does not describe its extracted tree."""


@dataclass(frozen=True)
class ManifestEntry:
    sha256: str
    relative: str
    size: int


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_relative_path(value: str) -> None:
    path = PurePosixPath(value)
    if (
        not value
        or not path.parts
        or "\n" in value
        or "\r" in value
        or "\\" in value
        or path.is_absolute()
        or "." in path.parts
        or ".." in path.parts
        or path.as_posix() != value
    ):
        raise ArchiveManifestError(f"unsafe manifest path: {value!r}")
    if value in MANIFEST_METADATA:
        raise ArchiveManifestError(f"manifest cannot digest itself: {value}")


def collect_entries(root: Path) -> tuple[ManifestEntry, ...]:
    entries: list[ManifestEntry] = []
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            raise ArchiveManifestError(f"manifest tree contains link: {relative}")
        if path.is_dir():
            continue
        if not path.is_file():
            raise ArchiveManifestError(
                f"manifest tree contains special file: {relative}"
            )
        if relative in MANIFEST_METADATA:
            continue
        validate_relative_path(relative)
        entries.append(ManifestEntry(file_sha256(path), relative, path.stat().st_size))
    return tuple(entries)


def source_tree_sha256(entries: tuple[ManifestEntry, ...]) -> str:
    digest = hashlib.sha256(SOURCE_TREE_DOMAIN)
    source_entries = (
        entry for entry in entries if entry.relative != AUTHORITY_MANIFEST_FILE
    )
    for entry in sorted(source_entries, key=lambda item: item.relative):
        encoded = entry.relative.encode("utf-8")
        digest.update(len(encoded).to_bytes(4, "big"))
        digest.update(encoded)
        digest.update(entry.size.to_bytes(8, "big"))
        digest.update(bytes.fromhex(entry.sha256))
    return digest.hexdigest()


def render_source_document(
    root: Path, entries: tuple[ManifestEntry, ...], archive_root: str
) -> str:
    runtime = verify_migrations(root)
    stats = json.loads((root / "verification/static-validation.json").read_text(encoding="utf-8"))[
        "stats"
    ]
    size = sum(entry.size for entry in entries)
    return f"""# Package Manifest — Gurine Source Tree v13.0.0

- Archive root: `{archive_root}/`
- Manifested files: **{len(entries)}**
- Manifested bytes: **{size}**
- Hash algorithm: **SHA-256**
- Checksum coverage excludes its two circular digest files and generated build/cache output.
- Source provenance also excludes the archive-only frozen-authority manifest.

## Contract counts

- Screens: {stats['screens']}
- Operations: {stats['operations']} ({stats['query_operations']} queries / {stats['command_operations']} commands)
- Database migrations/tables: specification {stats['database_migrations']} / runtime {len(runtime)} / {stats['database_tables']}
- Events: {stats['events']}
- Agent/detection evaluation cases: {stats['agent_eval_cases']} / {stats['rule_evaluation_cases']}
- Acceptance features/scenarios: {stats['acceptance_features']} / {stats['acceptance_scenarios']}

`MANIFEST.sha256` contains one digest and repository-relative path per line.
"""


def write_source_archive_manifest(root: Path, archive_root: str) -> tuple[ManifestEntry, ...]:
    entries = collect_entries(root)
    checksum = "".join(f"{entry.sha256}  {entry.relative}\n" for entry in entries)
    (root / CHECKSUM_MANIFEST).write_text(checksum, encoding="utf-8")
    document = render_source_document(root, entries, archive_root)
    (root / DOCUMENT_MANIFEST).write_text(document, encoding="utf-8")
    return entries


def parse_checksum_manifest(root: Path) -> dict[str, str]:
    path = root / CHECKSUM_MANIFEST
    try:
        content = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise ArchiveManifestError(f"cannot read archive checksum manifest: {error}") from error
    if not content or not content.endswith("\n") or "\r" in content:
        raise ArchiveManifestError(
            "archive checksum manifest must be non-empty UTF-8 with final LF"
        )
    entries: dict[str, str] = {}
    for line_number, line in enumerate(content.splitlines(), start=1):
        digest, separator, relative = line.partition("  ")
        if separator != "  " or SHA256_PATTERN.fullmatch(digest) is None:
            raise ArchiveManifestError(f"invalid checksum manifest line {line_number}")
        validate_relative_path(relative)
        if relative in entries:
            raise ArchiveManifestError(f"duplicate checksum manifest path: {relative}")
        entries[relative] = digest
    return entries


def verify_document_manifest(
    root: Path, archive_root: str, entries: tuple[ManifestEntry, ...]
) -> None:
    path = root / DOCUMENT_MANIFEST
    try:
        content = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise ArchiveManifestError(f"cannot read archive document manifest: {error}") from error
    expected_lines = {
        f"- Archive root: `{archive_root}/`",
        f"- Manifested files: **{len(entries)}**",
        f"- Manifested bytes: **{sum(entry.size for entry in entries)}**",
        "- Hash algorithm: **SHA-256**",
    }
    missing = sorted(expected_lines - set(content.splitlines()))
    if missing:
        raise ArchiveManifestError(
            f"archive document manifest metadata differs: missing={missing}"
        )


def verify_archive_manifest(root: Path, archive_root: str) -> tuple[ManifestEntry, ...]:
    if not root.is_dir():
        raise ArchiveManifestError(f"archive root is missing: {root}")
    actual = collect_entries(root)
    actual_by_path = {entry.relative: entry for entry in actual}
    expected = parse_checksum_manifest(root)
    actual_paths = set(actual_by_path)
    expected_paths = set(expected)
    if actual_paths != expected_paths:
        missing = sorted(actual_paths - expected_paths)
        extra = sorted(expected_paths - actual_paths)
        raise ArchiveManifestError(
            f"manifest member set differs: missing={missing} extra={extra}"
        )
    mismatches = sorted(
        relative
        for relative, digest in expected.items()
        if actual_by_path[relative].sha256 != digest
    )
    if mismatches:
        raise ArchiveManifestError(f"manifest checksum differs: {mismatches}")
    verify_document_manifest(root, archive_root, actual)
    return actual
