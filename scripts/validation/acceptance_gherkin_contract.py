"""Byte-stable Gherkin clause, example, instance, and oracle contracts."""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import re
import unicodedata
from typing import Any, Iterable


PLACEHOLDER_RE = re.compile(r"<([^<>]+)>")
CLAUSE_DOMAIN = b"GURINNAE-ACCEPTANCE-GHERKIN-CLAUSE-V1\0"
EXAMPLE_DOMAIN = b"GURINNAE-ACCEPTANCE-GHERKIN-EXAMPLE-V1\0"
INSTANCE_DOMAIN = b"GURINNAE-ACCEPTANCE-GHERKIN-INSTANCE-V1\0"
SCENARIO_DOMAIN = b"GURINNAE-ACCEPTANCE-GHERKIN-SCENARIO-V1\0"
ORACLE_DOMAIN = b"GURINNAE-ACCEPTANCE-ORACLE-CONTRACT-V1\0"
SET_DOMAIN = b"GURINNAE-ACCEPTANCE-GHERKIN-SET-V1\0"

class GherkinContractError(ValueError):
    """The feature cannot be compiled without guessing its intended contract."""

    def __init__(self, code: str, source: str, detail: str) -> None:
        super().__init__(f"{code}: {source}: {detail}")
        self.code = code
        self.source = source
        self.detail = detail
def nfc(value: str) -> str:
    return unicodedata.normalize("NFC", value)


def _normal(value: Any) -> Any:
    if isinstance(value, str):
        return nfc(value)
    if isinstance(value, (list, tuple)):
        return [_normal(item) for item in value]
    if isinstance(value, dict):
        return {str(key): _normal(item) for key, item in value.items()}
    return value


