#!/usr/bin/env python3
"""Verify the sole v13 authority archive and isolate additive implementation files."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
from dataclasses import asdict, dataclass
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_AUTHORITY_ZIP = Path(
    os.environ.get(
        "GURINNAE_AUTHORITY_ZIP",
        "/home/dongwonttuna/.codex/attachments/"
        "29aa0c62-686a-450b-84aa-944e5cb7d47a/"
        "gurine-codex-authority-pack-v13.0.0-20260712.zip",
    )
)
AUTHORITY_ZIP_SHA256 = (
    "960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5"
)
AUTHORITY_MANIFEST_SHA256 = (
    "6e693b427c3dc048193d62936b0bd9cc66bb79396605ccaf9f9b9b967c964028"
)
AUTHORITY_MANIFEST_COUNT = 1_230
AUTHORITY_TREE_SHA256 = (
    "3136450c3d01f950e123ab52813c3992cd7239f1e691166e6694669cffe13f98"
)
AUTHORITY_ARCHIVE_ROOT = "gurine"
BASE_MIGRATION_COUNT = 24
FINAL_MIGRATION_COUNT = 30
RESERVED_DESIGN_MIGRATION_ORDINALS = tuple(range(25, 30))
EXPECTED_ADDITIVE_MIGRATIONS = (
    "0025_evidence_snapshots_and_search.sql",
    "0026_agent_action_approval.sql",
    "0027_communication_consent_delivery.sql",
    "0028_governance_operations.sql",
    "0029_product_economics.sql",
    "0030_v13_submission_session_hardening.sql",
)
MIGRATION_PATTERN = re.compile(r"^(?P<ordinal>[0-9]{4})_[a-z0-9_]+\.sql$")

@dataclass(frozen=True)
class Problem:
    kind: str
    path: str
    expected: str
    actual: str


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_relative_path(value: str) -> bool:
    path = PurePosixPath(value)
    return bool(
        value
        and "\\" not in value
        and not path.is_absolute()
        and ".." not in path.parts
        and path.as_posix() == value
    )


def parse_manifest(data: bytes, problems: list[Problem]) -> dict[str, str]:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        problems.append(Problem("manifest_encoding", "MANIFEST.sha256", "UTF-8", str(error)))
        return {}
    if not text.endswith("\n"):
        problems.append(Problem("manifest_newline", "MANIFEST.sha256", "final LF", "missing"))
    entries: dict[str, str] = {}
    for line_number, line in enumerate(text.splitlines(), start=1):
        fields = line.split("  ", 1)
        if len(fields) != 2 or not re.fullmatch(r"[0-9a-f]{64}", fields[0]):
            problems.append(
                Problem("manifest_line", f"MANIFEST.sha256:{line_number}", "sha256  path", line)
            )
            continue
        digest, relative = fields
        if not safe_relative_path(relative):
            problems.append(
                Problem("manifest_path", f"MANIFEST.sha256:{line_number}", "safe relative path", relative)
            )
            continue
        if relative in entries:
            problems.append(
                Problem("manifest_duplicate", relative, "one entry", "duplicate")
            )
            continue
        entries[relative] = digest
    return entries


def tree_digest(entries: list[tuple[str, str]]) -> str:
    digest = hashlib.sha256()
    for relative, file_digest in entries:
        encoded = relative.encode("utf-8")
        digest.update(len(encoded).to_bytes(4, "big"))
        digest.update(encoded)
        digest.update(bytes.fromhex(file_digest))
    return digest.hexdigest()


def verify_archive_post_digest(
    authority_zip: Path,
    before_digest: str,
    problems: list[Problem],
    stats: dict[str, object],
) -> None:
    try:
        after_digest = sha256_file(authority_zip)
    except OSError as error:
        problems.append(
            Problem(
                "archive_post_sha256",
                str(authority_zip),
                before_digest,
                str(error),
            )
        )
        return
    stats["authority_zip_sha256_after"] = after_digest
    if after_digest != before_digest:
        problems.append(
            Problem(
                "archive_changed_during_verification",
                str(authority_zip),
                before_digest,
                after_digest,
            )
        )


def verify_archive(
    authority_zip: Path, problems: list[Problem], stats: dict[str, object]
) -> dict[str, str]:
    if not authority_zip.is_file():
        problems.append(
            Problem("archive_missing", str(authority_zip), AUTHORITY_ZIP_SHA256, "missing")
        )
        return {}
    archive_digest = sha256_file(authority_zip)
    stats["authority_zip_sha256"] = archive_digest
    stats["authority_zip_sha256_before"] = archive_digest
    if archive_digest != AUTHORITY_ZIP_SHA256:
        problems.append(
            Problem("archive_sha256", str(authority_zip), AUTHORITY_ZIP_SHA256, archive_digest)
        )
        return {}

    with zipfile.ZipFile(authority_zip) as archive:
        infos = archive.infolist()
        names = [info.filename for info in infos]
        if len(names) != len(set(names)):
            problems.append(Problem("archive_duplicate", str(authority_zip), "unique paths", "duplicates"))
        for info in infos:
            if not safe_relative_path(info.filename.rstrip("/")):
                problems.append(
                    Problem("archive_path", info.filename, "safe relative path", info.filename)
                )
            mode = (info.external_attr >> 16) & 0xFFFF
            if stat.S_IFMT(mode) == stat.S_IFLNK:
                problems.append(Problem("archive_symlink", info.filename, "regular file", "symlink"))

        manifest_member = f"{AUTHORITY_ARCHIVE_ROOT}/MANIFEST.sha256"
        try:
            manifest_data = archive.read(manifest_member)
        except KeyError:
            problems.append(Problem("archive_manifest", manifest_member, "present", "missing"))
            verify_archive_post_digest(
                authority_zip,
                archive_digest,
                problems,
                stats,
            )
            return {}
        manifest_digest = sha256_bytes(manifest_data)
        stats["authority_manifest_sha256"] = manifest_digest
        if manifest_digest != AUTHORITY_MANIFEST_SHA256:
            problems.append(
                Problem(
                    "manifest_sha256",
                    manifest_member,
                    AUTHORITY_MANIFEST_SHA256,
                    manifest_digest,
                )
            )
        manifest = parse_manifest(manifest_data, problems)
        stats["authority_manifest_entries"] = len(manifest)
        if len(manifest) != AUTHORITY_MANIFEST_COUNT:
            problems.append(
                Problem(
                    "manifest_count",
                    manifest_member,
                    str(AUTHORITY_MANIFEST_COUNT),
                    str(len(manifest)),
                )
            )

        expected_files = {
            f"{AUTHORITY_ARCHIVE_ROOT}/{relative}" for relative in manifest
        } | {
            f"{AUTHORITY_ARCHIVE_ROOT}/MANIFEST.md",
            manifest_member,
        }
        actual_files = {info.filename for info in infos if not info.is_dir()}
        if actual_files != expected_files:
            missing = sorted(expected_files - actual_files)
            extra = sorted(actual_files - expected_files)
            problems.append(
                Problem("archive_file_set", str(authority_zip), str(missing), str(extra))
            )

        matched = 0
        for relative, expected in manifest.items():
            member = f"{AUTHORITY_ARCHIVE_ROOT}/{relative}"
            try:
                actual = sha256_bytes(archive.read(member))
            except KeyError:
                continue
            if actual != expected:
                problems.append(Problem("archive_member_sha256", relative, expected, actual))
            else:
                matched += 1
        stats["authority_archive_members_matched"] = matched
        authority_tree_sha256 = tree_digest(list(manifest.items()))
        stats["authority_tree_sha256"] = authority_tree_sha256
        if authority_tree_sha256 != AUTHORITY_TREE_SHA256:
            problems.append(
                Problem(
                    "authority_tree_sha256",
                    manifest_member,
                    AUTHORITY_TREE_SHA256,
                    authority_tree_sha256,
                )
            )
        verify_archive_post_digest(
            authority_zip,
            archive_digest,
            problems,
            stats,
        )
        return manifest


def source_files(root: Path) -> set[str]:
    if (root / ".git").is_dir():
        result = subprocess.run(
            ["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            check=True,
            stdout=subprocess.PIPE,
        )
        return {
            value.decode("utf-8")
            for value in result.stdout.split(b"\0")
            if value
        }
    ignored = {".git", "node_modules", "target", ".svelte-kit", "dist", "coverage", "__pycache__"}
    return {
        path.relative_to(root).as_posix()
        for path in root.rglob("*")
        if path.is_file() and not any(part in ignored for part in path.relative_to(root).parts)
    }


def verify_worktree(
    root: Path,
    manifest: dict[str, str],
    problems: list[Problem],
    stats: dict[str, object],
) -> None:
    matched = 0
    missing = 0
    mismatched = 0
    for relative, expected in manifest.items():
        path = root / relative
        if path.is_symlink() or not path.is_file():
            problems.append(Problem("authority_base_missing", relative, expected, "missing"))
            missing += 1
            continue
        actual = sha256_file(path)
        if actual != expected:
            problems.append(Problem("authority_base_sha256", relative, expected, actual))
            mismatched += 1
        else:
            matched += 1
    stats["authority_worktree_matched"] = matched
    stats["authority_worktree_missing"] = missing
    stats["authority_worktree_mismatched"] = mismatched

    metadata = {"MANIFEST.md", "MANIFEST.sha256"}
    additions = sorted(source_files(root) - set(manifest) - metadata)
    additive_entries: list[tuple[str, str]] = []
    for relative in additions:
        path = root / relative
        if path.is_symlink() or not path.is_file():
            problems.append(Problem("additive_file_type", relative, "regular file", "non-regular"))
            continue
        additive_entries.append((relative, sha256_file(path)))
    stats["additive_source_files"] = len(additive_entries)
    stats["additive_source_tree_sha256"] = tree_digest(additive_entries)


def verify_migrations(
    root: Path,
    manifest: dict[str, str],
    problems: list[Problem],
    stats: dict[str, object],
    allow_pending_additive: bool,
) -> None:
    authority_migrations = {
        PurePosixPath(relative).name: (relative, digest)
        for relative, digest in manifest.items()
        if relative.startswith("specs/database/migrations/")
        and MIGRATION_PATTERN.fullmatch(PurePosixPath(relative).name)
    }
    if len(authority_migrations) != BASE_MIGRATION_COUNT:
        problems.append(
            Problem(
                "authority_migration_count",
                "specs/database/migrations",
                str(BASE_MIGRATION_COUNT),
                str(len(authority_migrations)),
            )
        )

    spec_directory = root / "specs/database/migrations"
    local_spec_base = {
        path.name: path
        for path in spec_directory.glob("*.sql")
        if (match := MIGRATION_PATTERN.fullmatch(path.name))
        and int(match.group("ordinal")) <= BASE_MIGRATION_COUNT
    }
    if set(local_spec_base) != set(authority_migrations):
        problems.append(
            Problem(
                "authority_migration_set",
                "specs/database/migrations",
                str(sorted(authority_migrations)),
                str(sorted(local_spec_base)),
            )
        )
    spec_matched = 0
    for name, (relative, expected) in authority_migrations.items():
        path = local_spec_base.get(name)
        if path is None:
            continue
        actual = sha256_file(path)
        if actual != expected:
            problems.append(Problem("authority_migration_sha256", relative, expected, actual))
        else:
            spec_matched += 1
    stats["authority_spec_migrations_matched"] = spec_matched

    runtime_directory = root / "db/migrations"
    runtime_files = sorted(runtime_directory.glob("*.sql"))
    runtime_base = {
        path.name: path
        for path in runtime_files
        if (match := MIGRATION_PATTERN.fullmatch(path.name))
        and int(match.group("ordinal")) <= BASE_MIGRATION_COUNT
    }
    if set(runtime_base) != set(authority_migrations):
        problems.append(
            Problem(
                "runtime_base_migration_set",
                "db/migrations",
                str(sorted(authority_migrations)),
                str(sorted(runtime_base)),
            )
        )
    runtime_base_entries: list[tuple[str, str]] = []
    runtime_matched = 0
    for name, (_, authority_digest) in authority_migrations.items():
        path = runtime_base.get(name)
        if path is None:
            continue
        actual = sha256_file(path)
        runtime_base_entries.append((f"db/migrations/{name}", actual))
        if actual != authority_digest:
            problems.append(
                Problem(
                    "runtime_base_migration_sha256",
                    f"db/migrations/{name}",
                    authority_digest,
                    actual,
                )
            )
        else:
            runtime_matched += 1
    stats["runtime_base_migrations_matched"] = runtime_matched
    stats["runtime_base_migration_tree_sha256"] = tree_digest(runtime_base_entries)

    additive: list[tuple[int, Path]] = []
    for path in runtime_files:
        match = MIGRATION_PATTERN.fullmatch(path.name)
        if match is None:
            problems.append(Problem("runtime_migration_name", path.name, "NNNN_slug.sql", path.name))
            continue
        ordinal = int(match.group("ordinal"))
        if ordinal > BASE_MIGRATION_COUNT:
            additive.append((ordinal, path))
    ordinals = [ordinal for ordinal, _ in additive]
    duplicates = sorted({ordinal for ordinal in ordinals if ordinals.count(ordinal) > 1})
    if duplicates:
        problems.append(
            Problem("additive_migration_ordinal", "db/migrations", "unique ordinals", str(duplicates))
        )
    hardening_name = "0030_v13_submission_session_hardening.sql"
    if hardening_name not in {path.name for _, path in additive}:
        problems.append(
            Problem("hardening_migration", f"db/migrations/{hardening_name}", "present", "missing")
        )
    if any(path.name == "0025_v13_submission_session_hardening.sql" for _, path in additive):
        problems.append(
            Problem(
                "reserved_migration_collision",
                "db/migrations/0025_v13_submission_session_hardening.sql",
                "absent; 0025-0029 reserved",
                "present",
            )
        )
    additive_entries = [
        (f"db/migrations/{path.name}", sha256_file(path)) for _, path in additive
    ]
    expected_additive_ordinals = set(range(BASE_MIGRATION_COUNT + 1, FINAL_MIGRATION_COUNT + 1))
    expected_additive_names = set(EXPECTED_ADDITIVE_MIGRATIONS)
    actual_additive_names = {path.name for _, path in additive}
    pending_additive_ordinals = sorted(expected_additive_ordinals - set(ordinals))
    unexpected_additive_ordinals = sorted(set(ordinals) - expected_additive_ordinals)
    pending_additive_names = sorted(expected_additive_names - actual_additive_names)
    unexpected_additive_names = sorted(actual_additive_names - expected_additive_names)
    stats["runtime_additive_migrations"] = [path.name for _, path in additive]
    stats["runtime_additive_migration_count"] = len(additive)
    stats["runtime_additive_migration_tree_sha256"] = tree_digest(additive_entries)
    stats["reserved_additive_ordinals"] = list(RESERVED_DESIGN_MIGRATION_ORDINALS)
    stats["expected_additive_ordinals"] = sorted(expected_additive_ordinals)
    stats["expected_additive_migrations"] = list(EXPECTED_ADDITIVE_MIGRATIONS)
    stats["pending_additive_ordinals"] = pending_additive_ordinals
    stats["unexpected_additive_ordinals"] = unexpected_additive_ordinals
    stats["pending_additive_migrations"] = pending_additive_names
    stats["unexpected_additive_migrations"] = unexpected_additive_names
    stats["allow_pending_additive"] = allow_pending_additive
    stats["expected_final_migration_count"] = FINAL_MIGRATION_COUNT
    if pending_additive_names and not allow_pending_additive:
        problems.append(
            Problem(
                "additive_migration_missing",
                "db/migrations",
                ",".join(EXPECTED_ADDITIVE_MIGRATIONS),
                "missing " + ",".join(pending_additive_names),
            )
        )
    if unexpected_additive_names:
        problems.append(
            Problem(
                "additive_migration_set",
                "db/migrations",
                ",".join(EXPECTED_ADDITIVE_MIGRATIONS),
                "unexpected " + ",".join(unexpected_additive_names),
            )
        )
    if unexpected_additive_ordinals:
        problems.append(
            Problem(
                "additive_migration_ordinal",
                "db/migrations",
                f"ordinals <= {FINAL_MIGRATION_COUNT:04d}",
                ",".join(f"{ordinal:04d}" for ordinal in unexpected_additive_ordinals),
            )
        )


def _populate_migration_fixture(
    fixture_root: Path,
    source_root: Path,
    authority_zip: Path,
    manifest: dict[str, str],
) -> None:
    spec_directory = fixture_root / "specs/database/migrations"
    runtime_directory = fixture_root / "db/migrations"
    spec_directory.mkdir(parents=True)
    runtime_directory.mkdir(parents=True)
    authority_migrations = {
        PurePosixPath(relative).name: relative
        for relative in manifest
        if relative.startswith("specs/database/migrations/")
        and MIGRATION_PATTERN.fullmatch(PurePosixPath(relative).name)
    }
    with zipfile.ZipFile(authority_zip) as archive:
        for name, relative in authority_migrations.items():
            authority_bytes = archive.read(f"{AUTHORITY_ARCHIVE_ROOT}/{relative}")
            (spec_directory / name).write_bytes(authority_bytes)
            (runtime_directory / name).write_bytes(authority_bytes)
    for name in EXPECTED_ADDITIVE_MIGRATIONS:
        (runtime_directory / name).write_bytes(b"-- isolated self-test migration\n")


def _write_synthetic_authority(
    path: Path,
    manifest_bytes: bytes,
    member_bytes: bytes,
) -> None:
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(f"{AUTHORITY_ARCHIVE_ROOT}/MANIFEST.sha256", manifest_bytes)
        archive.writestr(f"{AUTHORITY_ARCHIVE_ROOT}/MANIFEST.md", b"synthetic\n")
        archive.writestr(f"{AUTHORITY_ARCHIVE_ROOT}/fixture.txt", member_bytes)


def _synthetic_archive_contracts(temporary: Path) -> list[dict[str, object]]:
    global AUTHORITY_MANIFEST_COUNT
    global AUTHORITY_MANIFEST_SHA256
    global AUTHORITY_TREE_SHA256
    global AUTHORITY_ZIP_SHA256

    original_constants = (
        AUTHORITY_ZIP_SHA256,
        AUTHORITY_MANIFEST_SHA256,
        AUTHORITY_MANIFEST_COUNT,
        AUTHORITY_TREE_SHA256,
    )
    member_bytes = b"trusted fixture\n"
    member_digest = sha256_bytes(member_bytes)
    manifest_bytes = f"{member_digest}  fixture.txt\n".encode("utf-8")
    good_archive = temporary / "synthetic-good.zip"
    manifest_corruption = temporary / "synthetic-manifest-corruption.zip"
    member_corruption = temporary / "synthetic-member-corruption.zip"
    _write_synthetic_authority(good_archive, manifest_bytes, member_bytes)
    _write_synthetic_authority(
        manifest_corruption,
        f"{'0' * 64}  fixture.txt\n".encode("utf-8"),
        member_bytes,
    )
    _write_synthetic_authority(
        member_corruption,
        manifest_bytes,
        b"tampered fixture\n",
    )
    AUTHORITY_MANIFEST_COUNT = 1
    AUTHORITY_MANIFEST_SHA256 = sha256_bytes(manifest_bytes)
    AUTHORITY_TREE_SHA256 = tree_digest([("fixture.txt", member_digest)])
    results: list[dict[str, object]] = []
    try:
        AUTHORITY_ZIP_SHA256 = sha256_file(good_archive)
        good_problems: list[Problem] = []
        verify_archive(good_archive, good_problems, {})
        results.append(
            {
                "fixture": "synthetic-authority-control",
                "contract_held": not good_problems,
            }
        )

        AUTHORITY_ZIP_SHA256 = sha256_file(manifest_corruption)
        manifest_problems: list[Problem] = []
        verify_archive(manifest_corruption, manifest_problems, {})
        results.append(
            {
                "fixture": "internal-manifest-corruption",
                "contract_held": any(
                    problem.kind == "manifest_sha256"
                    for problem in manifest_problems
                ),
            }
        )

        AUTHORITY_ZIP_SHA256 = sha256_file(member_corruption)
        member_problems: list[Problem] = []
        verify_archive(member_corruption, member_problems, {})
        results.append(
            {
                "fixture": "internal-member-corruption",
                "contract_held": any(
                    problem.kind == "archive_member_sha256"
                    for problem in member_problems
                ),
            }
        )
    finally:
        (
            AUTHORITY_ZIP_SHA256,
            AUTHORITY_MANIFEST_SHA256,
            AUTHORITY_MANIFEST_COUNT,
            AUTHORITY_TREE_SHA256,
        ) = original_constants
    return results


def self_test(
    source_root: Path,
    authority_zip: Path,
) -> tuple[bool, list[dict[str, object]]]:
    results: list[dict[str, object]] = []
    archive_problems: list[Problem] = []
    archive_stats: dict[str, object] = {}
    manifest = verify_archive(authority_zip, archive_problems, archive_stats)
    authority_ready = bool(manifest) and not archive_problems

    with tempfile.TemporaryDirectory(prefix="gurinnae-authority-lock-self-test-") as directory:
        temporary = Path(directory)

        results.extend(_synthetic_archive_contracts(temporary))

        corrupted_archive = temporary / "corrupted-authority.zip"
        shutil.copyfile(authority_zip, corrupted_archive)
        archive_bytes = bytearray(corrupted_archive.read_bytes())
        if archive_bytes:
            archive_bytes[-1] ^= 0x01
        corrupted_archive.write_bytes(archive_bytes)
        corruption_problems: list[Problem] = []
        verify_archive(corrupted_archive, corruption_problems, {})
        results.append(
            {
                "fixture": "authority-archive-byte-corruption",
                "contract_held": any(
                    problem.kind == "archive_sha256" for problem in corruption_problems
                ),
            }
        )

        for fixture_name, mutation, expected_problem in (
            (
                "additive-migration-missing",
                "missing",
                "additive_migration_missing",
            ),
            (
                "additive-migration-wrong-name",
                "wrong-name",
                "additive_migration_set",
            ),
            (
                "additive-migration-duplicate-ordinal",
                "duplicate",
                "additive_migration_ordinal",
            ),
            (
                "additive-migration-excess-ordinal",
                "excess",
                "additive_migration_ordinal",
            ),
            (
                "hardening-migration-missing",
                "hardening-missing",
                "hardening_migration",
            ),
        ):
            fixture_root = temporary / mutation
            if authority_ready:
                _populate_migration_fixture(
                    fixture_root,
                    source_root,
                    authority_zip,
                    manifest,
                )
                runtime_directory = fixture_root / "db/migrations"
                first_additive = runtime_directory / EXPECTED_ADDITIVE_MIGRATIONS[0]
                if mutation == "missing":
                    first_additive.unlink()
                elif mutation == "wrong-name":
                    first_additive.rename(runtime_directory / "0025_wrong_name.sql")
                elif mutation == "duplicate":
                    (runtime_directory / "0025_duplicate.sql").write_bytes(b"-- duplicate\n")
                elif mutation == "excess":
                    (runtime_directory / "0031_excess.sql").write_bytes(b"-- excess\n")
                elif mutation == "hardening-missing":
                    (runtime_directory / EXPECTED_ADDITIVE_MIGRATIONS[-1]).unlink()
                migration_problems = []
                verify_migrations(
                    fixture_root,
                    manifest,
                    migration_problems,
                    {},
                    allow_pending_additive=False,
                )
                held = any(
                    problem.kind == expected_problem for problem in migration_problems
                )
            else:
                held = False
            results.append({"fixture": fixture_name, "contract_held": held})

        for fixture_name, target_kind, relative_target, expected_problem in (
            (
                "authority-spec-migration-byte-drift",
                "spec",
                "specs/database/migrations/0001_extensions_schemas_types.sql",
                "authority_migration_sha256",
            ),
            (
                "runtime-base-migration-byte-drift",
                "runtime",
                "db/migrations/0001_extensions_schemas_types.sql",
                "runtime_base_migration_sha256",
            ),
        ):
            fixture_root = temporary / target_kind
            if authority_ready:
                _populate_migration_fixture(
                    fixture_root,
                    source_root,
                    authority_zip,
                    manifest,
                )
                target = fixture_root / relative_target
                target.write_bytes(target.read_bytes() + b"\n-- drift\n")
                migration_problems: list[Problem] = []
                verify_migrations(
                    fixture_root,
                    manifest,
                    migration_problems,
                    {},
                    allow_pending_additive=False,
                )
                held = any(
                    problem.kind == expected_problem for problem in migration_problems
                )
            else:
                held = False
            results.append({"fixture": fixture_name, "contract_held": held})

        implementation_root = temporary / "implementation-change"
        if authority_ready:
            _populate_migration_fixture(
                implementation_root,
                source_root,
                authority_zip,
                manifest,
            )
            implementation_path = implementation_root / "services/new-runtime/src/lib.rs"
            implementation_path.parent.mkdir(parents=True)
            implementation_path.write_text(
                "#![forbid(unsafe_code)]\n",
                encoding="utf-8",
            )
            release_problems: list[Problem] = []
            release_stats: dict[str, object] = {"scope": "migrations"}
            verify_migrations(
                implementation_root,
                manifest,
                release_problems,
                release_stats,
                allow_pending_additive=False,
            )
            implementation_change_accepted = not release_problems
            authority_readme = next(
                relative
                for relative in manifest
                if relative == "README.md"
            )
            with zipfile.ZipFile(authority_zip) as archive:
                readme_bytes = archive.read(
                    f"{AUTHORITY_ARCHIVE_ROOT}/{authority_readme}"
                )
            readme_path = implementation_root / authority_readme
            readme_path.write_bytes(readme_bytes + b"\nimplementation change\n")
            diagnostic_problems: list[Problem] = []
            verify_worktree(
                implementation_root,
                manifest,
                diagnostic_problems,
                {},
            )
            diagnostic_reports_change = any(
                problem.kind == "authority_base_sha256"
                and problem.path == authority_readme
                for problem in diagnostic_problems
            )
        else:
            implementation_change_accepted = False
            diagnostic_reports_change = False
        results.append(
            {
                "fixture": "ordinary-implementation-source-change",
                "contract_held": implementation_change_accepted,
            }
        )
        results.append(
            {
                "fixture": "full-diagnostic-reports-source-change",
                "contract_held": diagnostic_reports_change,
            }
        )

    return (
        authority_ready and all(bool(row["contract_held"]) for row in results),
        results,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--authority-zip", type=Path, default=DEFAULT_AUTHORITY_ZIP)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument(
        "--scope",
        choices=("archive", "migrations", "full"),
        default="migrations",
        help=(
            "archive verifies the pinned authority package; migrations is the release "
            "authority/base-runtime gate; full additionally diagnoses worktree drift "
            "and is expected to fail after implementation changes"
        ),
    )
    parser.add_argument("--json-output", type=Path)
    parser.add_argument("--max-problems", type=int, default=50)
    parser.add_argument(
        "--allow-pending-additive",
        action="store_true",
        help=(
            "diagnostic only: allow reserved physical migrations 0025-0029 to be absent; "
            "0030 and exact filenames remain mandatory"
        ),
    )
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        passed, fixtures = self_test(
            args.root.resolve(),
            args.authority_zip.resolve(),
        )
        print(
            json.dumps(
                {
                    "self_test": "PASS" if passed else "FAIL",
                    "fixtures": fixtures,
                },
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )
        )
        print(f"SELF_TEST: {'PASS' if passed else 'FAIL'}")
        return 0 if passed else 1

    problems: list[Problem] = []
    stats: dict[str, object] = {"scope": args.scope}
    manifest = verify_archive(args.authority_zip.resolve(), problems, stats)
    if manifest and args.scope in {"migrations", "full"}:
        verify_migrations(
            args.root.resolve(),
            manifest,
            problems,
            stats,
            args.allow_pending_additive,
        )
    if manifest and args.scope == "full":
        verify_worktree(args.root.resolve(), manifest, problems, stats)

    payload = {
        "result": "PASS" if not problems else "FAIL",
        "stats": stats,
        "problem_count": len(problems),
        "problems": [asdict(problem) for problem in problems],
    }
    if args.json_output is not None:
        args.json_output.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    display = dict(payload)
    display["problems"] = display["problems"][: max(0, args.max_problems)]
    print(json.dumps(display, ensure_ascii=False, indent=2, sort_keys=True))
    if len(problems) > args.max_problems:
        print(f"... {len(problems) - args.max_problems} additional problems omitted")
    print(f"RESULT: {payload['result']}")
    return 0 if not problems else 1


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    raise SystemExit(main())
