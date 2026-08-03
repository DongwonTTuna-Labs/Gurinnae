from __future__ import annotations

import copy
import hashlib
import re
import runpy
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

import yaml


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from journey_contracts import (
    JOURNEY_IDS,
    _normalized_edges,
    _screen_journey_registry,
    _validate_identity,
)


class ScreenJourneyRegistryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.authority = yaml.safe_load(
            (ROOT / "specs/product/addendum-journey-contracts.yaml").read_text(
                encoding="utf-8"
            )
        )
        self.catalog = yaml.safe_load(
            (ROOT / "specs/ui/screen-catalog.yaml").read_text(encoding="utf-8")
        )

    def test_registry_is_exact_95_and_pub_035_is_j01(self) -> None:
        registry = _screen_journey_registry(self.authority, self.catalog)

        self.assertEqual(len(registry), 95)
        self.assertEqual(registry["PUB-035"], "J-01")
        self.assertEqual(set(registry.values()) - set(JOURNEY_IDS), set())

    def test_prior_94_mapping_rows_are_preserved_exactly(self) -> None:
        authority_rows = dict(self.authority["screen_journey_registry"])
        added = authority_rows.pop("PUB-035")
        provenance = self.authority["screen_journey_registry_provenance"]
        fixture_path = ROOT / provenance["prior_runtime_artifact"]
        fixture_bytes = fixture_path.read_bytes()
        fixture_rows = dict(
            re.findall(
                rb'^\s+"([A-Z]+-[0-9]{3})": "(J-[0-9]{2})",$',
                fixture_bytes,
                re.MULTILINE,
            )
        )
        decoded_fixture_rows = {
            screen_id.decode("ascii"): journey_id.decode("ascii")
            for screen_id, journey_id in fixture_rows.items()
        }
        mapping_preimage = "".join(
            f"{screen_id}={journey_id}\n"
            for screen_id, journey_id in sorted(authority_rows.items())
        ).encode("utf-8")

        self.assertEqual(added, "J-01")
        self.assertEqual(
            provenance["prior_runtime_artifact_role"],
            "IMMUTABLE_HISTORICAL_TEST_FIXTURE_NOT_ACTIVE_GENERATED_AUTHORITY",
        )
        self.assertNotEqual(
            provenance["prior_runtime_artifact"],
            "packages/ui/src/generated-screen-journeys.ts",
        )
        self.assertEqual(
            hashlib.sha256(fixture_bytes).hexdigest(),
            provenance["prior_runtime_artifact_sha256"],
        )
        self.assertEqual(decoded_fixture_rows, authority_rows)
        self.assertEqual(
            provenance["prior_mapping_preimage_contract"],
            "UTF8_LEXICOGRAPHIC_SCREEN_ID_EQUALS_JOURNEY_ID_TRAILING_LF",
        )
        self.assertEqual(len(authority_rows), provenance["prior_runtime_row_count"])
        self.assertEqual(
            hashlib.sha256(mapping_preimage).hexdigest(),
            provenance["prior_mapping_sha256"],
        )

    def test_generator_rejects_duplicate_journey_registry_key(self) -> None:
        authority_path = ROOT / "specs/product/addendum-journey-contracts.yaml"
        original_read_text = Path.read_text

        def read_text(path: Path, *args: object, **kwargs: object) -> str:
            if path == authority_path:
                return "screen_journey_registry:\n  PUB-001: J-01\n  PUB-001: J-02\n"
            return original_read_text(path, *args, **kwargs)

        with patch.object(Path, "read_text", read_text):
            with self.assertRaisesRegex(
                ValueError,
                "duplicate YAML key 'PUB-001'",
            ):
                runpy.run_path(
                    str(ROOT / "scripts/generate_typed_screen_registry.py"),
                    run_name="__duplicate_key_canary__",
                )

    def test_missing_screen_membership_fails_closed(self) -> None:
        authority = copy.deepcopy(self.authority)
        authority["screen_journey_registry"].pop("PUB-035")

        with self.assertRaisesRegex(ValueError, "screen-catalog-set-equal"):
            _screen_journey_registry(authority, self.catalog)

    def test_duplicate_screen_id_fails_closed(self) -> None:
        catalog = copy.deepcopy(self.catalog)
        catalog["screens"].append(copy.deepcopy(catalog["screens"][0]))

        with self.assertRaisesRegex(ValueError, "95 unique screen IDs"):
            _screen_journey_registry(self.authority, catalog)

    def test_unknown_journey_id_and_journey_key_drift_fail_closed(self) -> None:
        authority = copy.deepcopy(self.authority)
        authority["screen_journey_registry"]["PUB-035"] = "J-99"
        with self.assertRaisesRegex(ValueError, "unknown JourneyId"):
            _screen_journey_registry(authority, self.catalog)

        authority = copy.deepcopy(self.authority)
        authority["journey_contracts"]["J-99"] = authority["journey_contracts"].pop(
            "J-12"
        )
        screen_ids = {screen["id"] for screen in self.catalog["screens"]}
        with self.assertRaisesRegex(ValueError, "journey contract set drifted"):
            _validate_identity(
                authority,
                _normalized_edges(authority),
                screen_ids,
            )


if __name__ == "__main__":
    unittest.main()
