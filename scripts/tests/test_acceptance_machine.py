from __future__ import annotations

import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from validation.acceptance_machine import (
    MachineReportError,
    parse_nextest_discovery,
    parse_nextest_junit,
    parse_playwright_report,
)


class AcceptanceMachineReportTests(unittest.TestCase):
    def test_nextest_discovery_requires_one_exact_nonignored_identity(self) -> None:
        value = {
            "rust-suites": {
                "target": {
                    "testcases": {"ac_contract_001": {"ignored": False}}
                }
            },
            "test-count": 1,
        }
        counts = parse_nextest_discovery(
            json.dumps(value).encode(), "ac_contract_001"
        )
        self.assertEqual(counts.discovered, 1)
        value["rust-suites"]["target"]["testcases"]["extra"] = {
            "ignored": False
        }
        value["test-count"] = 2
        with self.assertRaises(MachineReportError):
            parse_nextest_discovery(json.dumps(value).encode(), "ac_contract_001")

    def test_nextest_junit_recomputes_success_and_failure(self) -> None:
        success = b'''<testsuites><testsuite tests="1" failures="0" errors="0" skipped="0"><testcase name="ac_contract_001"/></testsuite></testsuites>'''
        self.assertTrue(
            parse_nextest_junit(success, "ac_contract_001").success()
        )
        failure = b'''<testsuites><testsuite tests="1" failures="1" errors="0" skipped="0"><testcase name="ac_contract_001"><failure>sentinel</failure></testcase></testsuite></testsuites>'''
        self.assertTrue(
            parse_nextest_junit(
                failure, "ac_contract_001", expected_failure=True
            ).sentinel_failure()
        )
        with self.assertRaises(MachineReportError):
            parse_nextest_junit(failure, "ac_contract_001")

    def test_playwright_json_binds_title_file_project_and_terminal(self) -> None:
        title = "[AC-CONTRACT-001] exact"
        path = "tests/e2e/acceptance/contract.spec.ts"
        report = {
            "suites": [
                {
                    "specs": [
                        {
                            "title": title,
                            "file": path,
                            "tests": [
                                {
                                    "projectName": "chromium",
                                    "annotations": [],
                                    "results": [{"retry": 0, "status": "passed"}],
                                }
                            ],
                        }
                    ]
                }
            ]
        }
        self.assertTrue(
            parse_playwright_report(
                json.dumps(report).encode(),
                title,
                path,
                list_only=False,
            ).success()
        )
        report["suites"][0]["specs"][0]["tests"][0]["results"].append(
            {"retry": 1, "status": "passed"}
        )
        with self.assertRaises(MachineReportError):
            parse_playwright_report(
                json.dumps(report).encode(), title, path, list_only=False
            )

    def test_duplicate_json_key_is_rejected(self) -> None:
        with self.assertRaisesRegex(MachineReportError, "duplicate JSON key"):
            parse_nextest_discovery(
                b'{"rust-suites":{},"rust-suites":{},"test-count":0}',
                "ac_contract_001",
            )


if __name__ == "__main__":
    unittest.main()
