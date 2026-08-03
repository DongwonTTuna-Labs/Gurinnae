import unittest

from scripts.validation.api import (
    PROVIDER_CONTROL_SIDE_DOOR_OPERATION_IDS,
    _error_catalog_for_operation,
)


class ApiValidationTests(unittest.TestCase):
    def test_additive_error_catalog_is_limited_to_declared_base_extensions(self) -> None:
        base = {"BASE_ERROR": {"layer": "DOMAIN", "http_status": 422}}
        additive = {"ADDITIVE_ERROR": {"layer": "DOMAIN", "http_status": 422}}
        extensions = frozenset({"placeLegalHold"})

        self.assertIn(
            "ADDITIVE_ERROR",
            _error_catalog_for_operation("placeLegalHold", base, additive, extensions),
        )
        self.assertNotIn(
            "ADDITIVE_ERROR",
            _error_catalog_for_operation("assignCorrection", base, additive, extensions),
        )

    def test_provider_side_door_keeps_its_additive_error_catalog(self) -> None:
        base = {"BASE_ERROR": {"layer": "DOMAIN", "http_status": 422}}
        additive = {
            "ACTION_PROPOSAL_REQUIRED": {"layer": "DOMAIN", "http_status": 409}
        }
        operation_id = next(iter(PROVIDER_CONTROL_SIDE_DOOR_OPERATION_IDS))

        self.assertIn(
            "ACTION_PROPOSAL_REQUIRED",
            _error_catalog_for_operation(operation_id, base, additive, frozenset()),
        )
