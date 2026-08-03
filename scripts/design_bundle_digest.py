#!/usr/bin/env python3
"""Build the canonical, path-and-byte-bound Gurinnae design bundle digest.

The bundle is discovered from categories.  It deliberately does not use a
hand-maintained tuple of files: a newly added normative overlay, schema,
generator, validator, or supplemental acceptance file is included on the next
run. Review records and runtime receipts are excluded because they attest to
bytes that must already have been frozen. Runtime evidence lives in an external
append-only evidence root and may only point back to this digest.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import stat
from dataclasses import asdict, dataclass
from pathlib import Path, PurePosixPath
from typing import Iterable

from git_authority import (
    AUTHORITY_COMMIT_OID,
    AUTHORITY_TAG,
    AUTHORITY_TREE_OID,
    AUTHORITY_ZIP_SHA256,
    GitAuthorityError,
    authority_paths,
)


ROOT = Path(__file__).resolve().parents[1]
BUNDLE_DOMAIN = b"GURINNAE-DESIGN-BUNDLE-V2\0"
IGNORED_PARTS = frozenset(
    {".git", "__pycache__", "node_modules", "target", ".svelte-kit", "dist", "coverage"}
)
DESIGN_EVIDENCE_INPUTS = frozenset(
    {
        "implementation-evidence/design-domain-closure.yaml",
        "implementation-evidence/design-screen-closure.yaml",
        "implementation-evidence/expert-review-roles.yaml",
        "implementation-evidence/supplemental-acceptance-registry.yaml",
    }
)
FORBIDDEN_SOURCE_EVIDENCE_PATTERNS = (
    "verification/acceptance/**/*",
    "test-results/acceptance/**/*",
    "implementation-evidence/runtime-receipts/**/*",
)


@dataclass(frozen=True)
class Member:
    category: str
    path: str
    size: int
    sha256: str


class BundleError(RuntimeError):
    """The bundle cannot be discovered without guessing."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _safe_relative(value: str) -> bool:
    path = PurePosixPath(value)
    return bool(
        value
        and "\\" not in value
        and not path.is_absolute()
        and ".." not in path.parts
        and value == path.as_posix()
    )


def authority_tag_paths(root: Path = ROOT) -> set[str]:
    """Return the baseline path set from the pinned Git tree."""

    try:
        return set(authority_paths(root))
    except GitAuthorityError as error:
        raise BundleError(f"Git authority is unreadable: {error}") from error


def _regular_files(root: Path, pattern: str) -> Iterable[Path]:
    for path in root.glob(pattern):
        relative_parts = path.relative_to(root).parts
        if any(part in IGNORED_PARTS for part in relative_parts) or path.suffix == ".pyc":
            continue
        if path.is_symlink():
            raise BundleError(f"bundle member must not be a symlink: {path}")
        if path.is_file():
            mode = path.stat().st_mode
            if not stat.S_ISREG(mode):
                raise BundleError(f"bundle member is not regular: {path}")
            yield path


def _add(
    root: Path,
    selected: dict[str, str],
    category: str,
    paths: Iterable[Path],
) -> None:
    for path in paths:
        relative = path.relative_to(root).as_posix()
        if not _safe_relative(relative):
            raise BundleError(f"unsafe bundle path: {relative}")
        previous = selected.get(relative)
        if previous is not None and previous != category:
            # Category precedence is explicit and stable; a path is hashed once.
            continue
        selected[relative] = category


