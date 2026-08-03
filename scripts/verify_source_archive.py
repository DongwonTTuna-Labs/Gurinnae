#!/usr/bin/env python3
"""Safely extract and independently run every hard gate on the source archive."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tarfile
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path, PurePosixPath

from archive_manifest import (
    ManifestEntry,
    source_tree_sha256,
    verify_archive_manifest,
)


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ARCHIVE = ROOT / "artifacts" / "gurine-source-v13.0.0.tar.gz"
DEFAULT_EXTRACTION_ROOT = Path("/var/tmp")


@dataclass(frozen=True)
class SourceArchiveVerification:
    archive_sha256: str
    source_tree_sha256: str
    manifest_sha256: str
    archive_member_count: int
    extracted_member_count: int
    extracted_members: tuple[str, ...]
    residue_paths: tuple[str, ...]
    verification_argv: tuple[str, ...]
    manifested_files: int
    manifested_bytes: int


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_sidecar(archive: Path) -> str:
    sidecar = Path(f"{archive}.sha256")
    if not sidecar.is_file():
        raise RuntimeError(f"source archive sidecar missing: {sidecar}")
    fields = sidecar.read_text(encoding="utf-8").strip().split()
    if len(fields) != 2 or fields[1] != archive.name:
        raise RuntimeError("source archive sidecar format is invalid")
    actual = sha256(archive)
    if fields[0] != actual:
        raise RuntimeError(f"source archive checksum differs: {fields[0]} != {actual}")
    return actual


def inspect(archive: Path) -> tuple[str, ...]:
    with tarfile.open(archive, "r:gz") as package:
        members = package.getmembers()
        names = [member.name for member in members]
        if len(names) != len(set(names)):
            raise RuntimeError("source archive contains duplicate paths")
        regular_members: list[str] = []
        for member in members:
            path = PurePosixPath(member.name)
            if (
                path.is_absolute()
                or not path.parts
                or path.parts[0] != "source"
                or ".." in path.parts
            ):
                raise RuntimeError(f"unsafe source archive path: {member.name}")
            if not (member.isdir() or member.isfile()):
                raise RuntimeError(
                    f"source archive links/special files forbidden: {member.name}"
                )
            if member.isfile():
                regular_members.append(member.name)
        return tuple(sorted(regular_members))


def verify_manifest(source: Path) -> tuple[ManifestEntry, ...]:
    return verify_archive_manifest(source, "source")


def extracted_regular_members(destination: Path) -> tuple[str, ...]:
    members: list[str] = []
    for path in sorted(destination.rglob("*")):
        relative = path.relative_to(destination).as_posix()
        if path.is_symlink():
            raise RuntimeError(f"clean extraction contains link: {relative}")
        if path.is_file():
            members.append(relative)
        elif not path.is_dir():
            raise RuntimeError(f"clean extraction contains special file: {relative}")
    return tuple(sorted(members))


def verify_member_parity(
    archive_members: tuple[str, ...], extracted_members: tuple[str, ...]
) -> tuple[str, ...]:
    archive_member_set = set(archive_members)
    extracted_member_set = set(extracted_members)
    missing = sorted(archive_member_set - extracted_member_set)
    residue_paths = tuple(sorted(extracted_member_set - archive_member_set))
    if missing or residue_paths:
        raise RuntimeError(
            f"clean extraction member set differs: "
            f"missing={missing} residue={list(residue_paths)}"
        )
    return residue_paths


def verify_source_digest(
    entries: tuple[ManifestEntry, ...], expected: str | None
) -> str:
    actual = source_tree_sha256(entries)
    if expected is not None and actual != expected:
        raise RuntimeError(f"source tree digest differs: {actual} != {expected}")
    return actual


def verify_source_archive(
    archive: Path,
    extraction_root: Path = DEFAULT_EXTRACTION_ROOT,
    expected_source_tree_sha256: str | None = None,
) -> SourceArchiveVerification:
    archive = archive.resolve()
    extraction_root = extraction_root.resolve()
    if not archive.is_file():
        raise RuntimeError(f"source archive missing: {archive}")
    if not extraction_root.is_dir():
        raise RuntimeError(f"clean extraction root missing: {extraction_root}")
    archive_sha256 = verify_sidecar(archive)
    archive_members = inspect(archive)
    temporary_path: Path | None = None
    with tempfile.TemporaryDirectory(
        prefix="gurine-clean-extraction-", dir=extraction_root
    ) as temporary:
        destination = Path(temporary)
        temporary_path = destination
        with tarfile.open(archive, "r:gz") as package:
            package.extractall(destination, filter="data")
        extracted_members = extracted_regular_members(destination)
        residue_paths = verify_member_parity(archive_members, extracted_members)
        source = destination / "source"
        entries = verify_manifest(source)
        manifest_sha256 = sha256(source / "MANIFEST.sha256")
        source_digest = verify_source_digest(entries, expected_source_tree_sha256)
        environment = os.environ.copy()
        environment["GURINE_CLEAN_EXTRACTION"] = "1"
        # Acceptance sealing and source archive creation are standalone, so
        # verify-final is the complete non-recursive clean-extraction gate.
        verification_argv = ("make", "verify-final")
        subprocess.run(verification_argv, cwd=source, env=environment, check=True)
        manifested_files = len(entries)
        manifested_bytes = sum(entry.size for entry in entries)
    if temporary_path is None or temporary_path.exists():
        raise RuntimeError("clean extraction temporary directory was not removed")
    return SourceArchiveVerification(
        archive_sha256=archive_sha256,
        source_tree_sha256=source_digest,
        manifest_sha256=manifest_sha256,
        archive_member_count=len(archive_members),
        extracted_member_count=len(extracted_members),
        extracted_members=extracted_members,
        residue_paths=residue_paths,
        verification_argv=verification_argv,
        manifested_files=manifested_files,
        manifested_bytes=manifested_bytes,
    )


def main() -> int:
    archive = Path(os.environ.get("SOURCE_ARCHIVE", DEFAULT_ARCHIVE)).resolve()
    extraction_root = Path(
        os.environ.get("GURINE_CLEAN_EXTRACTION_ROOT", DEFAULT_EXTRACTION_ROOT)
    ).resolve()
    expected_source_tree_sha256 = os.environ.get("EXPECTED_SOURCE_TREE_SHA256")
    verification = verify_source_archive(
        archive,
        extraction_root,
        expected_source_tree_sha256=expected_source_tree_sha256,
    )
    print(f"SOURCE_ARCHIVE_VERIFICATION={json.dumps(asdict(verification), sort_keys=True)}")
    print("clean extraction verify-final hard-gate verification: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
