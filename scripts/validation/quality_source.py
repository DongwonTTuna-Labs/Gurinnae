"""Source-grounded code-quality gates.

The authority contract is executable: a number written in YAML is not evidence
that the source respects it.  This module inventories first-party source and
reports every concrete hard-limit or forbidden-token violation.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re
from typing import Iterable

from .models import Validation
from .supplemental_acceptance_source import executable_source, source_without_comments


IGNORED_PARTS = frozenset(
    {
        ".git",
        ".svelte-kit",
        "coverage",
        "dist",
        "node_modules",
        "target",
        "vendor",
    }
)
GENERATED_MARKERS = frozenset({"generated", "gen", "openapi-generated"})
RUST_ROOTS = ("crates", "services")
TYPESCRIPT_ROOTS = ("apps", "packages", "tests")
SAVELTE_ROOTS = ("apps", "packages")
RUST_FORBIDDEN = {
    "unsafe_block": re.compile(r"\bunsafe\s*\{"),
    "unsafe_fn": re.compile(r"\bunsafe\s+fn\b"),
    "unsafe_trait": re.compile(r"\bunsafe\s+trait\b"),
    "unsafe_impl": re.compile(r"\bunsafe\s+impl\b"),
    "extern_c": re.compile(r"\bextern\s+\"C\""),
    "unwrap": re.compile(r"\.unwrap\s*\("),
    "expect": re.compile(r"\.expect\s*\("),
    "panic": re.compile(r"\bpanic\s*!\s*\("),
    "todo": re.compile(r"\btodo\s*!\s*\("),
    "unimplemented": re.compile(r"\bunimplemented\s*!\s*\("),
    "unreachable": re.compile(r"\bunreachable\s*!\s*\("),
}
RUST_FUNCTION = re.compile(
    r"(?m)\bfn\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*(?:<[^>{;]*>)?\s*\("
)


@dataclass(frozen=True)
class SourceFacts:
    rust_files: int
    typescript_files: int
    svelte_files: int
    rust_functions: int


def _files(root: Path, roots: Iterable[str], suffix: str) -> Iterable[Path]:
    for prefix in roots:
        directory = root / prefix
        if not directory.is_dir():
            continue
        for path in directory.rglob(f"*{suffix}"):
            relative = path.relative_to(root)
            if any(part in IGNORED_PARTS for part in relative.parts):
                continue
            if path.is_symlink() or not path.is_file():
                continue
            yield path


def _generated(root: Path, path: Path) -> bool:
    relative = path.relative_to(root)
    if any(part in GENERATED_MARKERS for part in relative.parts):
        return True
    name = relative.name.lower()
    if name.startswith(("generated-", "generated_")) or name.endswith(
        (".generated.ts", "_generated.rs", ".gen.ts")
    ):
        return True
    # Generators must leave an explicit marker in the first three lines. This
    # keeps generated outputs out of style-size rewriting while strict type
    # checking still compiles them.
    try:
        return any("generated from" in line.lower() for line in path.read_text(encoding="utf-8").splitlines()[:3])
    except OSError:
        return False


def _line_count(path: Path) -> int:
    return len(path.read_text(encoding="utf-8").splitlines())


def _production_rust(path: Path, text: str) -> str:
    """Drop the conventional test-only suffix before production token scans."""
    marker = re.search(r"(?m)^\s*#\s*\[\s*cfg\s*\(\s*test\s*\)\s*\]", text)
    return text[: marker.start()] if marker is not None else text


def _matching_brace(code: str, opening: int) -> int | None:
    depth = 0
    for index in range(opening, len(code)):
        token = code[index]
        if token == "{":
            depth += 1
        elif token == "}":
            depth -= 1
            if depth == 0:
                return index + 1
    return None


def _logical_lines(code: str) -> int:
    count = 0
    for line in code.splitlines():
        stripped = line.strip()
        if not stripped or stripped in {"{", "}", "};", ");"}:
            continue
        count += 1
    return count


def _rust_function_facts(path: Path, text: str) -> list[tuple[str, int]]:
    code = executable_source(path, text)
    rows: list[tuple[str, int]] = []
    for match in RUST_FUNCTION.finditer(code):
        semicolon = code.find(";", match.end())
        opening = code.find("{", match.end())
        if opening < 0 or (semicolon >= 0 and semicolon < opening):
            continue
        end = _matching_brace(code, opening)
        if end is None:
            rows.append((match.group("name"), 10**9))
            continue
        rows.append((match.group("name"), _logical_lines(code[opening + 1 : end - 1])))
    return rows


def _validate_rust(root: Path, result: Validation) -> tuple[int, int]:
    file_count = 0
    function_count = 0
    for path in sorted(_files(root, RUST_ROOTS, ".rs")):
        file_count += 1
        relative = path.relative_to(root).as_posix()
        text = path.read_text(encoding="utf-8")
        generated = _generated(root, path) or "Generated" in "\n".join(
            text.splitlines()[:3]
        )
        if not generated:
            lines = len(text.splitlines())
            result.require(
                lines <= 600,
                f"{relative}: Rust source exceeds 600 hard lines ({lines})",
            )
        production = _production_rust(path, text)
        # The authority contract's token gate is explicitly production-only.
        # Integration tests are first-party verification code and may use
        # expect/panic to make a failing assertion self-describing; they still
        # remain subject to the source-size/function-size limits below.
        is_runtime = (
            path.name != "build.rs"
            and "test-support" not in path.parts
            and "tests" not in path.parts
        )
        if is_runtime:
            executable = executable_source(path, production)
            for token_id, pattern in RUST_FORBIDDEN.items():
                scan = (
                    source_without_comments(path, production)
                    if token_id == "extern_c"
                    else executable
                )
                occurrences = len(pattern.findall(scan))
                result.require(
                    occurrences == 0,
                    f"{relative}: production forbidden token {token_id} occurs {occurrences} times",
                )
        for name, logical_lines in _rust_function_facts(path, production):
            function_count += 1
            if not generated:
                result.require(
                    logical_lines <= 70,
                    f"{relative}::{name}: function exceeds 70 logical lines ({logical_lines})",
                )
    return file_count, function_count


def _validate_web(root: Path, result: Validation) -> tuple[int, int]:
    typescript_count = 0
    svelte_count = 0
    for path in sorted(_files(root, TYPESCRIPT_ROOTS, ".ts")):
        typescript_count += 1
        if _generated(root, path):
            continue
        lines = _line_count(path)
        relative = path.relative_to(root).as_posix()
        result.require(
            lines <= 500,
            f"{relative}: TypeScript source exceeds 500 hard lines ({lines})",
        )
    for path in sorted(_files(root, SAVELTE_ROOTS, ".svelte")):
        svelte_count += 1
        if _generated(root, path):
            continue
        lines = _line_count(path)
        relative = path.relative_to(root).as_posix()
        result.require(
            lines <= 400,
            f"{relative}: Svelte source exceeds 400 hard lines ({lines})",
        )
    return typescript_count, svelte_count


def _crate_roots(root: Path, result: Validation) -> None:
    for manifest in sorted(root.glob("crates/*/Cargo.toml")) + sorted(
        root.glob("services/*/Cargo.toml")
    ):
        source = manifest.parent / "src"
        candidates = [source / "lib.rs", source / "main.rs"]
        crate_root = next((path for path in candidates if path.is_file()), None)
        relative = manifest.parent.relative_to(root).as_posix()
        result.require(crate_root is not None, f"{relative}: crate root is missing")
        if crate_root is None:
            continue
        text = crate_root.read_text(encoding="utf-8")
        result.require(
            "#![forbid(unsafe_code)]" in text,
            f"{crate_root.relative_to(root).as_posix()}: unsafe_code forbid is missing",
        )


def validate_source_quality(root: Path, result: Validation) -> SourceFacts:
    rust_files, rust_functions = _validate_rust(root, result)
    typescript_files, svelte_files = _validate_web(root, result)
    _crate_roots(root, result)
    return SourceFacts(
        rust_files=rust_files,
        typescript_files=typescript_files,
        svelte_files=svelte_files,
        rust_functions=rust_functions,
    )
