#!/usr/bin/env python3
"""Run the complete acceptance scenario set and seal append-only evidence."""
from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import selectors
import stat
import subprocess
import sys
import time
from typing import Any

from jsonschema import Draft202012Validator

from design_bundle_digest import build_manifest as build_design_manifest
from create_source_archive import excluded as source_archive_excluded
from generate_effective_execution_registry import (
    BASE_MAPPING,
    CURRENT_EFFECTIVE_SCENARIO_COUNT,
    OUTPUT as EFFECTIVE_REGISTRY,
    SUPPLEMENTAL_MAPPING,
    canonical_sha256,
)
from generate_supplemental_execution_mapping import prerequisite_argv_for_scenario
from git_authority import AUTHORITY_ZIP_SHA256
from source_provenance import source_tree_digest, worktree_inventory
from validation.acceptance_machine import (
    MachineReportError,
    TerminalCounts,
    artifact_media_type,
    load_closed_json_bytes,
    parse_nextest_discovery,
    parse_nextest_junit,
    parse_playwright_report,
)
from validation.effective_acceptance import (
    ARGV_DOMAIN,
    PROBE_ARGV_DOMAIN,
    PROBE_FACTS_DOMAIN,
    RUN_AGGREGATE_DOMAIN,
    validate_external_evidence,
    validate_sources,
    validate_static,
)


ROOT = Path(__file__).resolve().parents[1]
RUN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
SEAL_DOMAIN = b"GURINNAE-ACCEPTANCE-SEAL-MEMBERS-V1\0"
DEFAULT_EVIDENCE_RELATIVE = Path("artifacts/acceptance")
SOURCE_BUNDLES_DIRECTORY = "source-bundles"
AUTO_ARCHIVE_NAME = "source.tar.gz"
AUTO_EXTRACTION_RECEIPT_NAME = "extraction-receipt.json"
AUTO_VERIFICATION_LOG_NAME = "verify-final.log"
EXTRACTION_RECEIPT_SCHEMA = Path(
    "specs/acceptance/extraction-receipt-v1.schema.json"
)
DATABASE_URL_ENVIRONMENTS = (
    "DATABASE_URL",
    "TEST_DATABASE_URL",
    "GURINNAE_DATABASE_URL",
    "ECONOMICS_DATABASE_URL",
    "BILLING_DATABASE_URL",
    "PROJECTOR_DATABASE_URL",
)
R6E_ROLE_USERS = {
    "ECONOMICS_DATABASE_URL": "gurine_economics_importer",
    "BILLING_DATABASE_URL": "gurine_billing_gateway",
    "PROJECTOR_DATABASE_URL": "gurine_public_projector",
}
R6E_SCENARIO_ROLE_ENVIRONMENTS = {
    "AC-BUSINESS_MODEL-042": ("ECONOMICS_DATABASE_URL",),
    "AC-BUSINESS_MODEL-043": ("ECONOMICS_DATABASE_URL",),
    "AC-BUSINESS_MODEL-044": ("BILLING_DATABASE_URL",),
    "AC-BUSINESS_MODEL-045": ("BILLING_DATABASE_URL",),
    "AC-BUSINESS_MODEL-046": ("BILLING_DATABASE_URL", "ECONOMICS_DATABASE_URL"),
    "AC-BUSINESS_MODEL-047": ("BILLING_DATABASE_URL", "PROJECTOR_DATABASE_URL"),
    "AC-BUSINESS_MODEL-048": ("BILLING_DATABASE_URL",),
}
PREREQUISITE_READY_KEYS = {
    "schema_version",
    "status",
    "scenario_id",
    "host",
    "port",
    "database",
    "container",
}
PREREQUISITE_CONTAINER_RE = re.compile(r"gurine-r6e-monetization-[0-9]+")


class AcceptanceRunError(RuntimeError):
    """The authoritative run cannot continue without inventing evidence."""


@dataclass(frozen=True)
class EffectiveScenarioCounts:
    base: int
    supplemental: int
    effective: int


@dataclass
class RuntimePrerequisiteLease:
    process: Any
    scenario_id: str
    host: str
    port: int
    database: str
    container: str
    _closed: bool = False

    def child_environment(self, base: dict[str, str]) -> dict[str, str]:
        environment = dict(base)
        for name in DATABASE_URL_ENVIRONMENTS:
            environment.pop(name, None)
        control_url = self._database_url("gurine_control_api")
        environment["GURINNAE_DATABASE_URL"] = control_url
        environment["DATABASE_URL"] = control_url
        for name in R6E_SCENARIO_ROLE_ENVIRONMENTS[self.scenario_id]:
            environment[name] = self._database_url(R6E_ROLE_USERS[name])
        return environment

    def _database_url(self, user: str) -> str:
        return f"postgresql://{user}@{self.host}:{self.port}/{self.database}"

    def close(self, successful: bool) -> None:
        if self._closed:
            return
        self._closed = True
        cleanup_error = _finish_prerequisite_process(
            self.process, self.scenario_id, self.container
        )
        if cleanup_error is not None and successful:
            raise AcceptanceRunError(cleanup_error)

    def __enter__(self) -> RuntimePrerequisiteLease:
        return self

    def __exit__(self, error_type: object, error: object, traceback: object) -> bool:
        self.close(error_type is None)
        return False


def effective_scenario_counts(
    registry: dict[str, Any],
) -> EffectiveScenarioCounts:
    """Derive runner totals from the validated registry and its scenario rows."""
    counts = registry.get("counts")
    scenarios = registry.get("scenarios")
    if not isinstance(counts, dict) or not isinstance(scenarios, list):
        raise AcceptanceRunError("acceptance registry count contract is missing")
    declared = (
        counts.get("base_scenarios"),
        counts.get("supplemental_scenarios"),
        counts.get("effective_scenarios"),
    )
    if any(type(value) is not int for value in declared):
        raise AcceptanceRunError("acceptance registry counts must be integers")
    derived = (
        sum(
            isinstance(row, dict) and row.get("origin") == "BASE_V13"
            for row in scenarios
        ),
        sum(
            isinstance(row, dict) and row.get("origin") == "SUPPLEMENTAL_V1"
            for row in scenarios
        ),
        len(scenarios),
    )
    if declared != derived or declared[2] != declared[0] + declared[1]:
        raise AcceptanceRunError(
            f"acceptance registry count mismatch: declared={declared!r} derived={derived!r}"
        )
    return EffectiveScenarioCounts(*declared)


def _redact_database_urls(content: bytes, environment: dict[str, str]) -> bytes:
    redacted = content
    for name in DATABASE_URL_ENVIRONMENTS:
        value = environment.get(name, "")
        if value:
            redacted = redacted.replace(value.encode("utf-8"), b"[REDACTED_DATABASE_URL]")
    return redacted


def _prerequisite_environment(base: dict[str, str]) -> dict[str, str]:
    environment = dict(base)
    for name in DATABASE_URL_ENVIRONMENTS:
        environment.pop(name, None)
    return environment


def _read_prerequisite_line(process: Any, timeout_seconds: int) -> bytes:
    if process.stdout is None:
        raise AcceptanceRunError("runtime prerequisite stdout pipe is unavailable")
    descriptor = process.stdout.fileno()
    deadline = time.monotonic() + timeout_seconds
    buffer = bytearray()
    with selectors.DefaultSelector() as selector:
        selector.register(descriptor, selectors.EVENT_READ)
        while b"\n" not in buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not selector.select(remaining):
                raise AcceptanceRunError("runtime prerequisite timed out before ready")
            chunk = os.read(descriptor, 4096)
            if not chunk:
                raise AcceptanceRunError("runtime prerequisite exited before ready")
            buffer.extend(chunk)
            if len(buffer) > 4096:
                raise AcceptanceRunError("runtime prerequisite ready response is oversized")
    line, separator, trailing = bytes(buffer).partition(b"\n")
    if not separator or trailing:
        raise AcceptanceRunError("runtime prerequisite ready response is not one closed line")
    return line


def _parse_prerequisite_ready(line: bytes, scenario_id: str) -> dict[str, object]:
    value = load_closed_json_bytes(line, f"{scenario_id} runtime prerequisite")
    if not isinstance(value, dict) or set(value) != PREREQUISITE_READY_KEYS:
        raise AcceptanceRunError("runtime prerequisite ready response keys differ")
    valid = (
        value.get("schema_version") == 1
        and value.get("status") == "READY"
        and value.get("scenario_id") == scenario_id
        and value.get("host") == "127.0.0.1"
        and type(value.get("port")) is int
        and 1 <= int(value["port"]) <= 65535
        and value.get("database") == "gurine_r6e_monetization"
        and isinstance(value.get("container"), str)
        and PREREQUISITE_CONTAINER_RE.fullmatch(str(value["container"]))
    )
    if not valid:
        raise AcceptanceRunError("runtime prerequisite ready identity differs")
    return value


