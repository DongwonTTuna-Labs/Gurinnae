#!/usr/bin/env python3
"""Build and verify the byte-level provenance receipt for a Gurinnae source tree.

The immutable v13 Git tag, the normative post-authority design overlay, the
implementation tree, and execution evidence are deliberately separate roles.
This prevents an old design review or a pristine authority digest from being
misreported as proof for changed runtime source.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import stat
import sys
import tarfile
from collections import Counter
from dataclasses import asdict, dataclass
from pathlib import Path, PurePosixPath

from design_bundle_digest import (
    BundleError,
    build_manifest as build_design_manifest,
)
from git_authority import (
    AUTHORITY_ZIP_SHA256,
    GitAuthorityError,
    authority_archive,
    authority_paths,
    head_commit_oid,
    resolve_authority,
)


ROOT = Path(__file__).resolve().parents[1]
DOMAIN = b"GURINNAE-SOURCE-PROVENANCE-V1\0"
EXCLUDED_DIRECTORIES = frozenset(
    {
        ".git",
        ".fable-sol",
        ".svelte-kit",
        "artifacts",
        "build",
        "node_modules",
        "playwright-report",
        "target",
        "test-results",
        "__pycache__",
    }
)
EXCLUDED_FILES = frozenset(
    {
        ".env",
        ".env.local",
        ".env.production",
        ".env.test",
    }
)


class ProvenanceError(RuntimeError):
    """The receipt cannot be derived without guessing or omitting bytes."""


@dataclass(frozen=True)
class FileRecord:
    path: str
    origin: str
    status: str
    role: str
    authority_sha256: str | None
    source_sha256: str | None
    size: int | None


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_relative(value: str) -> bool:
    path = PurePosixPath(value)
    return bool(
        value
        and "\\" not in value
        and not path.is_absolute()
        and ".." not in path.parts
        and path.as_posix() == value
    )


def excluded(relative: Path) -> bool:
    return (
        (relative.as_posix() in EXCLUDED_FILES or relative.name in EXCLUDED_FILES)
        or any(part in EXCLUDED_DIRECTORIES for part in relative.parts)
        or relative.suffix in {".pyc", ".pyo"}
    )


def worktree_inventory(root: Path) -> dict[str, tuple[str, int]]:
    inventory: dict[str, tuple[str, int]] = {}
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        if excluded(relative):
            continue
        if path.is_symlink():
            raise ProvenanceError(f"source provenance forbids symlinks: {relative.as_posix()}")
        if path.is_dir():
            continue
        try:
            mode = path.stat().st_mode
        except OSError as error:
            raise ProvenanceError(f"source member became unreadable: {relative}: {error}") from error
        if not stat.S_ISREG(mode):
            raise ProvenanceError(f"source provenance forbids special files: {relative.as_posix()}")
        name = relative.as_posix()
        if not safe_relative(name):
            raise ProvenanceError(f"unsafe source path: {name}")
        inventory[name] = (sha256_file(path), path.stat().st_size)
    return inventory


def overlay_path(relative: str) -> bool:
    path = PurePosixPath(relative)
    if relative == "DESIGN.md" or relative.startswith("specs/"):
        return True
    if relative.startswith("tests/acceptance/"):
        return True
    if relative.startswith("implementation-evidence/"):
        name = path.name
        return (
            name.startswith("design-")
            or "authority" in name
            or "business-model" in name
            or name
            in {
                "spec-conflicts.md",
                "expert-review-prompt.md",
                "supplemental-acceptance-registry.yaml",
            }
        )
    return False


def evidence_path(relative: str) -> bool:
    return relative.startswith("verification/") or relative.startswith(
        "implementation-evidence/reviews/"
    ) or relative in {
        "VERIFICATION.md",
        "implementation-evidence/expert-review-status.md",
    }


def derived_role(relative: str) -> str:
    if overlay_path(relative):
        return "OVERLAY"
    if evidence_path(relative):
        return "EVIDENCE"
    return "IMPLEMENTATION"


def classify_records(
    authority: dict[str, str],
    source: dict[str, tuple[str, int]],
) -> list[FileRecord]:
    records: list[FileRecord] = []
    for relative, expected in sorted(authority.items()):
        current = source.get(relative)
        if current is None:
            records.append(
                FileRecord(relative, "AUTHORITY_MEMBER", "DELETED", derived_role(relative), expected, None, None)
            )
            continue
        actual, size = current
        same = actual == expected
        records.append(
            FileRecord(
                relative,
                "AUTHORITY_MEMBER",
                "SAME" if same else "MODIFIED",
                "BASE_AUTHORITY" if same else derived_role(relative),
                expected,
                actual,
                size,
            )
        )
    for relative in sorted(set(source) - set(authority)):
        actual, size = source[relative]
        records.append(
            FileRecord(relative, "WORKTREE_ADDITION", "ADDED", derived_role(relative), None, actual, size)
        )
    return records


def source_tree_digest(source: dict[str, tuple[str, int]]) -> str:
    digest = hashlib.sha256(DOMAIN)
    for relative, (file_digest, size) in sorted(source.items()):
        encoded = relative.encode("utf-8")
        digest.update(len(encoded).to_bytes(4, "big"))
        digest.update(encoded)
        digest.update(size.to_bytes(8, "big"))
        digest.update(bytes.fromhex(file_digest))
    return digest.hexdigest()


def git_head(root: Path) -> str | None:
    try:
        return head_commit_oid(root)
    except GitAuthorityError:
        return None


def authority_inventory(root: Path) -> tuple[dict[str, str], int]:
    """Hash tag members for per-file classification, never tree authority."""

    expected_paths = authority_paths(root)
    try:
        stream = io.BytesIO(authority_archive(root))
        with tarfile.open(fileobj=stream, mode="r:") as archive:
            inventory: dict[str, str] = {}
            seen_paths: set[str] = set()
            for member in archive.getmembers():
                if member.isdir():
                    continue
                relative = member.name
                if not member.isfile() or not safe_relative(relative):
                    raise ProvenanceError(
                        f"Git authority archive contains a non-regular member: {relative!r}"
                    )
                if relative in seen_paths:
                    raise ProvenanceError(
                        f"Git authority archive contains a duplicate member: {relative}"
                    )
                seen_paths.add(relative)
                if excluded(Path(relative)):
                    continue
                extracted = archive.extractfile(member)
                if extracted is None:
                    raise ProvenanceError(
                        f"Git authority archive member is unreadable: {relative}"
                    )
                inventory[relative] = hashlib.sha256(extracted.read()).hexdigest()
    except (OSError, tarfile.TarError) as error:
        raise ProvenanceError(f"Git authority archive is unreadable: {error}") from error
    if seen_paths != set(expected_paths):
        missing = sorted(set(expected_paths) - seen_paths)[:8]
        extra = sorted(seen_paths - set(expected_paths))[:8]
        raise ProvenanceError(
            f"Git authority path set differs from git archive: missing={missing}, extra={extra}"
        )
    return inventory, len(expected_paths)


def build_receipt(root: Path) -> dict[str, object]:
    root = root.resolve()
    identity = resolve_authority(root)
    authority, authority_path_count = authority_inventory(root)
    source_before = worktree_inventory(root)
    records = classify_records(authority, source_before)
    try:
        design = build_design_manifest(root)
    except BundleError as error:
        raise ProvenanceError(f"design bundle cannot be derived: {error}") from error
    source_after = worktree_inventory(root)
    if source_after != source_before:
        raise ProvenanceError("source tree changed while provenance was calculated")
    rows = [asdict(record) for record in records]
    canonical_rows = json.dumps(
        rows, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    status_counts = Counter(record.status for record in records)
    role_counts = Counter(record.role for record in records)
    return {
        "schema_version": 1,
        "result": "PASS",
        "authority_tag": identity.tag,
        "authority_commit_oid": identity.commit_oid,
        "authority_tree_oid": identity.tree_oid,
        "authority_zip_sha256": AUTHORITY_ZIP_SHA256,
        "authority_path_count": authority_path_count,
        "authority_member_count": len(authority),
        "source_tree_sha256": source_tree_digest(source_before),
        "source_file_count": len(source_before),
        "source_byte_count": sum(size for _, size in source_before.values()),
        "classification_sha256": hashlib.sha256(canonical_rows).hexdigest(),
        "design_bundle_sha256": design["bundle_sha256"],
        "design_member_manifest_sha256": design["member_manifest_sha256"],
        "design_member_count": design["member_count"],
        "git_head": git_head(root),
        "status_counts": dict(sorted(status_counts.items())),
        "role_counts": dict(sorted(role_counts.items())),
        "files": rows,
    }


def render(receipt: dict[str, object]) -> str:
    return json.dumps(receipt, ensure_ascii=False, sort_keys=True, indent=2) + "\n"


def write_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        temporary.write_text(text, encoding="utf-8")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def external_receipt_path(root: Path, receipt: Path | None) -> Path:
    """Return a plain receipt path that cannot become source-tree evidence."""

    if receipt is None:
        raise ProvenanceError("--receipt is required for --write and --check")
    root_resolved = root.resolve()
    try:
        parent = receipt.parent.resolve(strict=True)
    except OSError as error:
        raise ProvenanceError(
            f"source provenance receipt parent is unavailable: {receipt.parent}"
        ) from error
    resolved = parent / receipt.name
    if resolved.is_relative_to(root_resolved):
        raise ProvenanceError("source provenance receipt must be outside the source tree")
    if receipt.is_symlink():
        raise ProvenanceError("source provenance receipt must not be a symlink")
    return resolved


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--receipt", type=Path)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--print", dest="print_receipt", action="store_true")
    args = parser.parse_args()
    try:
        current = build_receipt(args.root)
        current_text = render(current)
        if args.write:
            receipt = external_receipt_path(args.root, args.receipt)
            write_atomic(receipt, current_text)
        elif args.check:
            receipt = external_receipt_path(args.root, args.receipt)
            if not receipt.is_file():
                raise ProvenanceError(f"source provenance receipt is missing: {receipt}")
            existing = receipt.read_text(encoding="utf-8")
            if existing != current_text:
                raise ProvenanceError("source provenance receipt is stale")
        else:
            print(current_text, end="")
    except (GitAuthorityError, OSError, ProvenanceError, ValueError) as error:
        print(f"SOURCE_PROVENANCE: FAIL: {error}", file=sys.stderr)
        return 1
    print("SOURCE_PROVENANCE: PASS", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
