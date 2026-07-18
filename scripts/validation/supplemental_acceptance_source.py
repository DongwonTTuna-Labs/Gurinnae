"""Fail-closed source scanning for executable supplemental acceptance tests."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re


def _mask(output: list[str], start: int, end: int) -> None:
    for index in range(start, end):
        if output[index] not in {"\n", "\r"}:
            output[index] = " "


def _quoted_end(text: str, start: int, quote: str) -> int:
    index = start + 1
    while index < len(text):
        if text[index] == "\\":
            index += 2
            continue
        if text[index] == quote:
            return index + 1
        index += 1
    return len(text)


def _raw_string_end(text: str, start: int) -> int | None:
    index = start
    if text.startswith(("br", "cr"), index):
        index += 2
    elif text.startswith("r", index):
        index += 1
    else:
        return None
    hashes = 0
    while index < len(text) and text[index] == "#":
        hashes += 1
        index += 1
    if index >= len(text) or text[index] != '"':
        return None
    terminator = '"' + ("#" * hashes)
    end = text.find(terminator, index + 1)
    return len(text) if end < 0 else end + len(terminator)


def _rust_char_end(text: str, start: int) -> int | None:
    index = start + 1
    if index >= len(text) or text[index] in {"\n", "\r", "'"}:
        return None
    while index < len(text) and text[index] not in {"\n", "\r"}:
        if text[index] == "\\":
            index += 2
            continue
        if text[index] == "'":
            return index + 1
        index += 1
    return None


def _rust_scan(text: str, *, mask_literals: bool) -> str:
    output = list(text)
    index = 0
    while index < len(text):
        raw_end = _raw_string_end(text, index)
        if raw_end is not None:
            if mask_literals:
                _mask(output, index, raw_end)
            index = raw_end
            continue
        if text.startswith("//", index):
            end = text.find("\n", index + 2)
            end = len(text) if end < 0 else end
            _mask(output, index, end)
            index = end
            continue
        if text.startswith("/*", index):
            depth = 1
            end = index + 2
            while end < len(text) and depth:
                if text.startswith("/*", end):
                    depth += 1
                    end += 2
                elif text.startswith("*/", end):
                    depth -= 1
                    end += 2
                else:
                    end += 1
            _mask(output, index, end)
            index = end
            continue
        string_start = index
        if text[index] in {"b", "c"} and index + 1 < len(text) and text[index + 1] == '"':
            string_start = index + 1
        if text[string_start] == '"':
            end = _quoted_end(text, string_start, '"')
            if mask_literals:
                _mask(output, index, end)
            index = end
            continue
        char_start = index
        if text[index] == "b" and index + 1 < len(text) and text[index + 1] == "'":
            char_start = index + 1
        if text[char_start] == "'":
            end = _rust_char_end(text, char_start)
            if end is not None:
                if mask_literals:
                    _mask(output, index, end)
                index = end
                continue
        index += 1
    return "".join(output)


def executable_source(path: Path, text: str) -> str:
    """Return position-preserving code with comments and literals masked."""
    return _rust_scan(text, mask_literals=True) if path.suffix == ".rs" else text


def source_without_comments(path: Path, text: str) -> str:
    """Return position-preserving source where comments cannot satisfy literals."""
    return _rust_scan(text, mask_literals=False) if path.suffix == ".rs" else text


def rust_function_end(path: Path, text: str, start: int) -> int | None:
    """Return the exact end of a balanced Rust test function body."""
    if path.suffix != ".rs":
        return None
    code = executable_source(path, text)
    opening = code.find("{", start)
    if opening < 0:
        return None
    depth = 0
    for index in range(opening, len(code)):
        if code[index] == "{":
            depth += 1
        elif code[index] == "}":
            depth -= 1
            if depth == 0:
                return index + 1
    return None


def _balanced_token_end(code: str, opening: int) -> int | None:
    pairs = {"(": ")", "[": "]", "{": "}"}
    stack: list[str] = []
    for index in range(opening, len(code)):
        token = code[index]
        if token in pairs:
            stack.append(pairs[token])
        elif token in pairs.values():
            if not stack or stack.pop() != token:
                return None
            if not stack:
                return index + 1
    return None


RUST_ASSERTION = re.compile(
    r"(?<![A-Za-z0-9_:])::std::"
    r"(?P<name>assert|assert_eq|assert_ne|assert_matches)\s*!\s*"
    r"(?P<opening>[({[])"
)
OBSERVED_ASSERTION = re.compile(
    r"(?<![A-Za-z0-9_:])::gurine_acceptance_testkit::"
    r"(?P<name>observed_precondition|observed_action|observed_assert|observed_assert_eq|observed_assert_ne|observed_assert_matches)"
    r"\s*!\s*(?P<opening>[({[])"
)


@dataclass(frozen=True)
class RustAssertionFacts:
    count: int
    trivial: bool
    ordinals: tuple[int, ...]
    binding_valid: bool


@dataclass(frozen=True)
class RustObservationBinding:
    macro_kind: str
    scenario_id: str
    ordinal: int
    instance_id: str
    instance_sha256: str
    clause_id: str
    clause_sha256: str
    example_id: str
    example_sha256: str | None
    phase: str
    oracle_id: str | None
    oracle_sha256: str | None


def _rust_depths(code: str) -> list[tuple[int, int, int]]:
    depths: list[tuple[int, int, int]] = []
    curly = 0
    parenthesis = 0
    square = 0
    for token in code:
        depths.append((curly, parenthesis, square))
        if token == "{":
            curly += 1
        elif token == "}":
            curly = max(0, curly - 1)
        elif token == "(":
            parenthesis += 1
        elif token == ")":
            parenthesis = max(0, parenthesis - 1)
        elif token == "[":
            square += 1
        elif token == "]":
            square = max(0, square - 1)
    return depths


def _statement_prefix_is_empty(
    code: str,
    depths: list[tuple[int, int, int]],
    start: int,
) -> bool:
    boundary = -1
    for index in range(start - 1, -1, -1):
        curly, parenthesis, square = depths[index]
        token = code[index]
        if token == ";" and (curly, parenthesis, square) == (1, 0, 0):
            boundary = index
            break
        if token == "}" and (curly, parenthesis, square) == (2, 0, 0):
            boundary = index
            break
        if token == "{" and (curly, parenthesis, square) == (0, 0, 0):
            boundary = index
            break
    return not code[boundary + 1 : start].strip()


def _observed_binding(
    text: str,
    opening: int,
    scenario_id: str,
) -> tuple[int | None, int]:
    match = re.match(
        rf'\s*"{re.escape(scenario_id)}"\s*,\s*([0-9]+)\s*,',
        text[opening + 1 :],
    )
    if match is None:
        return None, opening + 1
    return int(match.group(1)), opening + 1 + match.end()


def rust_assertion_facts(
    path: Path,
    text: str,
    scenario_id: str,
) -> RustAssertionFacts | None:
    """Inventory runtime-observed assertion sites in one Rust test body."""
    if path.suffix != ".rs":
        return None
    code = executable_source(path, text)
    depths = _rust_depths(code)
    count = 0
    trivial = False
    ordinals: list[int] = []
    binding_valid = True
    for match in OBSERVED_ASSERTION.finditer(code):
        curly, parenthesis, square = depths[match.start()]
        if (curly, parenthesis, square) != (1, 0, 0):
            continue
        if not _statement_prefix_is_empty(code, depths, match.start()):
            continue
        opening = match.start("opening")
        end = _balanced_token_end(code, opening)
        if end is None:
            continue
        ordinal, assertion_start = _observed_binding(text, opening, scenario_id)
        binding_valid = binding_valid and ordinal is not None
        if ordinal is not None:
            ordinals.append(ordinal)
        count += 1
        first_argument = code[assertion_start : end - 1].strip()
        if match.group("name") == "observed_assert" and re.fullmatch(
            r"true(?:\s*,[\s\S]*)?",
            first_argument,
        ):
            trivial = True
    bare_assertions = any(
        depths[match.start()] == (1, 0, 0)
        for match in RUST_ASSERTION.finditer(code)
    )
    return RustAssertionFacts(
        count=count,
        trivial=trivial,
        ordinals=tuple(ordinals),
        binding_valid=binding_valid and not bare_assertions,
    )


def rust_observation_bindings(
    path: Path,
    text: str,
) -> tuple[tuple[RustObservationBinding, ...], bool]:
    """Return exact top-level observed assertion bindings and bare-assert state."""
    if path.suffix != ".rs":
        return (), False
    code = executable_source(path, text)
    depths = _rust_depths(code)
    bindings: list[RustObservationBinding] = []
    common_pattern = re.compile(
        r'\s*"(?P<scenario>[A-Z0-9_-]+)"\s*,\s*(?P<ordinal>[0-9]+)\s*,\s*'
        r'"(?P<instance>[A-Z0-9_-]+)"\s*,\s*"(?P<instance_sha>[0-9a-f]{64})"\s*,\s*'
        r'"(?P<clause>[A-Z0-9_-]+)"\s*,\s*"(?P<clause_sha>[0-9a-f]{64})"\s*,\s*'
        r'"(?P<example>[A-Z0-9_-]+)"\s*,\s*"(?P<example_sha>NONE|[0-9a-f]{64})"\s*,'
    )
    oracle_pattern = re.compile(
        r'\s*"(?P<oracle>[A-Z0-9_-]+)"\s*,\s*'
        r'"(?P<oracle_sha>[0-9a-f]{64})"\s*,'
    )
    for match in OBSERVED_ASSERTION.finditer(code):
        if depths[match.start()] != (1, 0, 0):
            continue
        if not _statement_prefix_is_empty(code, depths, match.start()):
            continue
        opening = match.start("opening")
        end = _balanced_token_end(code, opening)
        if end is None:
            continue
        body = text[opening + 1 : end - 1]
        common = common_pattern.match(body)
        if common is None:
            continue
        macro_kind = match.group("name")
        phase = (
            "GIVEN"
            if macro_kind == "observed_precondition"
            else "WHEN"
            if macro_kind == "observed_action"
            else "THEN"
        )
        oracle_id: str | None = None
        oracle_sha256: str | None = None
        if phase == "THEN":
            oracle = oracle_pattern.match(body, common.end())
            if oracle is None:
                continue
            oracle_id = oracle.group("oracle")
            oracle_sha256 = oracle.group("oracle_sha")
        bindings.append(
            RustObservationBinding(
                macro_kind=macro_kind,
                scenario_id=common.group("scenario"),
                ordinal=int(common.group("ordinal")),
                instance_id=common.group("instance"),
                instance_sha256=common.group("instance_sha"),
                clause_id=common.group("clause"),
                clause_sha256=common.group("clause_sha"),
                example_id=common.group("example"),
                example_sha256=(
                    None
                    if common.group("example_sha") == "NONE"
                    else common.group("example_sha")
                ),
                phase=phase,
                oracle_id=oracle_id,
                oracle_sha256=oracle_sha256,
            )
        )
    bare_assertions = any(
        depths[match.start()] == (1, 0, 0)
        for match in RUST_ASSERTION.finditer(code)
    )
    return tuple(bindings), bare_assertions
