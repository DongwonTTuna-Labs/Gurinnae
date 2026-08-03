from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

import yaml


SCRIPTS = Path(__file__).resolve().parents[1]
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from validation.assurance import (
    PRIVATE_BILLING_AUTHORITY,
    _private_billing_catalog,
    _resolve_additive_action_assurance,
    _validate_private_billing_action,
)
from validation.models import Validation


QUEUE_OPERATION_ID = "private.QueueDonationIntent"


def write_private_billing_catalog(root: Path, *, include_fake_id: bool = False) -> None:
    operation = {
        "operation_kind": "COMMAND",
        "transport": "PRIVATE_BILLING_GATEWAY_HTTP",
        "entrypoint": {
            "method": "POST",
            "path": "/internal/v1/donation-intents",
        },
        "request_schema": "DonationIntentQueueRequestV1",
        "response_schema": "DonationIntentQueuedReceiptV1",
        "authority_boundary": {"authority": PRIVATE_BILLING_AUTHORITY},
        "effect_owner": "billing-gateway",
        "errors": ["INVALID_REQUEST"],
    }
    owner = {
        "operation_id": QUEUE_OPERATION_ID,
        "method": "POST",
        "path": "/internal/v1/donation-intents",
        "kind": "COMMAND",
        "caller": "public-web",
        "runtime_mode": "TEST_MODE_ONLY",
    }
    binding = {
        "scope": "PRIVATE_BILLING_GATEWAY",
        "operation_kind": "COMMAND",
        "source_pointer": (
            "specs/product/addendum-operation-contracts.yaml"
            "#private_billing_gateway_operations['private.QueueDonationIntent']"
        ),
        "request_schema": "DonationIntentQueueRequestV1",
        "success_schema": "DonationIntentQueuedReceiptV1",
        "caller": "public-web",
        "issuer": "public-web",
        "audience": "billing-gateway",
        "effect_owner": "billing-gateway",
    }
    declared = [QUEUE_OPERATION_ID]
    if include_fake_id:
        declared.append("private.FakeDonationIntent")
    documents = {
        "specs/product/addendum-operation-contracts.yaml": {
            "private_billing_gateway_operations": {QUEUE_OPERATION_ID: operation},
        },
        "specs/product/owner-addendum-2026-07-14.yaml": {
            "private_billing_gateway_operations": [owner],
        },
        "specs/product/addendum-resource-error-contracts.yaml": {
            "set_equality": {
                "private_billing_gateway_operation_ids": declared,
            },
            "private_billing_gateway_operation_bindings": {
                QUEUE_OPERATION_ID: binding,
            },
            "private_billing_gateway_request_schemas": {
                QUEUE_OPERATION_ID: {"name": "DonationIntentQueueRequestV1"},
            },
            "private_billing_gateway_error_sets": {
                QUEUE_OPERATION_ID: ["INVALID_REQUEST"],
            },
        },
    }
    for relative, document in documents.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(yaml.safe_dump(document), encoding="utf-8")


def valid_private_action() -> dict:
    return {
        "interaction_kind": "COMMAND",
        "assurance_level": "NONE",
        "step_up_required": False,
        "server_only": True,
        "browser_direct": False,
        "availability": {
            "default": "DISABLED",
            "production": {
                "state": "UNAVAILABLE",
                "reason": PRIVATE_BILLING_AUTHORITY,
                "enabled": False,
            },
            "test_only": {
                "authority": PRIVATE_BILLING_AUTHORITY,
                "tier": "TEST_FIXTURE",
                "lifecycle": "EPHEMERAL",
                "enabled": True,
            },
        },
    }


class AdditiveActionAssuranceTests(unittest.TestCase):
    def test_query_download_with_none_is_allowed(self) -> None:
        result = Validation()

        resolved = _resolve_additive_action_assurance(
            {"kind": "QUERY", "assurance": "NONE"},
            "DOWNLOAD",
            result,
            "PUB-023:download-report",
        )

        self.assertEqual(resolved, "NONE")
        self.assertEqual(result.errors, [])

    def test_query_with_command_assurance_fails_closed(self) -> None:
        result = Validation()

        resolved = _resolve_additive_action_assurance(
            {"kind": "QUERY", "assurance": "ACTIVE_SESSION"},
            "COMMAND",
            result,
            "PUB-X:invalid-query",
        )

        self.assertIsNone(resolved)
        self.assertEqual(len(result.errors), 2)

    def test_conditional_command_keeps_step_up_upper_bound(self) -> None:
        result = Validation()

        resolved = _resolve_additive_action_assurance(
            {"kind": "COMMAND", "assurance": "conditional-decision"},
            "COMMAND",
            result,
            "REV-X:decision",
        )

        self.assertEqual(resolved, "STEP_UP")
        self.assertEqual(result.errors, [])


class PrivateBillingAssuranceTests(unittest.TestCase):
    def test_closed_queue_operation_resolves_and_validates(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_private_billing_catalog(root)
            result = Validation()

            catalog = _private_billing_catalog(root, result)
            operation = catalog[QUEUE_OPERATION_ID]
            _validate_private_billing_action(
                operation,
                valid_private_action(),
                result,
                "PUB-035:queue-donation",
            )

            self.assertEqual(set(catalog), {QUEUE_OPERATION_ID})
            self.assertEqual(operation["runtime_mode"], "TEST_MODE_ONLY")
            self.assertEqual(result.errors, [])

    def test_private_prefix_does_not_bypass_registry_closure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_private_billing_catalog(root, include_fake_id=True)
            result = Validation()

            catalog = _private_billing_catalog(root, result)

            self.assertEqual(catalog, {})
            self.assertEqual(
                result.errors,
                ["private billing operation registries differ"],
            )

    def test_browser_direct_private_action_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_private_billing_catalog(root)
            result = Validation()
            operation = _private_billing_catalog(root, result)[QUEUE_OPERATION_ID]
            action = valid_private_action()
            action["browser_direct"] = True

            _validate_private_billing_action(
                operation,
                action,
                result,
                "PUB-035:queue-donation",
            )

            self.assertEqual(
                result.errors,
                ["PUB-035:queue-donation: private billing action is not server-only"],
            )


if __name__ == "__main__":
    unittest.main()
