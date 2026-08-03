"""Strict parsers for authoritative nextest and Playwright machine reports."""
from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path, PurePosixPath
import xml.etree.ElementTree as ET


class MachineReportError(ValueError):
    """A report cannot prove one exact terminal test execution."""


@dataclass(frozen=True)
class TerminalCounts:
    discovered: int
    started: int
    terminal: int
    passed: int
    failed: int
    skipped: int
    retried: int

    def success(self) -> bool:
        return self == TerminalCounts(1, 1, 1, 1, 0, 0, 0)

    def sentinel_failure(self) -> bool:
        return self == TerminalCounts(1, 1, 1, 0, 1, 0, 0)


def load_closed_json_bytes(content: bytes, source: str) -> object:
    def reject_duplicates(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise MachineReportError(f"duplicate JSON key in {source}: {key}")
            result[key] = value
        return result

    try:
        return json.loads(content.decode("utf-8"), object_pairs_hook=reject_duplicates)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise MachineReportError(f"invalid JSON in {source}: {error}") from error


def parse_nextest_discovery(content: bytes, expected_test: str) -> TerminalCounts:
    value = load_closed_json_bytes(content, "nextest discovery")
    if not isinstance(value, dict):
        raise MachineReportError("nextest discovery root must be an object")
    suites = value.get("rust-suites")
    if not isinstance(suites, dict):
        raise MachineReportError("nextest discovery lacks rust-suites")
    identities: list[str] = []
    ignored: list[bool] = []
    for suite_name, suite in suites.items():
        if not isinstance(suite_name, str) or not isinstance(suite, dict):
            raise MachineReportError("nextest suite entry is malformed")
        testcases = suite.get("testcases")
        if not isinstance(testcases, dict):
            raise MachineReportError(f"nextest suite {suite_name} lacks testcases")
        for identity, row in testcases.items():
            if not isinstance(identity, str) or not isinstance(row, dict):
                raise MachineReportError("nextest testcase entry is malformed")
            identities.append(identity)
            ignored.append(bool(row.get("ignored", False)))
    declared_count = value.get("test-count")
    if isinstance(declared_count, bool) or not isinstance(declared_count, int):
        raise MachineReportError("nextest test-count must be an integer")
    if declared_count != len(identities):
        raise MachineReportError(
            f"nextest test-count differs: declared={declared_count} actual={len(identities)}"
        )
    if identities != [expected_test] or ignored != [False]:
        raise MachineReportError(
            f"nextest discovery is not exact: expected={[expected_test]!r} actual={identities!r} ignored={ignored!r}"
        )
    return TerminalCounts(1, 0, 0, 0, 0, 0, 0)


def _integer_attribute(node: ET.Element, name: str) -> int:
    raw = node.attrib.get(name)
    try:
        value = int(raw) if raw is not None else None
    except ValueError as error:
        raise MachineReportError(f"JUnit {name} is not an integer: {raw!r}") from error
    if value is None or value < 0:
        raise MachineReportError(f"JUnit {name} must be nonnegative")
    return value


def parse_nextest_junit(
    content: bytes,
    expected_test: str,
    *,
    expected_failure: bool = False,
) -> TerminalCounts:
    try:
        root = ET.fromstring(content)
    except ET.ParseError as error:
        raise MachineReportError(f"invalid nextest JUnit XML: {error}") from error
    if root.tag not in {"testsuites", "testsuite"}:
        raise MachineReportError(f"unexpected JUnit root: {root.tag}")
    cases = root.findall(".//testcase")
    if len(cases) != 1:
        raise MachineReportError(f"JUnit must contain one testcase, got {len(cases)}")
    case = cases[0]
    name = case.attrib.get("name")
    if name != expected_test:
        raise MachineReportError(f"JUnit testcase differs: {name!r} != {expected_test!r}")
    skipped = len(case.findall("skipped"))
    failures = len(case.findall("failure")) + len(case.findall("error"))
    if skipped > 1 or failures > 1:
        raise MachineReportError("JUnit testcase has multiple terminal child nodes")
    suite_nodes = [root] if root.tag == "testsuite" else root.findall("testsuite")
    if not suite_nodes:
        raise MachineReportError("JUnit contains no testsuite")
    aggregate = {
        "tests": sum(_integer_attribute(node, "tests") for node in suite_nodes),
        "failures": sum(_integer_attribute(node, "failures") for node in suite_nodes),
        "errors": sum(_integer_attribute(node, "errors") for node in suite_nodes),
        "skipped": sum(_integer_attribute(node, "skipped") for node in suite_nodes),
    }
    if aggregate["tests"] != 1:
        raise MachineReportError(f"JUnit aggregate test count differs: {aggregate}")
    aggregate_failed = aggregate["failures"] + aggregate["errors"]
    if aggregate_failed != failures or aggregate["skipped"] != skipped:
        raise MachineReportError(
            f"JUnit aggregate differs from testcase terminal state: aggregate={aggregate}"
        )
    counts = TerminalCounts(
        discovered=1,
        started=1,
        terminal=1,
        passed=1 - failures - skipped,
        failed=failures,
        skipped=skipped,
        retried=0,
    )
    if expected_failure and not counts.sentinel_failure():
        raise MachineReportError(f"expected one failed sentinel test, got {counts}")
    if not expected_failure and not counts.success():
        raise MachineReportError(f"expected one passing test, got {counts}")
    return counts


def _playwright_specs(value: object) -> list[dict[str, object]]:
    specs: list[dict[str, object]] = []

    def visit(node: object) -> None:
        if isinstance(node, dict):
            raw_specs = node.get("specs")
            if isinstance(raw_specs, list):
                for spec in raw_specs:
                    if not isinstance(spec, dict):
                        raise MachineReportError("Playwright spec entry is malformed")
                    specs.append(spec)
            raw_suites = node.get("suites")
            if isinstance(raw_suites, list):
                for child in raw_suites:
                    visit(child)

    visit(value)
    return specs


def _same_report_path(actual: object, expected: str) -> bool:
    if not isinstance(actual, str) or not actual or "\\" in actual:
        return False
    path = PurePosixPath(actual)
    if path.is_absolute() or ".." in path.parts:
        return False
    return path.as_posix() == expected or path.as_posix().endswith(f"/{expected}")


def parse_playwright_report(
    content: bytes,
    expected_title: str,
    expected_file: str,
    *,
    list_only: bool,
    expected_failure: bool = False,
) -> TerminalCounts:
    value = load_closed_json_bytes(content, "Playwright JSON report")
    if not isinstance(value, dict):
        raise MachineReportError("Playwright report root must be an object")
    specs = _playwright_specs(value)
    if len(specs) != 1:
        raise MachineReportError(f"Playwright report must contain one spec, got {len(specs)}")
    spec = specs[0]
    if spec.get("title") != expected_title or not _same_report_path(spec.get("file"), expected_file):
        raise MachineReportError(
            f"Playwright spec identity differs: title={spec.get('title')!r} file={spec.get('file')!r}"
        )
    tests = spec.get("tests")
    if not isinstance(tests, list) or len(tests) != 1 or not isinstance(tests[0], dict):
        raise MachineReportError("Playwright spec must contain one test")
    test = tests[0]
    if test.get("projectName") != "chromium":
        raise MachineReportError(f"Playwright project differs: {test.get('projectName')!r}")
    if list_only:
        return TerminalCounts(1, 0, 0, 0, 0, 0, 0)
    results = test.get("results")
    if not isinstance(results, list) or len(results) != 1 or not isinstance(results[0], dict):
        raise MachineReportError("Playwright test must contain one terminal result")
    result = results[0]
    retry = result.get("retry")
    status = result.get("status")
    if retry != 0:
        raise MachineReportError(f"Playwright retry differs: {retry!r}")
    expected_status = "failed" if expected_failure else "passed"
    if status != expected_status:
        raise MachineReportError(f"Playwright terminal status differs: {status!r}")
    annotations = test.get("annotations", [])
    if not isinstance(annotations, list) or annotations:
        raise MachineReportError(f"Playwright annotations are forbidden: {annotations!r}")
    counts = TerminalCounts(
        discovered=1,
        started=1,
        terminal=1,
        passed=0 if expected_failure else 1,
        failed=1 if expected_failure else 0,
        skipped=0,
        retried=0,
    )
    return counts


def artifact_media_type(path: Path) -> str:
    suffix = path.suffix.lower()
    return {
        ".json": "application/json",
        ".jsonl": "application/jsonl",
        ".xml": "application/xml",
        ".txt": "text/plain",
        ".log": "text/plain",
        ".zip": "application/zip",
        ".png": "image/png",
    }.get(suffix, "application/octet-stream")


__all__ = [
    "MachineReportError",
    "TerminalCounts",
    "artifact_media_type",
    "load_closed_json_bytes",
    "parse_nextest_discovery",
    "parse_nextest_junit",
    "parse_playwright_report",
]