def _expected_prerequisite_container(process: Any) -> str:
    process_id = getattr(process, "pid", None)
    if type(process_id) is not int or process_id <= 0:
        raise AcceptanceRunError("runtime prerequisite process identity is invalid")
    return f"gurine-r6e-monetization-{process_id}"


def _validate_prerequisite_container(
    ready: dict[str, object], process: Any
) -> str:
    expected = _expected_prerequisite_container(process)
    if ready.get("container") != expected:
        raise AcceptanceRunError("runtime prerequisite ready container differs")
    return expected


def _remove_prerequisite_container(container: str) -> str | None:
    if PREREQUISITE_CONTAINER_RE.fullmatch(container) is None:
        return "runtime prerequisite cleanup target is invalid"
    try:
        subprocess.run(
            ["docker", "container", "rm", "--force", container],
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=15,
        )
        inventory = subprocess.run(
            [
                "docker",
                "container",
                "ls",
                "--all",
                "--format",
                "{{.Names}}",
                "--filter",
                f"name=^/{container}$",
            ],
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "runtime prerequisite container cleanup failed"
    if inventory.returncode != 0 or (inventory.stdout or b"").strip():
        return "runtime prerequisite container cleanup failed"
    return None


def _abort_prerequisite_process(process: Any, container: str) -> str | None:
    try:
        process.communicate(input=b"\n", timeout=10)
    except (BrokenPipeError, OSError, subprocess.TimeoutExpired):
        try:
            process.terminate()
        except OSError:
            pass
        try:
            process.communicate(timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            try:
                process.kill()
                process.communicate(timeout=10)
            except (OSError, subprocess.TimeoutExpired):
                pass
    return _remove_prerequisite_container(container)


def _finish_prerequisite_process(
    process: Any, scenario_id: str, container: str
) -> str | None:
    process_cleanup_failed = False
    try:
        stdout, _ = process.communicate(input=b"\n", timeout=30)
    except (BrokenPipeError, OSError, subprocess.TimeoutExpired):
        process_cleanup_failed = True
        stdout = b""
        try:
            process.kill()
            process.communicate(timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            pass
    container_cleanup_error = _remove_prerequisite_container(container)
    if (
        process_cleanup_failed
        or process.returncode != 0
        or (stdout or b"").strip()
        or container_cleanup_error is not None
    ):
        return f"runtime prerequisite cleanup failed for {scenario_id}"
    return None


def open_runtime_prerequisite(
    root: Path,
    row: dict[str, Any],
    base_environment: dict[str, str],
    timeout_seconds: int,
) -> RuntimePrerequisiteLease | None:
    scenario_id = str(row["scenario_id"])
    execution = row.get("execution", {})
    argv = execution.get("prerequisite_argv") if isinstance(execution, dict) else None
    if argv is None:
        return None
    expected = prerequisite_argv_for_scenario(scenario_id)
    if argv != expected or not isinstance(argv, list):
        raise AcceptanceRunError(f"runtime prerequisite argv differs: {scenario_id}")
    try:
        process = subprocess.Popen(
            argv,
            cwd=root,
            env=_prerequisite_environment(base_environment),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
    except OSError as error:
        raise AcceptanceRunError(
            f"runtime prerequisite could not start for {scenario_id}"
        ) from error
    expected_container = _expected_prerequisite_container(process)
    try:
        ready = _parse_prerequisite_ready(
            _read_prerequisite_line(process, timeout_seconds), scenario_id
        )
        container = _validate_prerequisite_container(ready, process)
    except (AcceptanceRunError, MachineReportError, OSError, ValueError) as error:
        cleanup_error = _abort_prerequisite_process(process, expected_container)
        if cleanup_error is not None:
            raise AcceptanceRunError(cleanup_error) from error
        raise
    return RuntimePrerequisiteLease(
        process=process,
        scenario_id=scenario_id,
        host=str(ready["host"]),
        port=int(ready["port"]),
        database=str(ready["database"]),
        container=container,
    )


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def sha256_bytes(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_relative(value: str) -> bool:
    path = PurePosixPath(value)
    return bool(
        value
        and "\\" not in value
        and not path.is_absolute()
        and ".." not in path.parts
        and path.as_posix() == value
    )


def symlink_free_path(path: Path) -> bool:
    if not path.is_absolute():
        return False
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        try:
            metadata = current.lstat()
        except OSError:
            return False
        if stat.S_ISLNK(metadata.st_mode):
            return False
    return True


def git_ignored_path(path: Path, source_root: Path) -> bool:
    try:
        relative = path.relative_to(source_root).as_posix()
    except ValueError:
        return False
    if not relative or relative == ".":
        return False
    environment = dict(os.environ)
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    result = subprocess.run(
        ["git", "-C", str(source_root), "check-ignore", "--quiet", "--", relative],
        check=False,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=environment,
    )
    return result.returncode == 0


def evidence_path_allowed(path: Path, source_root: Path) -> bool:
    try:
        resolved = path.resolve(strict=True)
        source = source_root.resolve(strict=True)
    except OSError:
        return False
    if not symlink_free_path(path):
        return False
    return not resolved.is_relative_to(source) or git_ignored_path(resolved, source)


def ensure_external_directory(path: Path, source_root: Path) -> Path:
    if not path.is_absolute():
        raise AcceptanceRunError("evidence root must be absolute")
    try:
        resolved = path.resolve(strict=True)
        source = source_root.resolve(strict=True)
    except OSError as error:
        raise AcceptanceRunError(f"evidence/source root is unavailable: {error}") from error
    if not path.is_dir() or not evidence_path_allowed(path, source):
        raise AcceptanceRunError(
            "evidence root must be symlink-free and either outside source or Git-ignored"
        )
    return resolved


def prepare_evidence_directory(path: Path, source_root: Path, create: bool) -> Path:
    if not path.is_absolute():
        raise AcceptanceRunError("evidence root must be absolute")
    absolute = path
    if create and not absolute.exists():
        current = Path(absolute.anchor)
        for part in absolute.parts[1:]:
            current /= part
            if current.exists():
                try:
                    if stat.S_ISLNK(current.lstat().st_mode):
                        raise AcceptanceRunError(
                            f"symlink ancestor in evidence root: {current}"
                        )
                except OSError as error:
                    raise AcceptanceRunError(
                        f"evidence root ancestor is unavailable: {current}: {error}"
                    ) from error
        try:
            absolute.mkdir(parents=True, mode=0o700)
        except OSError as error:
            raise AcceptanceRunError(f"cannot create default evidence root: {error}") from error
    return ensure_external_directory(absolute, source_root)


def ensure_evidence_file(path: Path, source_root: Path, label: str) -> Path:
    lexical = path if path.is_absolute() else Path.cwd() / path
    try:
        resolved = lexical.resolve(strict=True)
    except OSError as error:
        raise AcceptanceRunError(f"{label} is unavailable: {path}: {error}") from error
    if not resolved.is_file() or not evidence_path_allowed(lexical, source_root):
        raise AcceptanceRunError(
            f"{label} must be a symlink-free file outside source or in a Git-ignored path"
        )
    return resolved


def source_inventory_without_evidence(
    source_root: Path, evidence_root: Path
) -> dict[str, tuple[str, int]]:
    inventory = worktree_inventory(source_root)
    source = source_root.resolve()
    evidence = evidence_root.resolve()
    prefix = (
        evidence.relative_to(source).as_posix()
        if evidence.is_relative_to(source)
        else None
    )
    return {
        relative: value
        for relative, value in inventory.items()
        if not source_archive_excluded(Path(relative))
        and (
            prefix is None
            or (relative != prefix and not relative.startswith(f"{prefix}/"))
        )
    }


def git_head(root: Path) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "--verify", "HEAD"],
        check=False,
        text=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    value = result.stdout.strip()
    if result.returncode != 0 or COMMIT_RE.fullmatch(value) is None:
        raise AcceptanceRunError(
            f"cannot derive source commit from git HEAD: {result.stderr.strip()}"
        )
    return value


def automatic_run_id(evidence_root: Path) -> str:
    for _ in range(32):
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        candidate = f"acceptance-{timestamp}-{secrets.token_hex(4)}"
        run_path = evidence_root / candidate
        bundle_path = evidence_root / SOURCE_BUNDLES_DIRECTORY / candidate
        if not run_path.exists() and not bundle_path.exists():
            return candidate
    raise AcceptanceRunError("could not allocate a unique automatic run ID")


def archive_override_is_complete(
    archive: Path | None,
    extraction_receipt: Path | None,
    extraction_receipt_sha256: str | None,
) -> bool:
    supplied = (
        archive is not None,
        extraction_receipt is not None,
        extraction_receipt_sha256 is not None,
    )
    if any(supplied) and not all(supplied):
        raise AcceptanceRunError(
            "--archive, --extraction-receipt, and "
            "--extraction-receipt-sha256 must be supplied together"
        )
    return all(supplied)


def exclusive_source_bundle_directory(evidence_root: Path, run_id: str) -> Path:
    parent = evidence_root / SOURCE_BUNDLES_DIRECTORY
    try:
        os.mkdir(parent, 0o700)
    except FileExistsError:
        try:
            metadata = parent.lstat()
        except OSError as error:
            raise AcceptanceRunError(
                f"source bundle directory is unavailable: {parent}: {error}"
            ) from error
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            raise AcceptanceRunError(
                f"source bundle parent must be a plain directory: {parent}"
            )
    bundle = parent / run_id
    try:
        os.mkdir(bundle, 0o700)
    except FileExistsError as error:
        raise AcceptanceRunError(
            f"source bundle already exists for run ID: {run_id}"
        ) from error
    if not symlink_free_path(bundle):
        raise AcceptanceRunError(f"source bundle path is not symlink-free: {bundle}")
    return bundle


def run_logged_command(
    argv: list[str],
    root: Path,
    environment: dict[str, str],
    log_path: Path,
) -> None:
    descriptor = os.open(
        log_path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        with os.fdopen(descriptor, "wb", closefd=False) as stream:
            completed = subprocess.run(
                argv,
                cwd=root,
                env=environment,
                check=False,
                stdin=subprocess.DEVNULL,
                stdout=stream,
                stderr=subprocess.STDOUT,
            )
            stream.flush()
            os.fsync(stream.fileno())
    finally:
        os.close(descriptor)
    if completed.returncode != 0:
        raise AcceptanceRunError(
            f"source archive command failed ({completed.returncode}); see {log_path}"
        )


def result_from_log(log_path: Path, prefix: bytes) -> dict[str, object]:
    matches: list[bytes] = []
    with log_path.open("rb") as stream:
        for line in stream:
            if line.startswith(prefix):
                matches.append(line[len(prefix) :].strip())
    if len(matches) != 1:
        raise AcceptanceRunError(
            f"source archive log must contain one {prefix.decode('ascii')} result"
        )
    value = load_closed_json_bytes(matches[0], str(log_path))
    if not isinstance(value, dict):
        raise AcceptanceRunError(f"source archive result is not an object: {log_path}")
    return value


def evidence_artifact(evidence_root: Path, path: Path) -> dict[str, object]:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise AcceptanceRunError(f"source bundle artifact is unavailable: {path}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise AcceptanceRunError(f"source bundle artifact is not plain: {path}")
    if metadata.st_size < 1:
        raise AcceptanceRunError(f"empty source bundle artifact is forbidden: {path}")
    digest = sha256_file(path)
    after = path.stat()
    if (
        after.st_size != metadata.st_size
        or after.st_mtime_ns != metadata.st_mtime_ns
    ):
        raise AcceptanceRunError(f"source bundle artifact changed while hashing: {path}")
    return {
        "path": path.relative_to(evidence_root).as_posix(),
        "sha256": digest,
        "size": metadata.st_size,
        "media_type": artifact_media_type(path),
    }


def validate_extraction_receipt_shape(
    root: Path, receipt: dict[str, object]
) -> None:
    schema = load_closed_json_bytes(
        read_plain_file(root / EXTRACTION_RECEIPT_SCHEMA),
        str(EXTRACTION_RECEIPT_SCHEMA),
    )
    if not isinstance(schema, dict):
        raise AcceptanceRunError("extraction receipt schema is not an object")
    schema_errors = sorted(
        Draft202012Validator(schema).iter_errors(receipt),
        key=lambda error: [str(part) for part in error.absolute_path],
    )
    if schema_errors:
        raise AcceptanceRunError(
            f"extraction receipt violates its schema: {schema_errors[0].message}"
        )


def validate_extraction_receipt_artifacts(
    receipt: dict[str, object],
    receipt_parent: Path,
    evidence_root: Path,
    source_root: Path,
) -> None:
    rows = receipt.get("artifacts")
    if not isinstance(rows, list):
        raise AcceptanceRunError("extraction receipt artifacts are invalid")
    seen: set[str] = set()
    for row in rows:
        if not isinstance(row, dict):
            raise AcceptanceRunError("extraction receipt artifact is not an object")
        relative = row.get("path")
        if not isinstance(relative, str) or not safe_relative(relative):
            raise AcceptanceRunError("extraction receipt artifact path is unsafe")
        if relative in seen:
            raise AcceptanceRunError(
                f"duplicate extraction receipt artifact path: {relative}"
            )
        seen.add(relative)
        matched = False
        candidates = (evidence_root / relative, receipt_parent / relative)
        for candidate in dict.fromkeys(candidates):
            try:
                resolved = ensure_evidence_file(
                    candidate, source_root, "extraction receipt artifact"
                )
            except AcceptanceRunError:
                continue
            before = resolved.stat()
            digest = sha256_file(resolved)
            after = resolved.stat()
            if (
                before.st_size != after.st_size
                or before.st_mtime_ns != after.st_mtime_ns
                or before.st_ino != after.st_ino
                or before.st_mode != after.st_mode
            ):
                continue
            if before.st_size == row.get("size") and digest == row.get("sha256"):
                matched = True
                break
        if not matched:
            raise AcceptanceRunError(
                f"extraction receipt artifact is missing or differs: {relative}"
            )


def validate_verified_extraction_receipt(
    receipt: dict[str, object],
    verification: dict[str, object],
    archive_sha256: str,
    source_tree_sha256: str,
    design: dict[str, object],
) -> None:
    expected = {
        "archive_sha256": archive_sha256,
        "source_tree_sha256": source_tree_sha256,
        "design_bundle_sha256": design.get("bundle_sha256"),
        "member_manifest_sha256": design.get("member_manifest_sha256"),
        "manifest_sha256": verification.get("manifest_sha256"),
        "archive_member_count": verification.get("archive_member_count"),
        "extracted_member_count": verification.get("extracted_member_count"),
        "residue_paths": verification.get("residue_paths"),
        "verification_argv": verification.get("verification_argv"),
    }
    mismatches = {
        field: {"expected": wanted, "actual": receipt.get(field)}
        for field, wanted in expected.items()
        if receipt.get(field) != wanted
    }
    if mismatches:
        raise AcceptanceRunError(
            f"extraction receipt differs from actual clean verification: {mismatches}"
        )


def write_exclusive(path: Path, content: bytes) -> None:
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        with os.fdopen(descriptor, "wb", closefd=False) as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
    finally:
        os.close(descriptor)


def actual_archive_verification(
    root: Path,
    archive: Path,
    source_tree_sha256: str,
    log_path: Path,
) -> dict[str, object]:
    environment = dict(os.environ)
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    environment["SOURCE_ARCHIVE"] = str(archive)
    environment["EXPECTED_SOURCE_TREE_SHA256"] = source_tree_sha256
    verify_argv = [sys.executable, "-B", "scripts/verify_source_archive.py"]
    run_logged_command(verify_argv, root, environment, log_path)
    verification = result_from_log(log_path, b"SOURCE_ARCHIVE_VERIFICATION=")
    required = {
        "archive_sha256",
        "source_tree_sha256",
        "manifest_sha256",
        "archive_member_count",
        "extracted_member_count",
        "residue_paths",
        "verification_argv",
        "manifested_files",
        "manifested_bytes",
    }
    if not required <= set(verification):
        raise AcceptanceRunError(
            "source archive verification result lacks schema receipt fields"
        )
    archive_sha256 = sha256_file(archive)
    if verification.get("archive_sha256") != archive_sha256:
        raise AcceptanceRunError("source archive verification digest differs")
    if verification.get("source_tree_sha256") != source_tree_sha256:
        raise AcceptanceRunError("clean extraction source tree digest differs")
    if verification.get("residue_paths") != []:
        raise AcceptanceRunError("clean extraction left residue paths")
    for field in (
        "archive_member_count",
        "extracted_member_count",
        "manifested_files",
        "manifested_bytes",
    ):
        value = verification.get(field)
        minimum = 1 if field != "manifested_bytes" else 0
        if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
            raise AcceptanceRunError(f"invalid source archive {field}: {value!r}")
    if verification.get("verification_argv") != ["make", "verify-final"]:
        raise AcceptanceRunError(
            "clean extraction did not run make verify-final: "
            f"{verification.get('verification_argv')!r}"
        )
    manifest_sha256 = verification.get("manifest_sha256")
    if (
        not isinstance(manifest_sha256, str)
        or SHA256_RE.fullmatch(manifest_sha256) is None
    ):
        raise AcceptanceRunError("clean extraction manifest digest is invalid")
    return verification


def automatic_release_artifacts(
    root: Path,
    evidence_root: Path,
    run_id: str,
    source_tree_sha256: str,
    design: dict[str, object],
) -> tuple[Path, Path, str]:
    bundle = exclusive_source_bundle_directory(evidence_root, run_id)
    archive = bundle / AUTO_ARCHIVE_NAME
    creation_log = bundle / "create-source-archive.log"
    verification_log = bundle / AUTO_VERIFICATION_LOG_NAME
    environment = dict(os.environ)
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    environment["SOURCE_ARCHIVE"] = str(archive)
    create_argv = [sys.executable, "-B", "scripts/create_source_archive.py"]
    run_logged_command(create_argv, root, environment, creation_log)
    creation = result_from_log(creation_log, b"SOURCE_ARCHIVE_CREATION=")
    archive_sha256 = sha256_file(archive)
    expected_sidecar = Path(f"{archive}.sha256")
    if (
        creation.get("archive_path") != str(archive)
        or creation.get("sidecar_path") != str(expected_sidecar)
        or creation.get("archive_sha256") != archive_sha256
        or creation.get("source_tree_sha256") != source_tree_sha256
    ):
        raise AcceptanceRunError("source archive creation result does not bind its outputs")
    creation_manifest_sha256 = creation.get("manifest_sha256")
    if (
        not isinstance(creation_manifest_sha256, str)
        or SHA256_RE.fullmatch(creation_manifest_sha256) is None
    ):
        raise AcceptanceRunError("source archive creation manifest digest is invalid")

    verification = actual_archive_verification(
        root,
        archive,
        source_tree_sha256,
        verification_log,
    )
    if verification.get("manifest_sha256") != creation_manifest_sha256:
        raise AcceptanceRunError("clean extraction manifest digest differs")
    for field in ("manifested_files", "manifested_bytes"):
        if verification.get(field) != creation.get(field):
            raise AcceptanceRunError(
                f"clean extraction {field} differs from archive creation"
            )
    verification_argv = verification.get("verification_argv")
    manifest_sha256 = verification.get("manifest_sha256")
    design_bundle_sha256 = design.get("bundle_sha256")
    member_manifest_sha256 = design.get("member_manifest_sha256")
    if not isinstance(design_bundle_sha256, str) or not isinstance(
        member_manifest_sha256, str
    ):
        raise AcceptanceRunError("design manifest lacks release bindings")
    receipt = {
        "schema_version": 1,
        "receipt_kind": "CLEAN_SOURCE_ARCHIVE_EXTRACTION",
        "status": "PASSED",
        "verified_at": utc_now(),
        "archive_sha256": archive_sha256,
        "source_tree_sha256": source_tree_sha256,
        "design_bundle_sha256": design_bundle_sha256,
        "member_manifest_sha256": member_manifest_sha256,
        "manifest_sha256": manifest_sha256,
        "archive_member_count": verification["archive_member_count"],
        "extracted_member_count": verification["extracted_member_count"],
        "residue_paths": verification["residue_paths"],
        "verification_argv": verification_argv,
        "artifacts": [
            evidence_artifact(evidence_root, archive),
            evidence_artifact(evidence_root, expected_sidecar),
            evidence_artifact(evidence_root, creation_log),
            evidence_artifact(evidence_root, verification_log),
        ],
    }
    receipt_content = (
        json.dumps(receipt, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
    ).encode("utf-8")
    validate_extraction_receipt_shape(root, receipt)
    validate_verified_extraction_receipt(
        receipt, verification, archive_sha256, source_tree_sha256, design
    )
    validate_extraction_receipt_artifacts(receipt, bundle, evidence_root, root)
    receipt_path = bundle / AUTO_EXTRACTION_RECEIPT_NAME
    write_exclusive(receipt_path, receipt_content)
    return archive, receipt_path, sha256_bytes(receipt_content)


def verify_explicit_release_artifacts(
    root: Path,
    evidence_root: Path,
    run_id: str,
    archive: Path,
    receipt_path: Path,
    receipt_sha256: str,
    source_tree_sha256: str,
    design: dict[str, object],
) -> Path:
    content = read_plain_file(receipt_path)
    if sha256_bytes(content) != receipt_sha256:
        raise AcceptanceRunError("extraction receipt digest differs")
    receipt = load_closed_json_bytes(content, "extraction receipt")
    if not isinstance(receipt, dict):
        raise AcceptanceRunError("extraction receipt is not an object")
    validate_extraction_receipt_shape(root, receipt)
    validate_extraction_receipt_artifacts(
        receipt, receipt_path.parent, evidence_root, root
    )

    bundle = exclusive_source_bundle_directory(evidence_root, run_id)
    verification_log = bundle / "verify-explicit-release.log"
    archive_sha256 = sha256_file(archive)
    verification = actual_archive_verification(
        root, archive, source_tree_sha256, verification_log
    )
    validate_verified_extraction_receipt(
        receipt,
        verification,
        archive_sha256,
        source_tree_sha256,
        design,
    )
    return verification_log


def read_plain_file(path: Path) -> bytes:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise AcceptanceRunError(f"required file is unavailable: {path}: {error}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise AcceptanceRunError(f"required file is not plain: {path}")
    return path.read_bytes()


class ExclusiveRunDirectory:
    def __init__(self, evidence_root: Path, run_id: str) -> None:
        self.evidence_root = evidence_root
        self.run_id = run_id
        self.path = evidence_root / run_id
        try:
            os.mkdir(self.path, 0o700)
        except FileExistsError as error:
            raise AcceptanceRunError(f"run ID already exists: {run_id}") from error
        self._directories = {""}

    def directory(self, relative: str) -> Path:
        if not safe_relative(relative):
            raise AcceptanceRunError(f"unsafe run directory path: {relative}")
        current = self.path
        prefix: list[str] = []
        for part in PurePosixPath(relative).parts:
            prefix.append(part)
            key = "/".join(prefix)
            current /= part
            if key not in self._directories:
                try:
                    os.mkdir(current, 0o700)
                except FileExistsError as error:
                    raise AcceptanceRunError(
                        f"unexpected pre-existing run directory: {key}"
                    ) from error
                self._directories.add(key)
        return current

    def path_for(self, relative: str) -> Path:
        if not safe_relative(relative):
            raise AcceptanceRunError(f"unsafe run file path: {relative}")
        parent = PurePosixPath(relative).parent.as_posix()
        if parent != ".":
            self.directory(parent)
        return self.path / relative

    def precreate(self, relative: str) -> Path:
        path = self.path_for(relative)
        descriptor = os.open(
            path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        os.close(descriptor)
        return path

    def write(self, relative: str, content: bytes) -> Path:
        path = self.path_for(relative)
        descriptor = os.open(
            path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        try:
            with os.fdopen(descriptor, "wb", closefd=False) as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
        finally:
            os.close(descriptor)
        return path

    def write_json(self, relative: str, value: object) -> Path:
        content = (
            json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
        ).encode("utf-8")
        return self.write(relative, content)

    def fsync_directories(self) -> None:
        for relative in sorted(self._directories, key=lambda value: value.count("/"), reverse=True):
            path = self.path if not relative else self.path / relative
            descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)


def artifact(run: ExclusiveRunDirectory, path: Path) -> dict[str, object]:
    relative = path.relative_to(run.path).as_posix()
    content = read_plain_file(path)
    if not content:
        raise AcceptanceRunError(f"empty artifact is forbidden: {relative}")
    return {
        "path": relative,
        "sha256": sha256_bytes(content),
        "size": len(content),
        "media_type": artifact_media_type(path),
    }


def run_process(
    argv: list[str],
    root: Path,
    environment: dict[str, str],
    timeout_seconds: int,
) -> tuple[subprocess.CompletedProcess[bytes], int]:
    if not argv or not all(isinstance(value, str) and value for value in argv):
        raise AcceptanceRunError(f"invalid process argv: {argv!r}")
    started = time.monotonic_ns()
    try:
        completed = subprocess.run(
            argv,
            cwd=root,
            env=environment,
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout_seconds,
        )
    except subprocess.TimeoutExpired as error:
        raise AcceptanceRunError(
            f"acceptance command timed out after {timeout_seconds}s: {argv!r}"
        ) from error
    duration_ms = max(1, (time.monotonic_ns() - started) // 1_000_000)
    if completed.returncode < 0:
        raise AcceptanceRunError(
            f"acceptance command terminated by signal {-completed.returncode}: {argv!r}"
        )
    completed.stdout = _redact_database_urls(completed.stdout or b"", environment)
    completed.stderr = _redact_database_urls(completed.stderr or b"", environment)
    return completed, duration_ms


def git_binding(root: Path, commit: str) -> None:
    if not (root / ".git").exists():
        return
    head = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=root,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    status = subprocess.run(
        ["git", "status", "--porcelain=v1", "--untracked-files=all"],
        cwd=root,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if head.returncode != 0 or head.stdout.strip() != commit:
        raise AcceptanceRunError("source commit differs from current git HEAD")
    if status.returncode != 0 or status.stdout:
        raise AcceptanceRunError("authoritative acceptance run requires a clean source tree")


def copy_extraction_receipt(
    run: ExclusiveRunDirectory,
    source: Path,
    expected_sha256: str,
) -> tuple[Path, dict[str, object]]:
    content = read_plain_file(source)
    if sha256_bytes(content) != expected_sha256:
        raise AcceptanceRunError("extraction receipt digest differs")
    load_closed_json_bytes(content, "extraction receipt")
    path = run.write("common/extraction-receipt.json", content)
    return path, artifact(run, path)


def environment_receipt(root: Path, common: dict[str, object]) -> dict[str, object]:
    tool_commands = {
        "python": [sys.executable, "--version"],
        "rustc": ["rustc", "--version", "--verbose"],
        "cargo": ["cargo", "--version"],
        "bun": ["bun", "--version"],
        "docker": ["docker", "--version"],
    }
    tools: dict[str, object] = {}
    for name, argv in tool_commands.items():
        completed = subprocess.run(
            argv,
            cwd=root,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        output = completed.stdout + completed.stderr
        tools[name] = {
            "argv": argv,
            "exit_code": completed.returncode,
            "output_sha256": sha256_bytes(output),
            "output": output.decode("utf-8", errors="strict").strip(),
        }
    return {
        "schema_version": 1,
        "receipt_kind": "ACCEPTANCE_ENVIRONMENT",
        "bindings": common,
        "tools": tools,
    }


def scenario_environment(
    base: dict[str, str],
    observation_path: Path,
    layer_paths: dict[str, Path],
    layer_ids: list[str],
    edge_contracts: dict[str, dict[str, dict[str, str | None]]],
    sentinel: str | None,
) -> dict[str, str]:
    result = dict(base)
    result["GURINNAE_ACCEPTANCE_OBSERVATION_PATH"] = str(observation_path)
    result["GURINNAE_ACCEPTANCE_RUNTIME_LAYERS_JSON"] = json.dumps(
        layer_ids, ensure_ascii=False, separators=(",", ":")
    )
    # Runtime layer probes are runner-owned subprocesses.  Do not expose
    # writable probe paths to the test process: an acceptance test must never
    # be able to fabricate a layer receipt by writing JSON into a pre-created
    # file.  The argument is retained as an explicit empty map for old test
    # binaries, which fail closed if they still try to use it.
    result["GURINNAE_ACCEPTANCE_LAYER_PROBE_PATHS_JSON"] = "{}"
    result["GURINNAE_ACCEPTANCE_EDGE_CONTRACTS_JSON"] = json.dumps(
        edge_contracts,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    if sentinel is None:
        result.pop("GURINE_ASSERTION_SENTINEL", None)
    else:
        result["GURINE_ASSERTION_SENTINEL"] = sentinel
    return result


def runtime_edge_contracts(
    row: dict[str, Any],
) -> dict[str, dict[str, dict[str, str | None]]]:
    observation_edges = {
        (str(edge["layer_id"]), str(edge["instance_id"])): edge
        for edge in row["observation_layer_contracts"]
    }
    oracle_edges = {
        (str(edge["layer_id"]), str(edge["oracle_id"])): edge
        for edge in row["oracle_layer_contracts"]
    }
    result: dict[str, dict[str, dict[str, str | None]]] = {}
    for observation in row["observation_contracts"]:
        instance_id = str(observation["instance_id"])
        for layer_id, candidate_instance in observation_edges:
            if candidate_instance != instance_id:
                continue
            observation_edge = observation_edges[(layer_id, instance_id)]
            oracle_contract = observation.get("oracle_contract")
            oracle_edge = (
                oracle_edges.get((layer_id, str(oracle_contract[0])))
                if isinstance(oracle_contract, list) and len(oracle_contract) == 2
                else None
            )
            result.setdefault(layer_id, {})[instance_id] = {
                "observation_layer_edge_id": str(observation_edge["edge_id"]),
                "observation_layer_edge_sha256": str(
                    observation_edge["edge_sha256"]
                ),
                "oracle_layer_edge_id": (
                    str(oracle_edge["edge_id"])
                    if isinstance(oracle_edge, dict)
                    else None
                ),
                "oracle_layer_edge_sha256": (
                    str(oracle_edge["edge_sha256"])
                    if isinstance(oracle_edge, dict)
                    else None
                ),
            }
    return result


def prepare_runtime_files(
    run: ExclusiveRunDirectory,
    prefix: str,
    layer_ids: list[str],
) -> tuple[Path, dict[str, Path]]:
    observation = run.precreate(f"{prefix}/observations.jsonl")
    # Layer probe files are written only after the runner has executed and
    # validated the pinned probe command.  Keeping this map empty prevents a
    # test process from smuggling a fabricated probe artifact into evidence.
    return observation, {}


def copy_nextest_junit(
    run: ExclusiveRunDirectory,
    root: Path,
    relative: str,
) -> Path:
    source = root / "target/nextest/acceptance/junit.xml"
    content = read_plain_file(source)
    return run.write(relative, content)


def clear_nextest_junit(root: Path) -> None:
    path = root / "target/nextest/acceptance/junit.xml"
    if path.is_symlink():
        raise AcceptanceRunError("nextest JUnit path is a symlink")
    if path.exists():
        if not path.is_file():
            raise AcceptanceRunError("nextest JUnit path is not a regular file")
        path.unlink()


def parse_execution(
    run: ExclusiveRunDirectory,
    root: Path,
    row: dict[str, Any],
    prefix: str,
    completed: subprocess.CompletedProcess[bytes],
    *,
    expected_failure: bool,
) -> tuple[TerminalCounts, list[Path], bytes]:
    selector = row["execution"]["selector"]
    test_id = str(selector["implementation_test_id"])
    implementation_path = str(row["execution"]["implementation_test_path"])
    stdout_path = run.write(f"{prefix}/run.stdout", completed.stdout or b"\n")
    stderr_path = run.write(f"{prefix}/run.stderr", completed.stderr or b"\n")
    combined = completed.stdout + completed.stderr
    if selector["runner_kind"] == "RUST_NEXTEST":
        report_path = copy_nextest_junit(run, root, f"{prefix}/run.junit.xml")
        counts = parse_nextest_junit(
            report_path.read_bytes(), test_id, expected_failure=expected_failure
        )
    elif selector["runner_kind"] == "PLAYWRIGHT":
        report_path = run.write(f"{prefix}/run.report.json", completed.stdout)
        counts = parse_playwright_report(
            completed.stdout,
            test_id,
            implementation_path,
            list_only=False,
            expected_failure=expected_failure,
        )
    else:
        raise AcceptanceRunError(f"unknown runner kind: {selector['runner_kind']!r}")
    expected_exit = completed.returncode != 0 if expected_failure else completed.returncode == 0
    if not expected_exit:
        raise AcceptanceRunError(
            f"terminal exit differs for {row['scenario_id']}: {completed.returncode}"
        )
    return counts, [stdout_path, stderr_path, report_path], combined + report_path.read_bytes()


def discover(
    run: ExclusiveRunDirectory,
    root: Path,
    row: dict[str, Any],
    prefix: str,
    environment: dict[str, str],
    timeout_seconds: int,
) -> tuple[TerminalCounts, list[Path]]:
    selector = row["execution"]["selector"]
    argv = list(selector["discovery_argv"])
    completed, _ = run_process(argv, root, environment, timeout_seconds)
    stdout_path = run.write(f"{prefix}/discovery.stdout", completed.stdout or b"\n")
    stderr_path = run.write(f"{prefix}/discovery.stderr", completed.stderr or b"\n")
    if completed.returncode != 0:
        raise AcceptanceRunError(
            f"discovery failed for {row['scenario_id']}: {completed.returncode}"
        )
    if selector["runner_kind"] == "RUST_NEXTEST":
        counts = parse_nextest_discovery(
            completed.stdout, str(selector["implementation_test_id"])
        )
    elif selector["runner_kind"] == "PLAYWRIGHT":
        counts = parse_playwright_report(
            completed.stdout,
            str(selector["implementation_test_id"]),
            str(row["execution"]["implementation_test_path"]),
            list_only=True,
        )
    else:
        raise AcceptanceRunError(f"unknown runner kind: {selector['runner_kind']!r}")
    report_path = run.write(f"{prefix}/discovery.report.json", completed.stdout)
    return counts, [stdout_path, stderr_path, report_path]


def layer_receipts(
    run: ExclusiveRunDirectory,
    root: Path,
    row: dict[str, Any],
    registry: dict[str, Any],
    base_environment: dict[str, str],
    environment_sha256: str,
    timeout_seconds: int,
) -> tuple[list[dict[str, object]], list[Path]]:
    """Execute every pinned runtime probe and bind its process output.

    The old implementation consumed JSON written by the test process.  That
    made a no-op test able to manufacture a green layer receipt.  Probe
    commands now come from the generated registry, are expanded only with the
    current scenario identity, and are executed directly by this runner.  We
    only write the raw artifact after a successful, closed JSON response has
    been parsed, so the test binary has no write path into layer evidence.
    """
    runtime = registry["runtime_contracts"]
    profile_id = row["execution"]["runtime_profile_id"]
    receipts: list[dict[str, object]] = []
    artifacts: list[Path] = []
    for layer_id in runtime["profiles"][profile_id]["layer_ids"]:
        contract = runtime["layers"][layer_id]
        template = contract.get("probe_argv_template")
        if not isinstance(template, list) or not template:
            raise AcceptanceRunError(f"missing probe argv template: {layer_id}")
        selector = row["execution"]["selector"]
        replacements = {
            "{scenario_id}": str(row["scenario_id"]),
            "{implementation_test_path}": str(row["execution"]["implementation_test_path"]),
            "{implementation_test_id}": str(selector["implementation_test_id"]),
        }
        probe_argv = [
            replacements.get(str(value), str(value))
            for value in template
        ]
        if any("{" in value or "}" in value for value in probe_argv):
            raise AcceptanceRunError(f"unexpanded probe argv template: {probe_argv!r}")
        probe_started_at = utc_now()
        completed, probe_duration_ms = run_process(
            probe_argv,
            root,
            {
                **base_environment,
                "GURINNAE_ACCEPTANCE_PROBE_SCENARIO_ID": str(row["scenario_id"]),
                "GURINNAE_ACCEPTANCE_PROBE_LAYER_ID": layer_id,
            },
            timeout_seconds=min(timeout_seconds, 300),
        )
        stdout = completed.stdout or b""
        stderr = completed.stderr or b""
        if completed.returncode != 0:
            raise AcceptanceRunError(
                f"runtime layer probe failed for {row['scenario_id']} {layer_id}: "
                f"exit={completed.returncode} stderr={stderr[-512:]!r}"
            )
        value = load_closed_json_bytes(
            stdout,
            f"{row['scenario_id']} {layer_id} probe stdout",
        )
        if not isinstance(value, dict):
            raise AcceptanceRunError("runtime layer probe stdout must be an object")
        expected_identity = {
            "schema_version": 1,
            "scenario_id": row["scenario_id"],
            "layer_id": layer_id,
            "probe_kind": contract["probe_kind"],
        }
        if any(value.get(key) != expected for key, expected in expected_identity.items()):
            raise AcceptanceRunError(
                f"runtime layer probe identity differs: {row['scenario_id']} {layer_id}"
            )
        if set(value) != {*expected_identity, "probe_facts"}:
            raise AcceptanceRunError(
                f"runtime layer probe response keys differ: {row['scenario_id']} {layer_id}"
            )
        probe_facts = value["probe_facts"]
        if not isinstance(probe_facts, dict) or probe_facts.get("kind") != contract["probe_kind"]:
            raise AcceptanceRunError(
                f"runtime layer probe facts differ: {row['scenario_id']} {layer_id}"
            )
        prefix = f"scenarios/{row['scenario_id']}/baseline/layers/{layer_id}"
        stdout_path = run.write(f"{prefix}.probe.stdout.json", stdout)
        # Evidence artifacts are required to be non-empty.  Preserve an empty
        # stderr stream as a canonical one-byte line terminator and bind the
        # digest to exactly the bytes persisted in the receipt.
        stderr_artifact_bytes = stderr or b"\n"
        stderr_path = run.write(f"{prefix}.probe.stderr", stderr_artifact_bytes)
        raw_path = run.write_json(
            f"{prefix}.probe.json",
            {
                **expected_identity,
                "probe_argv": probe_argv,
                "probe_facts": probe_facts,
            },
        )
        raw_artifact = artifact(run, raw_path)
        stdout_artifact = artifact(run, stdout_path)
        stderr_artifact = artifact(run, stderr_path)
        receipts.append(
            {
                "schema_version": 2,
                "receipt_kind": "ACCEPTANCE_RUNTIME_LAYER_V2",
                "scenario_id": row["scenario_id"],
                "runtime_profile_id": profile_id,
                "runtime_profile_sha256": row["runtime_profile_sha256"],
                "layer_id": layer_id,
                "layer_contract_sha256": contract["layer_contract_sha256"],
                "probe_kind": contract["probe_kind"],
                "status": "PASSED",
                "started_at": probe_started_at,
                "duration_ms": probe_duration_ms,
                "environment_digest": environment_sha256,
                "oracle_contracts": row["oracle_contracts"],
                "oracle_layer_contracts": [
                    [edge["edge_id"], edge["edge_sha256"]]
                    for edge in row["oracle_layer_contracts"]
                    if edge["layer_id"] == layer_id
                ],
                "probe_argv": probe_argv,
                "probe_argv_sha256": canonical_sha256(
                    PROBE_ARGV_DOMAIN, probe_argv
                ),
                "probe_facts": probe_facts,
                "probe_facts_sha256": canonical_sha256(
                    PROBE_FACTS_DOMAIN, probe_facts
                ),
                "probe_exit_code": completed.returncode,
                "probe_stdout_sha256": sha256_bytes(stdout),
                "probe_stderr_sha256": sha256_bytes(stderr_artifact_bytes),
                "probe_stdout_artifact": stdout_artifact,
                "probe_stderr_artifact": stderr_artifact,
                "raw_probe_artifact": raw_artifact,
                "artifacts": [raw_artifact, stdout_artifact, stderr_artifact],
            }
        )
        artifacts.extend([raw_path, stdout_path, stderr_path])
    return receipts, artifacts


def mutation_runs(
    run: ExclusiveRunDirectory,
    root: Path,
    row: dict[str, Any],
    base_environment: dict[str, str],
    layer_ids: list[str],
    timeout_seconds: int,
) -> tuple[Path, list[Path]]:
    rows: list[dict[str, object]] = []
    all_paths: list[Path] = []
    selector = row["execution"]["selector"]
    edge_contracts = runtime_edge_contracts(row)
    for ordinal, observation in enumerate(row["observation_contracts"], start=1):
        prefix = f"scenarios/{row['scenario_id']}/mutations/{ordinal:04d}"
        observation_path, probe_paths = prepare_runtime_files(run, prefix, layer_ids)
        sentinel = (
            f"{row['scenario_id']}:{ordinal}:"
            f"{observation['instance_id']}:{observation['instance_sha256']}"
        )
        environment = scenario_environment(
            base_environment,
            observation_path,
            probe_paths,
            layer_ids,
            edge_contracts,
            sentinel,
        )
        if selector["runner_kind"] == "RUST_NEXTEST":
            clear_nextest_junit(root)
        started_at = utc_now()
        completed, duration_ms = run_process(
            list(selector["run_argv"]), root, environment, timeout_seconds
        )
        counts, report_paths, combined = parse_execution(
            run,
            root,
            row,
            prefix,
            completed,
            expected_failure=True,
        )
        expected_marker = f"GURINE_ASSERTION_REACHED:{sentinel}".encode("utf-8")
        if expected_marker not in combined:
            raise AcceptanceRunError(
                f"observation sentinel was not reached: {row['scenario_id']} #{ordinal}"
            )
        all_paths.extend([observation_path, *probe_paths.values(), *report_paths])
        rows.append(
            {
                "observation_ordinal": ordinal,
                "instance_id": observation["instance_id"],
                "instance_sha256": observation["instance_sha256"],
                "sentinel_sha256": sha256_bytes(expected_marker),
                "started_at": started_at,
                "duration_ms": duration_ms,
                "exit_code": completed.returncode,
                "counts": asdict(counts),
                "artifacts": [artifact(run, path) for path in report_paths],
            }
        )
    payload = {
        "schema_version": 2,
        "receipt_kind": "ACCEPTANCE_OBSERVATION_MUTATIONS",
        "scenario_id": row["scenario_id"],
        "counts": {
            "total": len(rows),
            "killed": len(rows),
            "survivors": 0,
            "skipped": 0,
        },
        "mutations": rows,
    }
    summary = run.write_json(
        f"scenarios/{row['scenario_id']}/mutations.json", payload
    )
    return summary, [summary, *all_paths]


def _execute_scenario_with_environment(
    run: ExclusiveRunDirectory,
    root: Path,
    row: dict[str, Any],
    registry: dict[str, Any],
    common: dict[str, object],
    base_environment: dict[str, str],
    environment_path: Path,
    timeout_seconds: int,
) -> tuple[Path, dict[str, object], list[Path]]:
    scenario_id = str(row["scenario_id"])
    prefix = f"scenarios/{scenario_id}/baseline"
    profile_id = str(row["execution"]["runtime_profile_id"])
    layer_ids = list(registry["runtime_contracts"]["profiles"][profile_id]["layer_ids"])
    observation_path, probe_paths = prepare_runtime_files(run, prefix, layer_ids)
    environment = scenario_environment(
        base_environment,
        observation_path,
        probe_paths,
        layer_ids,
        runtime_edge_contracts(row),
        None,
    )
    discovery_counts, discovery_paths = discover(
        run, root, row, prefix, environment, timeout_seconds
    )
    if discovery_counts.discovered != 1:
        raise AcceptanceRunError(f"discovery count differs: {scenario_id}")
    selector = row["execution"]["selector"]
    if selector["runner_kind"] == "RUST_NEXTEST":
        clear_nextest_junit(root)
    started_at = utc_now()
    completed, duration_ms = run_process(
        list(selector["run_argv"]), root, environment, timeout_seconds
    )
    execution_counts, execution_paths, _ = parse_execution(
        run, root, row, prefix, completed, expected_failure=False
    )
    if not execution_counts.success():
        raise AcceptanceRunError(f"scenario did not pass exactly once: {scenario_id}")
    observation_content = read_plain_file(observation_path)
    observation_count = len(observation_content.splitlines())
    expected_observation_count = len(row["observation_contracts"]) * len(layer_ids)
    if observation_count != expected_observation_count:
        raise AcceptanceRunError(
            f"observation edge count differs for {scenario_id}: {observation_count} != {expected_observation_count}"
        )
    receipts, probe_artifact_paths = layer_receipts(
        run,
        root,
        row,
        registry,
        base_environment,
        sha256_file(environment_path),
        timeout_seconds,
    )
    mutation_summary, mutation_paths = mutation_runs(
        run,
        root,
        row,
        base_environment,
        layer_ids,
        timeout_seconds,
    )
    source_path = root / str(row["execution"]["implementation_test_path"])
    bindings = {
        **common,
        "base_mapping_sha256": sha256_file(root / BASE_MAPPING),
        "supplemental_mapping_sha256": sha256_file(root / SUPPLEMENTAL_MAPPING),
        "feature_sha256": row["feature_sha256"],
        "scenario_contract_sha256": row["scenario_contract_sha256"],
        "test_source_sha256": sha256_file(source_path),
        "selector_sha256": selector["selector_sha256"],
    }
    invocation = {
        "runner_kind": selector["runner_kind"],
        "implementation_test_path": row["execution"]["implementation_test_path"],
        "implementation_test_id": selector["implementation_test_id"],
        "discovery_argv": selector["discovery_argv"],
        "run_argv": selector["run_argv"],
        "run_argv_sha256": canonical_sha256(ARGV_DOMAIN, selector["run_argv"]),
    }
    prerequisite_argv = row["execution"].get("prerequisite_argv")
    if prerequisite_argv is not None:
        invocation["prerequisite_argv"] = prerequisite_argv
    main_artifact_paths = [
        environment_path,
        *discovery_paths,
        *execution_paths,
        observation_path,
        *probe_artifact_paths,
        mutation_summary,
    ]
    receipt = {
        "schema_version": 3,
        "receipt_kind": "ACCEPTANCE_SCENARIO_EXECUTION",
        "receipt_id": f"ACR-{run.run_id}-{scenario_id}",
        "run_id": run.run_id,
        "attempt": 1,
        "status": "PASSED",
        "origin": row["origin"],
        "scenario_id": scenario_id,
        "feature_file": row["feature_file"],
        "scenario_title": row["scenario_title"],
        "bindings": bindings,
        "invocation": invocation,
        "runtime_profile_id": profile_id,
        "runtime_profile_sha256": row["runtime_profile_sha256"],
        "layer_receipts": receipts,
        "started_at": started_at,
        "duration_ms": duration_ms,
        "exit_code": 0,
        "counts": {
            **asdict(execution_counts),
            "assertions": observation_count,
        },
        "observations": {
            "clause_contracts": row["clause_contracts"],
            "example_contracts": row["example_contracts"],
            "instance_contracts": row["instance_contracts"],
            "oracle_contracts": row["oracle_contracts"],
            "observation_contracts": row["observation_contracts"],
            "assertion_event_artifact": artifact(run, observation_path),
        },
        "artifacts": [artifact(run, path) for path in main_artifact_paths],
    }
    receipt_path = run.write_json(f"receipts/{row['origin'].lower()}/{scenario_id}.json", receipt)
    all_paths = [
        receipt_path,
        *main_artifact_paths,
        *mutation_paths,
    ]
    return receipt_path, receipt, all_paths


def execute_scenario(
    run: ExclusiveRunDirectory,
    root: Path,
    row: dict[str, Any],
    registry: dict[str, Any],
    common: dict[str, object],
    base_environment: dict[str, str],
    environment_path: Path,
    timeout_seconds: int,
) -> tuple[Path, dict[str, object], list[Path]]:
    lease = open_runtime_prerequisite(
        root, row, base_environment, timeout_seconds
    )
    if lease is None:
        return _execute_scenario_with_environment(
            run,
            root,
            row,
            registry,
            common,
            base_environment,
            environment_path,
            timeout_seconds,
        )
    with lease:
        return _execute_scenario_with_environment(
            run,
            root,
            row,
            registry,
            common,
            lease.child_environment(base_environment),
            environment_path,
            timeout_seconds,
        )


def seal_payload(run: ExclusiveRunDirectory, run_index_path: Path) -> dict[str, object]:
    members: list[dict[str, object]] = []
    for path in sorted(run.path.rglob("*")):
        if path.is_symlink():
            raise AcceptanceRunError(f"symlink in run directory: {path}")
        if path.is_dir():
            continue
        metadata = path.stat()
        if not stat.S_ISREG(metadata.st_mode):
            raise AcceptanceRunError(f"special file in run directory: {path}")
        relative = path.relative_to(run.path).as_posix()
        members.append(
            {
                "path": relative,
                "size": metadata.st_size,
                "sha256": sha256_file(path),
            }
        )
    return {
        "schema_version": 1,
        "seal_kind": "ACCEPTANCE_RUN_SEAL",
        "run_id": run.run_id,
        "run_index_sha256": sha256_file(run_index_path),
        "member_count": len(members),
        "member_set_sha256": canonical_sha256(
            SEAL_DOMAIN,
            [[row["path"], row["size"], row["sha256"]] for row in members],
        ),
        "members": members,
        "sealed_at": utc_now(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run and seal the complete effective acceptance scenario set."
    )
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument(
        "--evidence-root",
        type=Path,
        help="evidence directory (default: <root>/artifacts/acceptance)",
    )
    parser.add_argument("--run-id", help="run identity (default: generated UTC identity)")
    parser.add_argument(
        "--source-commit", help="40-hex source commit (default: current git HEAD)"
    )
    parser.add_argument(
        "--source-tree-sha256",
        help="source inventory digest (default: derived from the clean source tree)",
    )
    parser.add_argument(
        "--archive",
        type=Path,
        help="release archive override; requires both extraction receipt options",
    )
    parser.add_argument(
        "--extraction-receipt",
        type=Path,
        help="release extraction receipt override; requires both archive options",
    )
    parser.add_argument(
        "--extraction-receipt-sha256",
        help="release extraction receipt digest override; requires both archive options",
    )
    parser.add_argument("--timeout-seconds", type=int, default=900)
    args = parser.parse_args()
    root = args.root.resolve()
    archive_override = archive_override_is_complete(
        args.archive,
        args.extraction_receipt,
        args.extraction_receipt_sha256,
    )
    if args.run_id is not None and RUN_ID_RE.fullmatch(args.run_id) is None:
        raise AcceptanceRunError("run ID is invalid")
    if args.source_commit is not None and COMMIT_RE.fullmatch(args.source_commit) is None:
        raise AcceptanceRunError("source commit must be 40 lowercase hex")
    for name, value in {
        "source tree": args.source_tree_sha256,
        "extraction receipt": args.extraction_receipt_sha256,
    }.items():
        if value is not None and SHA256_RE.fullmatch(value) is None:
            raise AcceptanceRunError(f"{name} digest must be lowercase SHA-256")
    if args.timeout_seconds < 1:
        raise AcceptanceRunError("timeout must be positive")

    structural, registry = validate_static(root)
    if structural.problems:
        raise AcceptanceRunError(f"acceptance contract is invalid: {structural.problems[:3]}")
    scenario_counts = effective_scenario_counts(registry)
    source_checks = validate_sources(root, registry)
    if source_checks.problems:
        raise AcceptanceRunError(f"acceptance source is invalid: {source_checks.problems[:3]}")
    default_evidence = args.evidence_root is None
    requested_evidence = (
        root / DEFAULT_EVIDENCE_RELATIVE
        if default_evidence
        else args.evidence_root
    )
    if requested_evidence is None:
        raise AcceptanceRunError("evidence root resolution failed")
    evidence_root = prepare_evidence_directory(
        requested_evidence, root, create=default_evidence
    )
    args.run_id = args.run_id or automatic_run_id(evidence_root)
    if RUN_ID_RE.fullmatch(args.run_id) is None:
        raise AcceptanceRunError("run ID is invalid")
    if (evidence_root / args.run_id).exists():
        raise AcceptanceRunError(f"run ID already exists: {args.run_id}")
    if (evidence_root / SOURCE_BUNDLES_DIRECTORY / args.run_id).exists():
        raise AcceptanceRunError(
            f"source bundle already exists for run ID: {args.run_id}"
        )

    source_before = source_inventory_without_evidence(root, evidence_root)
    actual_tree = source_tree_digest(source_before)
    args.source_tree_sha256 = args.source_tree_sha256 or actual_tree
    if actual_tree != args.source_tree_sha256:
        raise AcceptanceRunError(
            f"source tree digest differs: {actual_tree} != {args.source_tree_sha256}"
        )
    args.source_commit = args.source_commit or git_head(root)
    if COMMIT_RE.fullmatch(args.source_commit) is None:
        raise AcceptanceRunError("source commit must be 40 lowercase hex")
    git_binding(root, args.source_commit)
    design = build_design_manifest(root)
    if design.get("authority_zip_sha256") != AUTHORITY_ZIP_SHA256:
        raise AcceptanceRunError("design bundle authority archive binding differs")
    explicit_verification_log: Path | None = None
    if archive_override:
        if args.archive is None or args.extraction_receipt is None:
            raise AcceptanceRunError("release archive override resolution failed")
        args.archive = ensure_evidence_file(args.archive, root, "source archive")
        ensure_evidence_file(
            Path(f"{args.archive}.sha256"), root, "source archive sidecar"
        )
        args.extraction_receipt = ensure_evidence_file(
            args.extraction_receipt, root, "extraction receipt"
        )
        if args.extraction_receipt_sha256 is None:
            raise AcceptanceRunError("release extraction receipt digest is missing")
        explicit_verification_log = verify_explicit_release_artifacts(
            root,
            evidence_root,
            args.run_id,
            args.archive,
            args.extraction_receipt,
            args.extraction_receipt_sha256,
            args.source_tree_sha256,
            design,
        )
    else:
        (
            args.archive,
            args.extraction_receipt,
            args.extraction_receipt_sha256,
        ) = automatic_release_artifacts(
            root,
            evidence_root,
            args.run_id,
            args.source_tree_sha256,
            design,
        )
    if args.archive is None or args.extraction_receipt is None:
        raise AcceptanceRunError("release archive inputs are incomplete")
    if (
        args.extraction_receipt_sha256 is None
        or SHA256_RE.fullmatch(args.extraction_receipt_sha256) is None
    ):
        raise AcceptanceRunError("extraction receipt digest must be lowercase SHA-256")
    archive_content = read_plain_file(args.archive)
    archive_sha256 = sha256_bytes(archive_content)
    common: dict[str, object] = {
        "authority_zip_sha256": AUTHORITY_ZIP_SHA256,
        "design_bundle_sha256": design["bundle_sha256"],
        "member_manifest_sha256": design["member_manifest_sha256"],
        "effective_registry_sha256": sha256_file(root / EFFECTIVE_REGISTRY),
        "source_commit": args.source_commit,
        "source_tree_sha256": args.source_tree_sha256,
        "archive_sha256": archive_sha256,
        "extraction_receipt_sha256": args.extraction_receipt_sha256,
    }
    run = ExclusiveRunDirectory(evidence_root, args.run_id)
    extraction_path, _ = copy_extraction_receipt(
        run,
        args.extraction_receipt,
        args.extraction_receipt_sha256,
    )
    if explicit_verification_log is not None:
        run.write(
            "common/archive-reverification.log",
            read_plain_file(explicit_verification_log),
        )
    environment_value = environment_receipt(root, common)
    environment_path = run.write_json("common/environment.json", environment_value)
    base_environment = dict(os.environ)
    # Never inherit an operator/test-provided writable probe map into any
    # child process.  scenario_environment installs the runner-owned empty
    # map explicitly for acceptance binaries.
    base_environment.pop("GURINNAE_ACCEPTANCE_LAYER_PROBE_PATHS_JSON", None)
    base_environment["GURINNAE_ACCEPTANCE_RUN_ID"] = args.run_id
    base_environment["GURINNAE_ACCEPTANCE_RUN_DIRECTORY"] = str(run.path)

    started_at = utc_now()
    entries: list[dict[str, object]] = []
    seen_paths: set[str] = set()
    for position, row in enumerate(registry["scenarios"], start=1):
        receipt_path, _, paths = execute_scenario(
            run,
            root,
            row,
            registry,
            common,
            base_environment,
            environment_path,
            args.timeout_seconds,
        )
        for path in paths:
            relative = path.relative_to(run.path).as_posix()
            if relative in seen_paths and path != environment_path:
                raise AcceptanceRunError(f"artifact path reused: {relative}")
            seen_paths.add(relative)
        receipt_artifact = artifact(run, receipt_path)
        entries.append(
            {
                "scenario_id": row["scenario_id"],
                "origin": row["origin"],
                "path": receipt_artifact["path"],
                "sha256": receipt_artifact["sha256"],
                "size": receipt_artifact["size"],
            }
        )
        print(
            "ACCEPTANCE_SCENARIO: "
            f"{position}/{scenario_counts.effective} PASS {row['scenario_id']}",
            flush=True,
        )

    source_after = source_inventory_without_evidence(root, evidence_root)
    if source_after != source_before:
        raise AcceptanceRunError("source tree changed during acceptance execution")
    if len(entries) != scenario_counts.effective:
        raise AcceptanceRunError(
            "executed acceptance scenario count differs from the registry: "
            f"{len(entries)} != {scenario_counts.effective}"
        )
    aggregate_rows = [
        [row["scenario_id"], row["origin"], row["path"], row["sha256"], row["size"]]
        for row in sorted(entries, key=lambda value: str(value["scenario_id"]))
    ]
    index = {
        "schema_version": 1,
        "index_kind": "ACCEPTANCE_RUN_INDEX",
        "run_id": args.run_id,
        "status": "PASSED",
        "started_at": started_at,
        "completed_at": utc_now(),
        "bindings": common,
        "counts": {
            "base_scenarios": scenario_counts.base,
            "supplemental_scenarios": scenario_counts.supplemental,
            "effective_scenarios": scenario_counts.effective,
            "passed": len(entries),
            "failed": 0,
            "skipped": 0,
            "retried": 0,
        },
        "scenario_sets": registry["scenario_sets"],
        "receipts": sorted(entries, key=lambda value: str(value["scenario_id"])),
        "aggregate_sha256": canonical_sha256(RUN_AGGREGATE_DOMAIN, aggregate_rows),
    }
    index_path = run.write_json("run-index.json", index)
    sidecar = f"{sha256_file(index_path)}  {index_path.name}\n".encode("utf-8")
    run.write("run-index.json.sha256", sidecar)
    seal = seal_payload(run, index_path)
    seal_path = run.write_json("seal.json", seal)
    run.fsync_directories()

    environment_updates = {
        "GURINNAE_SOURCE_COMMIT": args.source_commit,
        "GURINNAE_SOURCE_TREE_SHA256": args.source_tree_sha256,
        "GURINNAE_ARCHIVE_SHA256": archive_sha256,
        "GURINNAE_EXTRACTION_RECEIPT_SHA256": args.extraction_receipt_sha256,
        "GURINNAE_EXTRACTION_RECEIPT": str(extraction_path),
    }
    previous = {key: os.environ.get(key) for key in environment_updates}
    os.environ.update(environment_updates)
    try:
        evidence_checks = validate_external_evidence(
            root, registry, evidence_root, f"{args.run_id}/run-index.json"
        )
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
    if evidence_checks.problems:
        raise AcceptanceRunError(
            f"generated evidence failed independent validation: {evidence_checks.problems[:3]}"
        )
    print(
        json.dumps(
            {
                "result": "PASS",
                "run_id": args.run_id,
                "run_index": str(index_path),
                "run_index_sha256": sha256_file(index_path),
                "seal": str(seal_path),
                "seal_sha256": sha256_file(seal_path),
            },
            ensure_ascii=False,
            sort_keys=True,
        )
    )
    print(f"ACCEPTANCE_RUN_{scenario_counts.effective}: PASS")
    return 0


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    try:
        raise SystemExit(main())
    except (AcceptanceRunError, MachineReportError, OSError, ValueError) as error:
        print(
            f"ACCEPTANCE_RUN_{CURRENT_EFFECTIVE_SCENARIO_COUNT}: FAIL: {error}",
            file=sys.stderr,
        )
        raise SystemExit(1)
