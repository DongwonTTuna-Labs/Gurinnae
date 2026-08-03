#!/usr/bin/env python3
"""Create the single deterministic Gurine source-tree archive."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path

from archive_manifest import (
    source_tree_sha256,
    verify_archive_manifest,
    write_source_archive_manifest,
)


ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "artifacts"
ARCHIVE = ARTIFACTS / "gurine-source-v13.0.0.tar.gz"
EXCLUDED_DIRECTORIES = {
    ".git",
    ".svelte-kit",
    "artifacts",
    "build",
    "node_modules",
    "playwright-report",
    "target",
    "test-results",
    "__pycache__",
    ".fable-sol",
}
EXCLUDED_FILES = {
    ".env",
    ".env.local",
    ".env.production",
    ".env.test",
}
@dataclass(frozen=True)
class SourceArchiveCreation:
    archive_path: str
    sidecar_path: str
    archive_sha256: str
    manifest_sha256: str
    source_tree_sha256: str
    manifested_files: int
    manifested_bytes: int


def excluded(relative: Path) -> bool:
    return (
        any(part in EXCLUDED_DIRECTORIES for part in relative.parts)
        or relative.name in EXCLUDED_FILES
        or relative.suffix in {".pyc", ".pyo"}
    )


def copy_source(destination: Path, root: Path = ROOT) -> None:
    root = root.resolve()
    for source in sorted(root.rglob("*")):
        relative = source.relative_to(root)
        if excluded(relative):
            continue
        target = destination / relative
        if source.is_symlink():
            raise RuntimeError(f"source archive forbids links: {relative.as_posix()}")
        if source.is_dir():
            target.mkdir(parents=True, exist_ok=True)
        elif source.is_file():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        else:
            raise RuntimeError(f"source archive forbids special files: {relative.as_posix()}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def create_tar(source_parent: Path, output: Path) -> None:
    tar = subprocess.Popen(
        [
            "tar",
            "--sort=name",
            "--mtime=@0",
            "--owner=0",
            "--group=0",
            "--numeric-owner",
            "--format=posix",
            "--pax-option=delete=atime,delete=ctime",
            "-C",
            str(source_parent),
            "-cf",
            "-",
            "source",
        ],
        stdout=subprocess.PIPE,
    )
    if tar.stdout is None:
        raise RuntimeError("tar stdout was not created")
    with output.open("wb") as stream:
        gzip = subprocess.run(["gzip", "-n", "-9"], stdin=tar.stdout, stdout=stream, check=False)
    tar.stdout.close()
    tar_status = tar.wait()
    if tar_status != 0 or gzip.returncode != 0:
        raise RuntimeError(f"archive creation failed: tar={tar_status} gzip={gzip.returncode}")


def create_source_archive(
    root: Path = ROOT, archive: Path | None = None
) -> SourceArchiveCreation:
    root = root.resolve()
    if archive is None:
        archive = root / "artifacts" / ARCHIVE.name
    archive = archive.resolve()
    archive.parent.mkdir(parents=True, exist_ok=True)
    temporary_archive = archive.parent / f".{archive.name}.{os.getpid()}.tmp"
    with tempfile.TemporaryDirectory(prefix="gurine-source-archive-") as temporary:
        temporary_root = Path(temporary)
        source = temporary_root / "source"
        source.mkdir()
        copy_source(source, root)
        write_source_archive_manifest(source, "source")
        entries = verify_archive_manifest(source, "source")
        manifest_sha256 = sha256(source / "MANIFEST.sha256")
        try:
            create_tar(temporary_root, temporary_archive)
            os.replace(temporary_archive, archive)
        finally:
            temporary_archive.unlink(missing_ok=True)

    digest = sha256(archive)
    sidecar = Path(f"{archive}.sha256")
    sidecar.write_text(f"{digest}  {archive.name}\n", encoding="utf-8")
    return SourceArchiveCreation(
        archive_path=str(archive),
        sidecar_path=str(sidecar),
        archive_sha256=digest,
        manifest_sha256=manifest_sha256,
        source_tree_sha256=source_tree_sha256(entries),
        manifested_files=len(entries),
        manifested_bytes=sum(entry.size for entry in entries),
    )


def main() -> int:
    root = Path(os.environ.get("SOURCE_ROOT", ROOT))
    archive_value = os.environ.get("SOURCE_ARCHIVE")
    archive = Path(archive_value) if archive_value is not None else None
    creation = create_source_archive(root=root, archive=archive)
    print(f"SOURCE_ARCHIVE_CREATION={json.dumps(asdict(creation), sort_keys=True)}")
    print(f"source archive: {creation.archive_path}")
    print(f"sha256: {creation.archive_sha256}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
