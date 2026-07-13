#!/usr/bin/env python3
"""Create the single deterministic Gurine source-tree archive."""

from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


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
}
EXCLUDED_FILES = {
    ".env",
    ".env.local",
    ".env.production",
    ".env.test",
}


def excluded(relative: Path) -> bool:
    return (
        any(part in EXCLUDED_DIRECTORIES for part in relative.parts)
        or relative.name in EXCLUDED_FILES
        or relative.suffix in {".pyc", ".pyo"}
    )


def copy_source(destination: Path) -> None:
    for source in sorted(ROOT.rglob("*")):
        relative = source.relative_to(ROOT)
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


def main() -> int:
    ARTIFACTS.mkdir(exist_ok=True)
    temporary_archive = ARTIFACTS / f".{ARCHIVE.name}.{os.getpid()}.tmp"
    with tempfile.TemporaryDirectory(prefix="gurine-source-archive-") as temporary:
        temporary_root = Path(temporary)
        source = temporary_root / "source"
        source.mkdir()
        copy_source(source)
        environment = os.environ.copy()
        environment["GURINE_MANIFEST_ARCHIVE_ROOT"] = "source"
        subprocess.run(
            ["python3", "-B", "scripts/generate_manifest.py"],
            cwd=source,
            env=environment,
            check=True,
        )
        subprocess.run(["sha256sum", "--quiet", "--check", "MANIFEST.sha256"], cwd=source, check=True)
        try:
            create_tar(temporary_root, temporary_archive)
            os.replace(temporary_archive, ARCHIVE)
        finally:
            temporary_archive.unlink(missing_ok=True)

    digest = sha256(ARCHIVE)
    sidecar = Path(f"{ARCHIVE}.sha256")
    sidecar.write_text(f"{digest}  {ARCHIVE.name}\n", encoding="utf-8")
    print(f"source archive: {ARCHIVE}")
    print(f"sha256: {digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
