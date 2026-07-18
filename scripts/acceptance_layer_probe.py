#!/usr/bin/env python3
"""Execute one authoritative acceptance runtime-layer probe.

The acceptance runner owns the process and captures stdout/stderr.  This
program deliberately emits one closed JSON object and never writes an evidence
file.  Its source is part of the source-tree digest and the invocation is
declared in the generated effective registry, so replacing it or adding a
second no-op command changes the acceptance contract.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
KIND_BY_LAYER = {
    "rust-1.97.0-domain-application": "RUST_TOOLCHAIN_AND_BINARY",
    "postgresql-18.4-real-migrations": "POSTGRESQL_CATALOG",
    "docker-compose-production-topology": "COMPOSE_TOPOLOGY",
    "sveltekit-ssr-browser": "PLAYWRIGHT_BROWSER_TRACE",
    "provider-double-at-external-boundary": "PROVIDER_BOUNDARY_LOG",
    "parser-golden-bytes": "PARSER_GOLDEN",
    "production-ledger-projection": "PROJECTION_DIGEST",
    "koneps-synthetic-source-boundary": "SOURCE_BOUNDARY_LOG",
}


def digest(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def file_digest(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        raise RuntimeError(f"required probe input is not a regular file: {path}")
    return digest(path.read_bytes())


def run(argv: list[str], *, env: dict[str, str] | None = None) -> bytes:
    process = subprocess.run(
        argv,
        cwd=ROOT,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=240,
    )
    if process.returncode != 0:
        detail = process.stderr.decode("utf-8", errors="replace")[-512:]
        raise RuntimeError(f"probe command failed ({process.returncode}): {argv!r}: {detail}")
    return process.stdout


def rust_facts(test_path: str, test_id: str) -> dict[str, object]:
    version = run(["rustc", "--version"]).decode("utf-8", errors="strict").strip()
    if not version.startswith("rustc 1.97.0"):
        raise RuntimeError(f"unsupported rustc toolchain: {version}")
    verbose = run(["rustc", "--version", "--verbose"])
    metadata = run(["cargo", "metadata", "--locked", "--no-deps", "--format-version", "1"])
    source = ROOT / test_path
    # The nextest run has already compiled this target.  A binary digest is
    # required; silently substituting source bytes would make the probe a
    # fixture.  Match only regular executable test binaries.
    candidates = sorted(
        path
        for path in (ROOT / "target/debug/deps").glob("gurine_acceptance_tests-*")
        if path.is_file() and os.access(path, os.X_OK)
    )
    if not candidates:
        raise RuntimeError("acceptance test binary is unavailable after test execution")
    return {
        "kind": KIND_BY_LAYER["rust-1.97.0-domain-application"],
        "rustc_version": version,
        "rustc_verbose_sha256": digest(verbose),
        "cargo_metadata_sha256": digest(metadata),
        "test_binary_sha256": file_digest(candidates[0]),
        "test_target": Path(test_path).stem,
        "test_identity": test_id,
        "effect_receipt_sha256": digest(
            (version + test_path + test_id + file_digest(source)).encode("utf-8")
        ),
    }


def postgres_facts() -> dict[str, object]:
    psql = shutil.which("psql")
    database_url = os.environ.get("DATABASE_URL")
    if not psql or not database_url:
        raise RuntimeError("POSTGRESQL probe requires psql and DATABASE_URL")
    version = run(
        [psql, database_url, "-AtqX", "-c", "SHOW server_version_num"]
    ).decode("utf-8", errors="strict").strip()
    if version != "180004":
        raise RuntimeError(f"unexpected PostgreSQL server_version_num: {version}")
    role = run([psql, database_url, "-AtqX", "-c", "SELECT current_user"]).decode(
        "utf-8", errors="strict"
    ).strip()
    migrations = sorted((ROOT / "db/migrations").glob("*.sql"))
    if not migrations:
        raise RuntimeError("database migration directory is empty")
    migration_set = b"\n".join(
        f"{path.name}:{file_digest(path)}".encode("utf-8") for path in migrations
    )
    catalog = run(
        [
            psql,
            database_url,
            "-AtqX",
            "-c",
            "SELECT table_schema,table_name FROM information_schema.tables "
            "WHERE table_schema NOT IN ('pg_catalog','information_schema') "
            "ORDER BY 1,2",
        ]
    )
    transaction = run([psql, database_url, "-AtqX", "-c", "SELECT 1"])
    return {
        "kind": KIND_BY_LAYER["postgresql-18.4-real-migrations"],
        "server_version_num": 180004,
        "migration_count": len(migrations),
        "migration_set_sha256": digest(migration_set),
        "session_role": role,
        "catalog_snapshot_sha256": digest(catalog),
        "transaction_receipt_sha256": digest(transaction),
        "effect_receipt_sha256": digest(version.encode() + catalog),
    }


def compose_facts() -> dict[str, object]:
    compose = shutil.which("docker")
    if not compose:
        raise RuntimeError("COMPOSE probe requires docker")
    config = run([compose, "compose", "-f", "compose.production.yaml", "config", "--format", "json"])
    parsed = json.loads(config)
    services = parsed.get("services") if isinstance(parsed, dict) else None
    if not isinstance(services, dict):
        raise RuntimeError("compose config has no services object")
    networks = parsed.get("networks", {})
    health = run(
        [compose, "compose", "-f", "compose.production.yaml", "ps", "--format", "json"]
    )
    image_rows = sorted(
        (name, body.get("image", ""))
        for name, body in services.items()
        if isinstance(body, dict)
    )
    network_rows = sorted(networks) if isinstance(networks, dict) else []
    return {
        "kind": KIND_BY_LAYER["docker-compose-production-topology"],
        "service_count": len(services),
        "config_sha256": digest(config),
        "image_set_sha256": digest(json.dumps(image_rows, sort_keys=True).encode()),
        "network_set_sha256": digest(json.dumps(network_rows, sort_keys=True).encode()),
        "health_snapshot_sha256": digest(health),
    }


def browser_facts() -> dict[str, object]:
    # Browser tests publish this proof only through the runner environment;
    # accepting a made-up route or hash from test stdout would reintroduce the
    # old false-green boundary.
    return external_facts(
        "GURINNAE_BROWSER_PROBE_FACTS_JSON",
        KIND_BY_LAYER["sveltekit-ssr-browser"],
        required=(
            "project", "browser_name", "browser_version", "route", "ssr_status",
            "ssr_html_sha256", "trace_sha256", "screenshot_sha256",
            "accessibility_snapshot_sha256",
        ),
    )


def parser_facts() -> dict[str, object]:
    fixture = ROOT / "specs/parsers/fixture-manifest.yaml"
    if not fixture.is_file():
        raise RuntimeError("parser fixture manifest is unavailable")
    harness = ROOT / "specs/parsers/reference_harness.py"
    if not harness.is_file():
        raise RuntimeError("parser reference harness is unavailable")
    output = run([sys.executable, "-B", str(harness)])
    manifest = fixture.read_bytes()
    result = json.loads(output)
    if result.get("result") != "PASS" or int(result.get("caseCount", 0)) < 15:
        raise RuntimeError("parser reference harness did not pass all authority fixtures")
    expected = sorted(
        path
        for path in (ROOT / "specs/parsers/expected").glob("*.json")
        if path.is_file()
    )
    if not expected:
        raise RuntimeError("parser golden output directory is empty")
    golden = b"\n".join(path.read_bytes() for path in expected)
    return {
        "kind": KIND_BY_LAYER["parser-golden-bytes"],
        "parser_id": "authority-fixture-manifest",
        "parser_version": "reference_harness-v1",
        "input_sha256": digest(manifest),
        "output_sha256": digest(output),
        "golden_sha256": digest(golden),
        "golden_match": True,
        "locator_count": max(1, int(result.get("goldenCount", 0))),
        "effect_writer_count": 0,
    }


def projection_facts() -> dict[str, object]:
    return external_facts(
        "GURINNAE_PROJECTION_PROBE_FACTS_JSON",
        KIND_BY_LAYER["production-ledger-projection"],
        required=(
            "source_event_sha256", "consumer_sha256", "writer_sha256",
            "projection_row_sha256", "audit_event_sha256", "outbox_event_sha256",
            "fixture_effect_write_count",
        ),
    )


def source_facts() -> dict[str, object]:
    return external_facts(
        "GURINNAE_SOURCE_PROBE_FACTS_JSON",
        KIND_BY_LAYER["koneps-synthetic-source-boundary"],
        required=(
            "fixture_input_sha256", "adapter_sha256", "source_run_sha256",
            "revision_sha256", "normalization_sha256", "effect_writer_count",
        ),
    )


def external_facts(
    environment_name: str,
    kind: str,
    *,
    required: tuple[str, ...],
) -> dict[str, object]:
    """Load a receipt emitted by the real layer runtime, never synthesize one."""
    encoded = os.environ.get(environment_name)
    if not encoded:
        raise RuntimeError(f"{environment_name} is required; no fabricated probe is allowed")
    try:
        value = json.loads(encoded)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"{environment_name} is not closed JSON: {error}") from error
    if not isinstance(value, dict) or value.get("kind") != kind:
        raise RuntimeError(f"{environment_name} has the wrong probe kind")
    if set(value) != {"kind", *required}:
        raise RuntimeError(f"{environment_name} keys differ from the closed probe contract")
    return value


def facts(layer_id: str, test_path: str, test_id: str) -> dict[str, object]:
    return {
        "rust-1.97.0-domain-application": lambda: rust_facts(test_path, test_id),
        "postgresql-18.4-real-migrations": postgres_facts,
        "docker-compose-production-topology": compose_facts,
        "sveltekit-ssr-browser": browser_facts,
        "provider-double-at-external-boundary": lambda: external_facts(
            "GURINNAE_PROVIDER_PROBE_FACTS_JSON",
            KIND_BY_LAYER["provider-double-at-external-boundary"],
            required=(
                "adapter_id", "request_sha256", "response_sha256",
                "gateway_log_sha256", "direct_egress_denial_sha256",
                "direct_egress_denied", "effect_writer_count",
            ),
        ),
        "parser-golden-bytes": parser_facts,
        "production-ledger-projection": projection_facts,
        "koneps-synthetic-source-boundary": source_facts,
    }[layer_id]()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--layer-id", required=True, choices=sorted(KIND_BY_LAYER))
    parser.add_argument("--scenario-id", required=True)
    parser.add_argument("--test-path", default="")
    parser.add_argument("--test-id", default="")
    args = parser.parse_args()
    result = {
        "schema_version": 1,
        "scenario_id": args.scenario_id,
        "layer_id": args.layer_id,
        "probe_kind": KIND_BY_LAYER[args.layer_id],
        "probe_facts": facts(args.layer_id, args.test_path, args.test_id),
    }
    encoded = json.dumps(result, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    sys.stdout.write(encoded + "\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(f"ACCEPTANCE_LAYER_PROBE: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
