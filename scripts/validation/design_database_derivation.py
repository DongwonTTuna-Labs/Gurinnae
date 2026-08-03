from __future__ import annotations

import hashlib
from pathlib import Path
import re
from typing import Any

from .design_database_support import PHYSICAL_TABLE_PATHS
from .models import Validation


def validate_derivation_hashes(
    root: Path,
    global_contract: dict[str, Any],
    result: Validation,
) -> None:
    snapshot = global_contract.get("relation_inventory", {}).get(
        "stable_derivation_snapshot", {}
    )
    snapshot_status = snapshot.get("snapshot_status")
    result.require(
        isinstance(snapshot_status, str)
        and bool(snapshot_status)
        and not snapshot_status.startswith("PENDING_"),
        "database stable derivation snapshot is not final",
    )
    pinned = snapshot.get("input_sha256")
    result.require(
        isinstance(pinned, dict),
        "database stable derivation snapshot input_sha256 must be a mapping",
    )
    if not isinstance(pinned, dict):
        return
    result.require(
        set(pinned) == set(PHYSICAL_TABLE_PATHS),
        "database stable derivation snapshot paths are not set-equal to physical fragments",
    )
    for relative in sorted(set(pinned) | set(PHYSICAL_TABLE_PATHS)):
        path = root / relative
        digest = pinned.get(relative)
        result.require(
            isinstance(digest, str)
            and re.fullmatch(r"[0-9a-f]{64}", digest) is not None,
            f"{relative}: stable derivation digest is not lowercase SHA-256",
        )
        result.require(
            path.is_file(),
            f"{relative}: stable derivation input is missing",
        )
        if path.is_file() and isinstance(digest, str):
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
            result.require(
                digest == actual,
                f"{relative}: stable derivation digest differs from exact current bytes",
            )
