"""Compile Gurinnae's bounded Gherkin syntax into immutable contracts."""
from __future__ import annotations

from pathlib import Path
import re
from typing import Iterable

from .acceptance_gherkin_contract import (
    GherkinContractError,
    RawStep,
    ScenarioBuilder,
    ScenarioContract,
    canonical_sha256,
    compile_scenario,
    nfc,
    ordered_pair_set_sha256,
)


SCENARIO_ID_RE = re.compile(r"^AC-[A-Z0-9_]+(?:-[A-Z0-9_]+)*-[0-9]{3}$")
SCENARIO_ID_LINE_RE = re.compile(r"^\s*#\s*scenario-id:\s*(\S+)\s*$")
SCENARIO_RE = re.compile(r"^\s*(Scenario Outline|Scenario):\s*(.+?)\s*$")
BACKGROUND_RE = re.compile(r"^\s*Background:\s*(.*?)\s*$")
EXAMPLES_RE = re.compile(r"^\s*Examples:\s*(.*?)\s*$")
STEP_RE = re.compile(r"^\s*(Given|When|Then|And|But)\s+(.+?)\s*$")


def _parse_table_row(line: str, source: str) -> tuple[str, ...]:
    stripped = line.strip()
    if len(stripped) < 2 or not stripped.startswith("|") or not stripped.endswith("|"):
        raise GherkinContractError("invalid_examples_row", source, line)
    cells: list[str] = []
    current: list[str] = []
    escaped = False
    for character in stripped[1:-1]:
        if escaped:
            current.append(character)
            escaped = False
        elif character == "\\":
            escaped = True
        elif character == "|":
            cells.append(nfc("".join(current).strip()))
            current = []
        else:
            current.append(character)
    if escaped:
        current.append("\\")
    cells.append(nfc("".join(current).strip()))
    return tuple(cells)


def _append_step(
    destination: list[RawStep],
    lexical_keyword: str,
    text: str,
    source_line: int,
    source: str,
) -> None:
    if lexical_keyword in {"Given", "When", "Then"}:
        effective_phase = lexical_keyword.upper()
    else:
        if not destination:
            raise GherkinContractError(
                "orphan_conjunction",
                f"{source}:{source_line}",
                f"{lexical_keyword} has no prior Given/When/Then in this scope",
            )
        effective_phase = destination[-1].effective_phase
    destination.append(
        RawStep(
            lexical_keyword=lexical_keyword,
            effective_phase=effective_phase,
            text=nfc(text.strip()),
            source_line=source_line,
        )
    )


def _start_scenario(
    relative: str,
    line_number: int,
    match: re.Match[str],
    pending_id: tuple[str, int] | None,
    builders: list[ScenarioBuilder],
) -> ScenarioBuilder:
    if pending_id is None:
        raise GherkinContractError(
            "missing_scenario_id",
            f"{relative}:{line_number}",
            match.group(2),
        )
    scenario_id, id_line = pending_id
    if SCENARIO_ID_RE.fullmatch(scenario_id) is None:
        raise GherkinContractError(
            "unstable_scenario_id",
            f"{relative}:{id_line}",
            scenario_id,
        )
    if any(row.scenario_id == scenario_id for row in builders):
        raise GherkinContractError(
            "duplicate_scenario_id",
            f"{relative}:{id_line}",
            scenario_id,
        )
    return ScenarioBuilder(
        scenario_id=scenario_id,
        title=nfc(match.group(2).strip()),
        kind="OUTLINE" if match.group(1) == "Scenario Outline" else "SCENARIO",
        source_line=line_number,
        steps=[],
        example_headers=None,
        example_rows=[],
    )


def compile_feature(path: Path, relative: str) -> tuple[ScenarioContract, ...]:
    """Compile one UTF-8 feature and reject ambiguous or incomplete structure."""
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise GherkinContractError("feature_unreadable", relative, str(error)) from error

    background: list[RawStep] = []
    builders: list[ScenarioBuilder] = []
    current: ScenarioBuilder | None = None
    pending_id: tuple[str, int] | None = None
    in_background = False
    in_examples = False
    background_seen = False

    for line_number, line in enumerate(text.splitlines(), start=1):
        id_match = SCENARIO_ID_LINE_RE.match(line)
        if id_match:
            if pending_id is not None:
                raise GherkinContractError(
                    "duplicate_pending_scenario_id",
                    f"{relative}:{line_number}",
                    pending_id[0],
                )
            pending_id = (nfc(id_match.group(1)), line_number)
            continue

        if BACKGROUND_RE.match(line):
            if background_seen:
                raise GherkinContractError(
                    "duplicate_background",
                    f"{relative}:{line_number}",
                    "Background may occur at most once",
                )
            if builders or current is not None:
                raise GherkinContractError(
                    "late_background",
                    f"{relative}:{line_number}",
                    "Background must occur once before all scenarios",
                )
            background_seen = True
            in_background = True
            in_examples = False
            continue

        scenario_match = SCENARIO_RE.match(line)
        if scenario_match:
            current = _start_scenario(
                relative,
                line_number,
                scenario_match,
                pending_id,
                builders,
            )
            builders.append(current)
            pending_id = None
            in_background = False
            in_examples = False
            continue

        if EXAMPLES_RE.match(line):
            if current is None:
                raise GherkinContractError(
                    "orphan_examples",
                    f"{relative}:{line_number}",
                    line.strip(),
                )
            if current.example_headers is not None:
                raise GherkinContractError(
                    "multiple_examples_blocks",
                    f"{relative}:{line_number}",
                    current.scenario_id,
                )
            in_examples = True
            continue

        step_match = STEP_RE.match(line)
        if step_match:
            if in_examples:
                raise GherkinContractError(
                    "step_after_examples",
                    f"{relative}:{line_number}",
                    current.scenario_id if current else "unknown",
                )
            destination = background if in_background else current.steps if current else None
            if destination is None:
                raise GherkinContractError(
                    "orphan_step",
                    f"{relative}:{line_number}",
                    line.strip(),
                )
            _append_step(
                destination,
                step_match.group(1),
                step_match.group(2),
                line_number,
                relative,
            )
            continue

        if in_examples and line.strip().startswith("|"):
            if current is None:
                raise GherkinContractError(
                    "orphan_examples_row",
                    f"{relative}:{line_number}",
                    line.strip(),
                )
            row = _parse_table_row(line, f"{relative}:{line_number}")
            if current.example_headers is None:
                current.example_headers = row
            else:
                current.example_rows.append((row, line_number))

    if pending_id is not None:
        raise GherkinContractError(
            "orphan_scenario_id",
            f"{relative}:{pending_id[1]}",
            pending_id[0],
        )
    if not builders:
        raise GherkinContractError("zero_scenario_feature", relative, "no scenarios")
    return tuple(compile_scenario(relative, background, row) for row in builders)


def compile_features(root: Path, paths: Iterable[str]) -> tuple[ScenarioContract, ...]:
    rows: list[ScenarioContract] = []
    seen: set[str] = set()
    for relative in sorted(paths):
        for row in compile_feature(root / relative, relative):
            if row.scenario_id in seen:
                raise GherkinContractError(
                    "duplicate_scenario_id",
                    relative,
                    row.scenario_id,
                )
            seen.add(row.scenario_id)
            rows.append(row)
    return tuple(rows)


__all__ = [
    "GherkinContractError",
    "ScenarioContract",
    "canonical_sha256",
    "compile_feature",
    "compile_features",
    "ordered_pair_set_sha256",
]
