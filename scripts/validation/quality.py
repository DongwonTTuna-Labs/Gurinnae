from __future__ import annotations

from pathlib import Path

from .loaders import load_yaml
from .models import Validation
from .quality_source import validate_source_quality


AGENT_MARKERS = (
    "#![forbid(unsafe_code)]",
    'unsafe_code = "forbid"',
    "Rustful",
    "Svelteful",
    "SOLID",
    "YAGNI",
    "Clean Code",
    "{@html}",
    "server module scope",
    "valibot@1.1.0",
    "exactOptionalPropertyTypes",
)
CRITICAL_DEPENDENCIES = (
    'openidconnect = "=4.0.1"',
    'chacha20poly1305 = "=0.11.0"',
    'object_store = "=0.14.0"',
    'lettre = "=0.11.22"',
    'opentelemetry = "=0.32.0"',
    'calamine = "=0.35.0"',
    'quick-xml = "=0.41.0"',
    'zip = "=8.6.0"',
    'csv = "=1.4.0"',
    'lopdf = "=0.43.0"',
    'pdf-extract = "=0.10.0"',
    'clamd-client = "=0.1.2"',
)
REQUIRED_FORBIDDEN_RUST = {
    "unwrap(",
    "expect(",
    "panic!(",
    "todo!(",
    "unimplemented!(",
    "unreachable!(",
}


def _validate_contract(root: Path, result: Validation) -> None:
    contract = load_yaml(root / "specs/engineering/code-quality-contract.yaml")
    agents = (root / "AGENTS.md").read_text(encoding="utf-8")
    result.require(
        contract["specification_version"] == "13.0.0",
        "code quality version mismatch",
    )
    result.require(contract["status"] == "FINAL", "code quality status must be FINAL")
    for marker in AGENT_MARKERS:
        result.require(marker in agents, f"AGENTS missing {marker}")
    rust = contract["rust"]
    result.require(
        rust["first_party_unsafe_code"] == "forbidden",
        "first-party unsafe must be forbidden",
    )
    forbidden = set(rust["production_forbidden"]) | set(
        rust.get("forbidden_tokens_in_first_party", [])
    )
    result.require(
        REQUIRED_FORBIDDEN_RUST <= forbidden,
        "panic/placeholder control flow not fully forbidden",
    )
    result.require(
        rust["file_limits"]["hard_lines"] == 600
        and rust["function_limits"]["hard_logical_lines"] == 70,
        "Rust size limits mismatch",
    )
    result.require(
        contract["sveltekit"]["runtime_validator"] == "valibot@1.1.0",
        "runtime validator must be Valibot 1.1.0",
    )


def _validate_validator_sizes(root: Path, result: Validation) -> None:
    for module in sorted((root / "scripts/validation").glob("*.py")):
        lines = len(module.read_text(encoding="utf-8").splitlines())
        result.require(lines <= 400, f"{module.name}: validator module exceeds 400 lines")


def _validate_dependencies(root: Path, result: Validation) -> None:
    cargo = (root / "specs/dependencies/cargo-bom.toml").read_text(encoding="utf-8")
    for dependency in CRITICAL_DEPENDENCIES:
        result.require(
            dependency in cargo,
            f"critical direct dependency missing: {dependency}",
        )


def validate(root: Path, result: Validation) -> None:
    _validate_contract(root, result)
    _validate_validator_sizes(root, result)
    _validate_dependencies(root, result)
    facts = validate_source_quality(root, result)
    result.stats.update(
        {
            "code_quality_contract": "FINAL",
            "first_party_rust_files": facts.rust_files,
            "first_party_rust_functions": facts.rust_functions,
            "first_party_typescript_files": facts.typescript_files,
            "first_party_svelte_files": facts.svelte_files,
        }
    )
