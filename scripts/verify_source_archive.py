#!/usr/bin/env python3
"""Safely extract and independently run every hard gate on the source archive."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
import subprocess
import tarfile
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path, PurePosixPath

from jsonschema import Draft202012Validator

from archive_manifest import (
    ManifestEntry,
    source_tree_sha256,
    verify_archive_manifest,
)
from design_bundle_digest import build_manifest as build_design_manifest


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ARCHIVE = ROOT / "artifacts" / "gurine-source-v13.0.0.tar.gz"
DEFAULT_EXTRACTION_ROOT = Path("/var/tmp")
EXTRACTION_RECEIPT_SCHEMA = ROOT / "specs/acceptance/extraction-receipt-v1.schema.json"


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
    design_bundle_sha256: str
    member_manifest_sha256: str


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


def default_receipt_path(archive: Path) -> Path:
    suffix = ".tar.gz"
    if not archive.name.endswith(suffix):
        raise RuntimeError("source archive filename must end with .tar.gz")
    stem = archive.name.removesuffix(suffix)
    return archive.with_name(f"{stem}.extraction-receipt.json")


def receipt_artifact(path: Path, parent: Path, media_type: str) -> dict[str, object]:
    metadata = path.lstat()
    if path.is_symlink() or not path.is_file() or metadata.st_size < 1:
        raise RuntimeError(f"extraction receipt artifact is not plain: {path}")
    try:
        relative = path.relative_to(parent).as_posix()
    except ValueError as error:
        raise RuntimeError("extraction receipt artifacts must be receipt siblings") from error
    return {
        "path": relative,
        "sha256": sha256(path),
        "size": metadata.st_size,
        "media_type": media_type,
    }


def extraction_receipt(
    archive: Path, verification: SourceArchiveVerification, verified_at: str
) -> dict[str, object]:
    parent = archive.parent
    sidecar = Path(f"{archive}.sha256")
    return {
        "schema_version": 1,
        "receipt_kind": "CLEAN_SOURCE_ARCHIVE_EXTRACTION",
        "status": "PASSED",
        "verified_at": verified_at,
        "archive_sha256": verification.archive_sha256,
        "source_tree_sha256": verification.source_tree_sha256,
        "design_bundle_sha256": verification.design_bundle_sha256,
        "member_manifest_sha256": verification.member_manifest_sha256,
        "manifest_sha256": verification.manifest_sha256,
        "archive_member_count": verification.archive_member_count,
        "extracted_member_count": verification.extracted_member_count,
        "residue_paths": list(verification.residue_paths),
        "verification_argv": list(verification.verification_argv),
        "artifacts": [
            receipt_artifact(archive, parent, "application/gzip"),
            receipt_artifact(sidecar, parent, "text/plain"),
        ],
    }


def validate_receipt(receipt: dict[str, object]) -> None:
    schema = json.loads(EXTRACTION_RECEIPT_SCHEMA.read_text(encoding="utf-8"))
    errors = sorted(
        Draft202012Validator(schema).iter_errors(receipt),
        key=lambda error: [str(part) for part in error.absolute_path],
    )
    if errors:
        raise RuntimeError(f"extraction receipt violates schema: {errors[0].message}")


def write_receipt(path: Path, receipt: dict[str, object]) -> str:
    path = path.resolve()
    if path.parent != DEFAULT_ARCHIVE.parent.resolve():
        raise RuntimeError("extraction receipt must be an artifacts/ archive sibling")
    if path.is_symlink():
        raise RuntimeError("extraction receipt must not be a symlink")
    content = (
        json.dumps(receipt, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
    ).encode("utf-8")
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    if temporary.exists():
        raise RuntimeError(f"stale extraction receipt temporary file: {temporary}")
    try:
        temporary.write_bytes(content)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)
    return hashlib.sha256(content).hexdigest()


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
        # Acceptance evidence is produced only after this receipt exists.
        # Running the non-acceptance hard gates here keeps archive verification
        # independent and prevents verify-final from recursively starting a run.
        verification_argv = ("make", "verify-prearchive")
        subprocess.run(verification_argv, cwd=source, env=environment, check=True)
        design = build_design_manifest(source)
        design_bundle_sha256 = str(design["bundle_sha256"])
        member_manifest_sha256 = str(design["member_manifest_sha256"])
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
        design_bundle_sha256=design_bundle_sha256,
        member_manifest_sha256=member_manifest_sha256,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write-receipt", action="store_true")
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    if args.receipt is not None and not args.write_receipt:
        raise RuntimeError("--receipt requires --write-receipt")
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
    if args.write_receipt:
        receipt_path = (
            args.receipt.resolve()
            if args.receipt is not None
            else default_receipt_path(archive)
        )
        receipt = extraction_receipt(
            archive,
            verification,
            datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        )
        validate_receipt(receipt)
        receipt_sha256 = write_receipt(receipt_path, receipt)
        print(
            "SOURCE_EXTRACTION_RECEIPT="
            + json.dumps(
                {"path": str(receipt_path), "sha256": receipt_sha256}, sort_keys=True
            )
        )
    print("clean extraction verify-prearchive hard-gate verification: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