def discover_member_paths(root: Path = ROOT) -> dict[str, str]:
    root = root.resolve()
    base_paths = authority_tag_paths(root)
    selected: dict[str, str] = {}

    runtime_residue = sorted(
        {
            path.relative_to(root).as_posix()
            for pattern in FORBIDDEN_SOURCE_EVIDENCE_PATTERNS
            for path in _regular_files(root, pattern)
        }
    )
    if runtime_residue:
        raise BundleError(
            "runtime acceptance evidence must be outside the source tree: "
            + ", ".join(runtime_residue)
        )

    required_core = {
        ".config/nextest.toml": "acceptance_execution_contract",
        "Makefile": "acceptance_execution_contract",
        "DESIGN.md": "product_constitution",
        "crates/test-support/Cargo.toml": "acceptance_execution_contract",
        "crates/test-support/src/acceptance_observation.rs": "acceptance_execution_contract",
        "crates/test-support/src/lib.rs": "acceptance_execution_contract",
        "implementation-evidence/spec-conflicts.md": "design_closure_evidence",
        "implementation-evidence/expert-review-prompt.md": "design_closure_evidence",
        "implementation-evidence/design-screen-closure.yaml": "design_closure_evidence",
        "implementation-evidence/design-domain-closure.yaml": "design_closure_evidence",
        "implementation-evidence/design-freeze-contract.md": "freeze_contract",
        "infra/docker/dev/Dockerfile": "acceptance_execution_contract",
        "infra/docker/rust-service/Dockerfile": "acceptance_execution_contract",
        "infra/images.lock": "acceptance_execution_contract",
        "scripts/create_source_archive.py": "acceptance_execution_contract",
        "scripts/generate_acceptance_design_registry.py": "acceptance_execution_contract",
        "scripts/generate_effective_execution_registry.py": "acceptance_execution_contract",
        "scripts/run_acceptance.py": "acceptance_execution_contract",
        "scripts/run_acceptance_assertion_mutations.py": "acceptance_execution_contract",
        "scripts/source_provenance.py": "acceptance_execution_contract",
        "scripts/validation/acceptance_gherkin.py": "acceptance_execution_contract",
        "scripts/validation/effective_acceptance.py": "acceptance_execution_contract",
        "scripts/verify_source_archive.py": "acceptance_execution_contract",
        "tests/acceptance/base-v13.lock.yaml": "authority_base_proof",
        "scripts/git_authority.py": "authority_base_proof",
        "scripts/verify_base_acceptance_lock.py": "authority_base_proof",
    }
    for relative, category in required_core.items():
        path = root / relative
        if path.is_symlink() or not path.is_file():
            raise BundleError(f"required bundle member is missing: {relative}")
        selected[relative] = category

    for path in _regular_files(root, "implementation-evidence/*authority*.md"):
        selected[path.relative_to(root).as_posix()] = "authority_base_proof"
    for path in _regular_files(root, "implementation-evidence/*business-model*.md"):
        selected[path.relative_to(root).as_posix()] = "business_addenda"

    # Every new file under specs is normative.  Derive its category from the
    # first domain component rather than maintaining a domain allowlist: a new
    # connector, procurement/domain, lifecycle, or traceability overlay must
    # change the digest on its first appearance.
    for path in _regular_files(root, "specs/**/*"):
        relative_path = path.relative_to(root)
        relative = relative_path.as_posix()
        if relative in base_paths:
            continue
        domain = relative_path.parts[1] if len(relative_path.parts) > 1 else "other"
        selected.setdefault(relative, f"{domain}_addenda")

    # Machine-readable design inputs are an explicit closed set. Runtime
    # receipts, logs and review attestations must never become members merely
    # because they were written below implementation-evidence/.
    for relative in sorted(DESIGN_EVIDENCE_INPUTS):
        path = root / relative
        if path.is_symlink() or not path.is_file():
            raise BundleError(f"required static design evidence is missing: {relative}")
        selected.setdefault(relative, "design_closure_evidence")

    # Supplemental acceptance is every acceptance member absent from v13.  This
    # includes feature, mapping, fixture, runner, and schema files.
    for path in _regular_files(root, "tests/acceptance/**/*"):
        relative = path.relative_to(root).as_posix()
        if relative not in base_paths:
            selected.setdefault(relative, "supplemental_acceptance")

    generator_patterns = (
        "scripts/generate_*.py",
        "scripts/finalize_*.py",
        "scripts/normalize_*.py",
        "scripts/design_bundle_digest.py",
        "scripts/validate_final_spec.py",
        "scripts/verify_*.py",
        "scripts/tests/test_*.py",
        "scripts/validation/*.py",
    )
    for pattern in generator_patterns:
        _add(root, selected, "generators_and_validators", _regular_files(root, pattern))

    review_members = [
        relative
        for relative in selected
        if "reviews" in PurePosixPath(relative).parts
        or PurePosixPath(relative).name
        in {
            "expert-review-status.md",
            "design-review-status.md",
            "implementation-review-status.md",
        }
    ]
    if review_members:
        raise BundleError(
            "review attestations cannot be members of the digest they review: "
            + ", ".join(review_members)
        )
    if not any(category.endswith("addenda") for category in selected.values()):
        raise BundleError("no normative addendum member was discovered")
    return dict(sorted(selected.items()))


def build_manifest(root: Path = ROOT) -> dict[str, object]:
    root = root.resolve()
    selected = discover_member_paths(root)
    members: list[Member] = []
    digest = hashlib.sha256(BUNDLE_DOMAIN)
    for relative, category in selected.items():
        content = (root / relative).read_bytes()
        encoded_path = relative.encode("utf-8")
        digest.update(len(encoded_path).to_bytes(4, "big"))
        digest.update(encoded_path)
        digest.update(len(content).to_bytes(8, "big"))
        digest.update(content)
        members.append(
            Member(
                category=category,
                path=relative,
                size=len(content),
                sha256=hashlib.sha256(content).hexdigest(),
            )
        )
    member_rows = [asdict(member) for member in members]
    canonical_members = json.dumps(
        member_rows, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    category_counts: dict[str, int] = {}
    for member in members:
        category_counts[member.category] = category_counts.get(member.category, 0) + 1
    selected_after = discover_member_paths(root)
    if selected_after != selected:
        raise BundleError("bundle membership changed while the digest was being calculated")
    for member in members:
        path = root / member.path
        try:
            changed = path.stat().st_size != member.size or sha256_file(path) != member.sha256
        except OSError as error:
            raise BundleError(f"bundle member became unreadable: {member.path}: {error}") from error
        if changed:
            raise BundleError(f"bundle member changed while hashing: {member.path}")
    return {
        "schema_version": 2,
        "algorithm": "sha256(domain || repeated(u32be(path_len), path_utf8, u64be(byte_len), exact_bytes))",
        "authority_tag": AUTHORITY_TAG,
        "authority_commit_oid": AUTHORITY_COMMIT_OID,
        "authority_tree_oid": AUTHORITY_TREE_OID,
        "authority_zip_sha256": AUTHORITY_ZIP_SHA256,
        "bundle_sha256": digest.hexdigest(),
        "member_manifest_sha256": hashlib.sha256(canonical_members).hexdigest(),
        "member_count": len(members),
        "category_counts": dict(sorted(category_counts.items())),
        "members": member_rows,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--manifest", action="store_true", help="print the canonical member manifest")
    parser.add_argument("--json-output", type=Path)
    args = parser.parse_args()
    try:
        manifest = build_manifest(args.root)
    except BundleError as error:
        print(f"DESIGN_BUNDLE: FAIL: {error}")
        return 1
    rendered = json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
    if args.json_output is not None:
        args.json_output.write_text(rendered, encoding="utf-8")
    if args.manifest:
        print(rendered, end="")
    else:
        print(manifest["bundle_sha256"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
