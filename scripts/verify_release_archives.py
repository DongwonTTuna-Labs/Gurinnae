#!/usr/bin/env python3
"""Verify Gurine final ZIP/TAR.GZ release archives and their sidecars."""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path, PurePosixPath


EXPECTED_ROOT = "gurine"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_member(name: str) -> bool:
    path = PurePosixPath(name)
    return (
        not path.is_absolute()
        and ".." not in path.parts
        and bool(path.parts)
        and path.parts[0] == EXPECTED_ROOT
    )


def verify_sidecar(path: Path) -> None:
    sidecar = Path(str(path) + ".sha256")
    if not sidecar.is_file():
        raise RuntimeError(f"Missing sidecar: {sidecar}")
    expected = sidecar.read_text(encoding="utf-8").strip().split()[0]
    actual = sha256(path)
    if expected != actual:
        raise RuntimeError(f"Archive checksum mismatch: {path.name}: {expected} != {actual}")


def inspect_zip(path: Path) -> list[str]:
    with zipfile.ZipFile(path) as archive:
        bad = archive.testzip()
        if bad:
            raise RuntimeError(f"ZIP CRC failure: {bad}")
        names = [info.filename for info in archive.infolist()]
        if len(names) != len(set(names)):
            raise RuntimeError("ZIP contains duplicate member names")
        for info in archive.infolist():
            if not safe_member(info.filename):
                raise RuntimeError(f"Unsafe ZIP member: {info.filename}")
            mode = (info.external_attr >> 16) & 0xFFFF
            if stat.S_ISLNK(mode):
                raise RuntimeError(f"ZIP symlink forbidden: {info.filename}")
        return sorted(name for name in names if not name.endswith("/"))


def inspect_tar(path: Path) -> list[str]:
    with tarfile.open(path, "r:gz") as archive:
        names = [member.name for member in archive.getmembers()]
        if len(names) != len(set(names)):
            raise RuntimeError("TAR contains duplicate member names")
        for member in archive.getmembers():
            if not safe_member(member.name):
                raise RuntimeError(f"Unsafe TAR member: {member.name}")
            if member.issym() or member.islnk() or member.isdev():
                raise RuntimeError(f"TAR link/device forbidden: {member.name}")
        return sorted(member.name for member in archive.getmembers() if member.isfile())


def run(command: list[str], cwd: Path) -> None:
    process = subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(process.stdout, end="")
    if process.returncode:
        raise RuntimeError(f"Command failed ({process.returncode}): {' '.join(command)}")


def verify_extracted(root: Path) -> None:
    project = root / EXPECTED_ROOT
    if not project.is_dir():
        raise RuntimeError(f"Archive root {EXPECTED_ROOT}/ is missing")
    run([sys.executable, "-B", "scripts/validate_final_spec.py", "--strict"], project)
    run(["sha256sum", "--quiet", "--check", "MANIFEST.sha256"], project)


def tree_digest(root: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    files = sorted(path for path in root.rglob("*") if path.is_file())
    for path in files:
        relative = path.relative_to(root).as_posix().encode("utf-8")
        data = path.read_bytes()
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)
    return digest.hexdigest(), len(files)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("archives", nargs="*", type=Path)
    args = parser.parse_args()

    archives = [path.resolve() for path in args.archives]
    if not archives:
        parent = Path(__file__).resolve().parents[2]
        archives = sorted(parent.glob("gurine-codex-authority-pack-v13.0.0-*.zip"))
        archives += sorted(parent.glob("gurine-codex-authority-pack-v13.0.0-*.tar.gz"))

    if not archives:
        parser.error("Pass ZIP/TAR.GZ archive paths or place release archives beside the source directory")

    extracted_digests: dict[str, tuple[str, int]] = {}
    member_sets: dict[str, list[str]] = {}

    for archive in archives:
        if not archive.is_file():
            raise RuntimeError(f"Archive not found: {archive}")
        verify_sidecar(archive)
        if archive.suffix == ".zip":
            members = inspect_zip(archive)
        elif archive.name.endswith(".tar.gz"):
            members = inspect_tar(archive)
        else:
            raise RuntimeError(f"Unsupported archive: {archive}")
        member_sets[archive.name] = members

        with tempfile.TemporaryDirectory(prefix="gurine-release-verify-") as temporary:
            target = Path(temporary)
            if archive.suffix == ".zip":
                with zipfile.ZipFile(archive) as package:
                    package.extractall(target)
            else:
                with tarfile.open(archive, "r:gz") as package:
                    package.extractall(target, filter="data")
            verify_extracted(target)
            extracted_digests[archive.name] = tree_digest(target / EXPECTED_ROOT)

    if len(member_sets) > 1:
        first_name, first_members = next(iter(member_sets.items()))
        for name, members in member_sets.items():
            if members != first_members:
                raise RuntimeError(f"Archive member set differs: {first_name} vs {name}")

        first_name, first_digest = next(iter(extracted_digests.items()))
        for name, digest in extracted_digests.items():
            if digest != first_digest:
                raise RuntimeError(f"Extracted tree differs: {first_name} vs {name}")

    for name, (digest, count) in extracted_digests.items():
        print(f"{name}: files={count} tree_sha256={digest}")
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
