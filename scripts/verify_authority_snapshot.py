#!/usr/bin/env python3
"""Verify the immutable v13 authority snapshot shipped with the source tree."""
from __future__ import annotations

import hashlib
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SNAPSHOT = ROOT / "authority-v13"
AUTHORITY_ZIP_SHA256 = "960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    manifest = SNAPSHOT / "MANIFEST.sha256"
    if not manifest.is_file():
        raise SystemExit("authority-v13/MANIFEST.sha256 is missing")
    subprocess.run(["sha256sum", "--quiet", "--check", str(manifest)], cwd=SNAPSHOT, check=True)
    expected = {
        "specs/ui/screen-catalog.yaml": "e2dc57a4b6092105b088b84723456037bf2892f168afd542056c23284e6bff2b",
        "specs/ui/screen-build-manifest.yaml": "4862de1453b12a09ac775edef0414d057476dfc56b5dced9c17824b980fa7624",
        "specs/ui/screen-data-contracts.yaml": "665495729bd5a6ecfb8828583689a5ffc3ed18642b8d4aa7690da1834c1d987a",
    }
    for relative, digest in expected.items():
        actual = sha256(SNAPSHOT / relative)
        if actual != digest:
            raise SystemExit(f"authority digest mismatch: {relative}: {actual}")
    print(f"AUTHORITY_SNAPSHOT_PASS zip_sha256={AUTHORITY_ZIP_SHA256}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