def canonical_sha256(domain: bytes, value: object) -> str:
    encoded = json.dumps(
        _normal(value),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    digest = hashlib.sha256()
    digest.update(domain)
    digest.update(len(encoded).to_bytes(8, "big"))
    digest.update(encoded)
    return digest.hexdigest()


def ordered_pair_set_sha256(rows: Iterable[tuple[str, str]]) -> str:
    pairs = sorted(set(rows))
    return canonical_sha256(SET_DOMAIN, [[left, right] for left, right in pairs])


@dataclass(frozen=True)
class RawStep:
    lexical_keyword: str
    effective_phase: str
    text: str
    source_line: int


@dataclass(frozen=True)
class ClauseContract:
    clause_id: str
    scope: str
    source_step_ordinal: int
    lexical_keyword: str
    effective_phase: str
    text: str
    source_path: str
    source_line: int
    sha256: str


@dataclass(frozen=True)
class ExampleContract:
    example_id: str
    row_ordinal: int
    headers: tuple[str, ...]
    values: tuple[str, ...]
    source_path: str
    source_line: int
    sha256: str


@dataclass(frozen=True)
class ClauseInstanceContract:
    instance_id: str
    clause_id: str
    clause_sha256: str
    example_id: str
    example_sha256: str | None
    substituted_text: str
    substituted_text_sha256: str
    sha256: str


@dataclass(frozen=True)
class ScenarioContract:
    scenario_id: str
    feature_file: str
    scenario_title: str
    scenario_kind: str
    source_line: int
    clauses: tuple[ClauseContract, ...]
    examples: tuple[ExampleContract, ...]
    instances: tuple[ClauseInstanceContract, ...]
    clause_set_sha256: str
    example_set_sha256: str
    instance_set_sha256: str
    scenario_contract_sha256: str

    def registry_row(self) -> dict[str, object]:
        clause_by_id = {row.clause_id: row for row in self.clauses}
        observations: list[dict[str, object]] = []
        oracles = [
            [
                f"OR-{row.instance_id}",
                canonical_sha256(
                    ORACLE_DOMAIN,
                    {
                        "scenario_id": self.scenario_id,
                        "instance_id": row.instance_id,
                        "instance_sha256": row.sha256,
                    },
                ),
            ]
            for row in self.instances
            if clause_by_id[row.clause_id].effective_phase == "THEN"
        ]
        oracle_by_instance = {
            str(oracle_id).removeprefix("OR-"): [oracle_id, oracle_sha256]
            for oracle_id, oracle_sha256 in oracles
        }
        for instance in self.instances:
            clause = clause_by_id[instance.clause_id]
            observations.append(
                {
                    "instance_id": instance.instance_id,
                    "instance_sha256": instance.sha256,
                    "clause_id": instance.clause_id,
                    "clause_sha256": instance.clause_sha256,
                    "example_id": instance.example_id,
                    "example_sha256": instance.example_sha256,
                    "phase": clause.effective_phase,
                    "oracle_contract": oracle_by_instance.get(instance.instance_id),
                }
            )
        return {
            "scenario_id": self.scenario_id,
            "feature_file": self.feature_file,
            "scenario_title": self.scenario_title,
            "scenario_kind": self.scenario_kind,
            "source_line": self.source_line,
            "scenario_contract_sha256": self.scenario_contract_sha256,
            "clause_set_sha256": self.clause_set_sha256,
            "example_set_sha256": self.example_set_sha256,
            "instance_set_sha256": self.instance_set_sha256,
            "oracle_set_sha256": ordered_pair_set_sha256(
                (str(row[0]), str(row[1])) for row in oracles
            ),
            "clause_contracts": [[row.clause_id, row.sha256] for row in self.clauses],
            "example_contracts": [[row.example_id, row.sha256] for row in self.examples],
            "instance_contracts": [[row.instance_id, row.sha256] for row in self.instances],
            "oracle_contracts": oracles,
            "observation_contracts": observations,
        }


@dataclass
class ScenarioBuilder:
    scenario_id: str
    title: str
    kind: str
    source_line: int
    steps: list[RawStep]
    example_headers: tuple[str, ...] | None
    example_rows: list[tuple[tuple[str, ...], int]]


def _substitute(
    text: str,
    headers: tuple[str, ...],
    values: tuple[str, ...],
    source: str,
) -> str:
    replacements = dict(zip(headers, values, strict=True))
    missing = sorted(set(PLACEHOLDER_RE.findall(text)) - set(replacements))
    if missing:
        raise GherkinContractError(
            "unknown_example_placeholder",
            source,
            ", ".join(missing),
        )
    return PLACEHOLDER_RE.sub(lambda match: replacements[match.group(1)], text)


def _clause(
    scenario_id: str,
    relative: str,
    scope: str,
    ordinal: int,
    step: RawStep,
) -> ClauseContract:
    clause_id = f"GH-{scenario_id}-{'B' if scope == 'BACKGROUND' else 'S'}-{ordinal:03d}"
    body = {
        "clause_id": clause_id,
        "scope": scope,
        "source_step_ordinal": ordinal,
        "lexical_keyword": step.lexical_keyword,
        "effective_phase": step.effective_phase,
        "text": step.text,
        "source_path": relative,
        "source_line": step.source_line,
    }
    return ClauseContract(**body, sha256=canonical_sha256(CLAUSE_DOMAIN, body))


def _examples(relative: str, builder: ScenarioBuilder) -> list[ExampleContract]:
    rows: list[ExampleContract] = []
    if builder.kind != "OUTLINE":
        if builder.example_headers is not None or builder.example_rows:
            raise GherkinContractError(
                "examples_on_non_outline",
                f"{relative}:{builder.source_line}",
                builder.scenario_id,
            )
        return rows
    headers = builder.example_headers
    if headers is None or not builder.example_rows:
        raise GherkinContractError(
            "outline_without_examples",
            f"{relative}:{builder.source_line}",
            builder.scenario_id,
        )
    if not headers or any(not value for value in headers) or len(set(headers)) != len(headers):
        raise GherkinContractError(
            "invalid_examples_header",
            f"{relative}:{builder.source_line}",
            repr(headers),
        )
    for ordinal, (values, source_line) in enumerate(builder.example_rows, start=1):
        if len(values) != len(headers):
            raise GherkinContractError(
                "examples_width_mismatch",
                f"{relative}:{source_line}",
                f"expected {len(headers)}, got {len(values)}",
            )
        if any(not value for value in values):
            raise GherkinContractError(
                "empty_examples_cell",
                f"{relative}:{source_line}",
                repr(values),
            )
        if values in {row.values for row in rows}:
            raise GherkinContractError(
                "duplicate_examples_row",
                f"{relative}:{source_line}",
                repr(values),
            )
        example_id = f"EX-{builder.scenario_id}-{ordinal:03d}"
        body = {
            "example_id": example_id,
            "row_ordinal": ordinal,
            "headers": list(headers),
            "values": list(values),
            "source_path": relative,
            "source_line": source_line,
        }
        rows.append(
            ExampleContract(
                example_id=example_id,
                row_ordinal=ordinal,
                headers=headers,
                values=values,
                source_path=relative,
                source_line=source_line,
                sha256=canonical_sha256(EXAMPLE_DOMAIN, body),
            )
        )
    return rows


def _instances(
    relative: str,
    builder: ScenarioBuilder,
    clauses: tuple[ClauseContract, ...],
    examples: list[ExampleContract],
) -> list[ClauseInstanceContract]:
    rows: list[ClauseInstanceContract] = []
    for example in examples if examples else [None]:
        for clause in clauses:
            substituted = clause.text
            example_id = "NONE"
            example_sha256 = None
            suffix = "NONE"
            if example is not None:
                substituted = _substitute(
                    clause.text,
                    example.headers,
                    example.values,
                    f"{relative}:{clause.source_line}",
                )
                example_id = example.example_id
                example_sha256 = example.sha256
                suffix = f"{example.row_ordinal:03d}"
            substituted_digest = canonical_sha256(
                INSTANCE_DOMAIN,
                {"kind": "SUBSTITUTED_TEXT", "text": substituted},
            )
            scope = clause.clause_id.rsplit("-", 2)[-2]
            instance_id = (
                f"GI-{builder.scenario_id}-{suffix}-{scope}-"
                f"{clause.source_step_ordinal:03d}"
            )
            body = {
                "instance_id": instance_id,
                "clause_id": clause.clause_id,
                "clause_sha256": clause.sha256,
                "example_id": example_id,
                "example_sha256": example_sha256,
                "substituted_text": substituted,
                "substituted_text_sha256": substituted_digest,
            }
            rows.append(
                ClauseInstanceContract(
                    **body,
                    sha256=canonical_sha256(INSTANCE_DOMAIN, body),
                )
            )
    return rows


def compile_scenario(
    relative: str,
    background: list[RawStep],
    builder: ScenarioBuilder,
) -> ScenarioContract:
    if not any(step.effective_phase == "THEN" for step in builder.steps):
        raise GherkinContractError(
            "scenario_without_result_oracle",
            f"{relative}:{builder.source_line}",
            builder.scenario_id,
        )
    clauses = tuple(
        [
            _clause(builder.scenario_id, relative, "BACKGROUND", index, step)
            for index, step in enumerate(background, start=1)
        ]
        + [
            _clause(builder.scenario_id, relative, "SCENARIO", index, step)
            for index, step in enumerate(builder.steps, start=1)
        ]
    )
    if not clauses:
        raise GherkinContractError(
            "zero_clause_scenario",
            f"{relative}:{builder.source_line}",
            builder.scenario_id,
        )
    examples = _examples(relative, builder)
    instances = _instances(relative, builder, clauses, examples)
    clause_set = ordered_pair_set_sha256((row.clause_id, row.sha256) for row in clauses)
    example_set = ordered_pair_set_sha256((row.example_id, row.sha256) for row in examples)
    instance_set = ordered_pair_set_sha256((row.instance_id, row.sha256) for row in instances)
    scenario_body = {
        "scenario_id": builder.scenario_id,
        "feature_file": relative,
        "scenario_title": builder.title,
        "scenario_kind": builder.kind,
        "source_line": builder.source_line,
        "clauses": [[row.clause_id, row.sha256] for row in clauses],
        "examples": [[row.example_id, row.sha256] for row in examples],
        "instances": [[row.instance_id, row.sha256] for row in instances],
        "clause_set_sha256": clause_set,
        "example_set_sha256": example_set,
        "instance_set_sha256": instance_set,
    }
    return ScenarioContract(
        scenario_id=builder.scenario_id,
        feature_file=relative,
        scenario_title=builder.title,
        scenario_kind=builder.kind,
        source_line=builder.source_line,
        clauses=clauses,
        examples=tuple(examples),
        instances=tuple(instances),
        clause_set_sha256=clause_set,
        example_set_sha256=example_set,
        instance_set_sha256=instance_set,
        scenario_contract_sha256=canonical_sha256(SCENARIO_DOMAIN, scenario_body),
    )
