from __future__ import annotations

import hashlib
from pathlib import Path

from git_authority import GitAuthorityError, authority_file

from .models import Validation


def _frozen_bytes(
    root: Path, relative_path: str, unavailable_message: str, result: Validation
) -> bytes | None:
    try:
        return authority_file(relative_path, root)
    except GitAuthorityError as error:
        result.error(f"{unavailable_message}: {error}")
        return None


def validate_frozen_base_feature(
    root: Path,
    name: str,
    expected_digest: object,
    expected_size: object,
    result: Validation,
) -> None:
    frozen = _frozen_bytes(
        root,
        f"tests/acceptance/{name}",
        f"{name}: frozen base feature is unavailable",
        result,
    )
    if frozen is None:
        return
    result.require(
        expected_digest == hashlib.sha256(frozen).hexdigest()
        and expected_size == len(frozen),
        f"{name}: locked base feature bytes differ from frozen tag",
    )


def validate_frozen_base_registry(
    root: Path, name: str, expected_digest: object, result: Validation
) -> None:
    frozen = _frozen_bytes(
        root,
        f"tests/acceptance/{name}",
        f"{name}: frozen base registry is unavailable",
        result,
    )
    if frozen is None:
        return
    result.require(
        expected_digest == hashlib.sha256(frozen).hexdigest(),
        f"{name}: locked registry bytes differ from frozen tag",
    )


def validate_frozen_base_lock(
    root: Path, lock_path: Path, lock_name: str, result: Validation
) -> None:
    frozen = _frozen_bytes(
        root,
        f"tests/acceptance/{lock_name}",
        f"{lock_name}: frozen descriptor is unavailable",
        result,
    )
    if frozen is None:
        return
    result.require(
        lock_path.is_file()
        and not lock_path.is_symlink()
        and lock_path.read_bytes() == frozen,
        f"{lock_name}: descriptor differs from frozen tag",
    )
