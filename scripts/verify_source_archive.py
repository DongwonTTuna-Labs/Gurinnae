#!/usr/bin/env python3
"""Safely extract and independently run every hard gate on the source archive."""

from __future__ import annotations

import hashlib
import os
import subprocess
import tarfile
import tempfile
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ARCHIVE = ROOT / "artifacts" / "gurine-source-v13.0.0.tar.gz"
DEFAULT_EXTRACTION_ROOT = Path("/var/tmp")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_sidecar(archive: Path) -> None:
    sidecar = Path(f"{archive}.sha256")
    if not sidecar.is_file():
        raise RuntimeError(f"source archive sidecar missing: {sidecar}")
    fields = sidecar.read_text(encoding="utf-8").strip().split()
    if len(fields) != 2 or fields[1] != archive.name:
        raise RuntimeError("source archive sidecar format is invalid")
    actual = sha256(archive)
    if fields[0] != actual:
        raise RuntimeError(f"source archive checksum differs: {fields[0]} != {actual}")


def inspect(archive: Path) -> None:
    with tarfile.open(archive, "r:gz") as package:
        members = package.getmembers()
        names = [member.name for member in members]
        if len(names) != len(set(names)):
            raise RuntimeError("source archive contains duplicate paths")
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
                raise RuntimeError(f"source archive links/special files forbidden: {member.name}")


def verify_manifest(source: Path) -> None:
    subprocess.run(
        ["sha256sum", "--quiet", "--check", "MANIFEST.sha256"],
        cwd=source,
        check=True,
    )
    listed = {
        line.split("  ", 1)[1]
        for line in (source / "MANIFEST.sha256").read_text(encoding="utf-8").splitlines()
        if line
    }
    actual = {
        path.relative_to(source).as_posix()
        for path in source.rglob("*")
        if path.is_file() and path.name not in {"MANIFEST.md", "MANIFEST.sha256"}
    }
    if listed != actual:
        missing = sorted(actual - listed)
        extra = sorted(listed - actual)
        raise RuntimeError(f"manifest member set differs: missing={missing} extra={extra}")


def main() -> int:
    archive = Path(os.environ.get("SOURCE_ARCHIVE", DEFAULT_ARCHIVE)).resolve()
    if not archive.is_file():
        raise RuntimeError(f"source archive missing: {archive}")
    extraction_root = Path(
        os.environ.get("GURINE_CLEAN_EXTRACTION_ROOT", DEFAULT_EXTRACTION_ROOT)
    ).resolve()
    if not extraction_root.is_dir():
        raise RuntimeError(f"clean extraction root missing: {extraction_root}")
    verify_sidecar(archive)
    inspect(archive)
    with tempfile.TemporaryDirectory(
        prefix="gurine-clean-extraction-", dir=extraction_root
    ) as temporary:
        destination = Path(temporary)
        with tarfile.open(archive, "r:gz") as package:
            package.extractall(destination, filter="data")
        source = destination / "source"
        verify_manifest(source)
        environment = os.environ.copy()
        environment["GURINE_CLEAN_EXTRACTION"] = "1"
        subprocess.run(["make", "verify-final"], cwd=source, env=environment, check=True)
    print("clean extraction full hard-gate verification: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
