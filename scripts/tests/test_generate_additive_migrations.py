from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]


class AdditiveMigrationGenerationTest(unittest.TestCase):
    def test_exact_source_relation_counts(self) -> None:
        expected = {"0025": 36, "0026": 27, "0027": 22, "0028": 19}
        for ordinal, count in expected.items():
            path = next((ROOT / "specs/database/addendum").glob(f"{ordinal}-*.yaml"))
            document = yaml.safe_load(path.read_text())
            raw = document.get("tables", document.get("table_contracts", {}))
            actual = len(raw) if isinstance(raw, (dict, list)) else 0
            self.assertEqual(actual, count, ordinal)

    def test_generated_migrations_have_no_empty_indexes(self) -> None:
        for path in sorted((ROOT / "db/migrations").glob("002[5-8]_*.sql")):
            text = path.read_text()
            self.assertNotRegex(text, r"CREATE (?:UNIQUE )?INDEX [^;]+\(\s*\)")
            self.assertEqual(text.count("BEGIN;"), 1)
            self.assertEqual(text.count("COMMIT;"), 1)

    def test_text_digest_defaults_are_sql_literals(self) -> None:
        text = (ROOT / "db/migrations/0025_evidence_snapshots_and_search.sql").read_text()
        self.assertNotRegex(text, r"DEFAULT [0-9a-f]{64},")
        self.assertIn("DEFAULT '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945'", text)

    def test_signatureless_owner_procedures_are_not_guessed(self) -> None:
        text = (ROOT / "db/migrations/0025_evidence_snapshots_and_search.sql").read_text()
        self.assertNotIn("raw.insert_source_document_revision(jsonb)", text)
        self.assertNotIn("core.begin_dataset_snapshot(jsonb)", text)


if __name__ == "__main__":
    unittest.main()
