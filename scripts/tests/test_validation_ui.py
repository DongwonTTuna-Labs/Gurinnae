from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

import yaml


SCRIPTS = Path(__file__).resolve().parents[1]
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from validation.design_ui_operations import (
    design_screen_row,
    validate_additive_operation_section_closure,
)
from validation.models import Validation
from validation.ui import _action_operation, _external_operation_catalog, _proposal_only_fences


class UiOperationCatalogTests(unittest.TestCase):
    def test_missing_design_screen_fails_closed_without_crashing(self) -> None:
        result = Validation()

        row = design_screen_row(result, {}, "PUB-035")

        self.assertIsNone(row)
        self.assertEqual(
            result.errors,
            ["PUB-035: screen is missing from design closure"],
        )

    def test_missing_additive_design_operation_fails_closed_without_crashing(self) -> None:
        result = Validation()

        validate_additive_operation_section_closure(
            result,
            "PUB-023",
            {},
            {"downloadTransparencyReport": {"reports"}},
        )

        self.assertEqual(
            result.errors,
            [
                "PUB-023.downloadTransparencyReport: additive operation is missing from design closure"
            ],
        )

    def write_catalogs(self, root: Path, *, duplicate: bool = False) -> None:
        documents = {
            'specs/api/operation-contracts.yaml': {
                'operations': [{'operation_id': 'baseOperation'}],
            },
            'specs/product/addendum-operation-contracts.yaml': {
                'operations': [{
                    'operation_id': 'baseOperation' if duplicate else 'additiveOperation',
                    'api': 'control-api',
                    'method': 'POST',
                    'path': '/v1/internal/action-proposals',
                    'kind': 'COMMAND',
                    'response': 'ActionProposalReceiptV1',
                    'errors': ['INVALID_PARAMETER'],
                }],
            },
            'specs/product/addendum-resource-error-contracts.yaml': {
                'operation_bindings': {
                    'baseOperation' if duplicate else 'additiveOperation': {
                        'request_schema': 'CreateActionProposalRequestV1',
                        'success_schema': 'ActionProposalReceiptV1',
                    },
                },
            },
        }
        for relative, document in documents.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(yaml.safe_dump(document), encoding='utf-8')

    def test_unions_and_normalizes_additive_external_operations(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_catalogs(root)
            result = Validation()

            catalog = _external_operation_catalog(root, result)

            self.assertEqual(result.errors, [])
            self.assertEqual(set(catalog), {'baseOperation', 'additiveOperation'})
            additive = catalog['additiveOperation']
            self.assertEqual(additive['operation_kind'], 'COMMAND')
            self.assertEqual(additive['request_schema'], 'CreateActionProposalRequestV1')
            self.assertEqual(additive['response_schema'], 'ActionProposalReceiptV1')

    def test_duplicate_operation_id_is_rejected_and_not_indexed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_catalogs(root, duplicate=True)
            result = Validation()

            catalog = _external_operation_catalog(root, result)

            self.assertEqual(catalog, {})
            self.assertEqual(
                result.errors,
                ["duplicate external operation IDs across base/additive catalogs: ['baseOperation']"],
            )

    def test_only_explicit_proposal_binding_resolves_to_required_entry(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / 'specs/ui/screen-action-contracts.yaml'
            path.parent.mkdir(parents=True)
            unbound = {
                'screen_id': 'CAS-002',
                'legacy_action_id': 'transition',
                'legacy_operation_id': 'transitionCase',
                'policy': 'PROPOSAL_ONLY_UNTIL_AUTHORIZED_EXECUTION',
                'required_entry_operation': 'createActionProposal',
                'direct_effect_forbidden': True,
            }
            bound = {
                **unbound,
                'screen_id': 'OPS-005',
                'legacy_action_id': 'disable-routing',
                'legacy_operation_id': 'disableProviderRouting',
                'proposal_binding': {
                    'actionKind': 'PROVIDER_CONTROL',
                    'providerControl.operationId': 'disableProviderRouting',
                },
            }
            path.write_text(yaml.safe_dump({'legacy_side_door_fences': [unbound, bound]}), encoding='utf-8')
            operations = {
                'transitionCase': {'operation_kind': 'COMMAND'},
                'disableProviderRouting': {'operation_kind': 'COMMAND'},
                'createActionProposal': {'operation_kind': 'COMMAND'},
            }
            result = Validation()
            fences = _proposal_only_fences(root, result, operations)
            matched: set[tuple[str, str]] = set()

            legacy_resolved = _action_operation(
                'CAS-002',
                {'id': 'transition', 'operation_id': 'transitionCase'},
                operations,
                fences,
                matched,
                result,
            )
            proposal_resolved = _action_operation(
                'OPS-005',
                {'id': 'disable-routing', 'operation_id': 'disableProviderRouting'},
                operations,
                fences,
                matched,
                result,
            )

            self.assertEqual(result.errors, [])
            self.assertEqual(legacy_resolved, ('transitionCase', operations['transitionCase']))
            self.assertEqual(proposal_resolved, ('createActionProposal', operations['createActionProposal']))
            self.assertEqual(matched, {('CAS-002', 'transition'), ('OPS-005', 'disable-routing')})

    def test_proposal_fence_duplicate_and_operation_mismatch_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            row = {
                'screen_id': 'CAS-002',
                'legacy_action_id': 'transition',
                'legacy_operation_id': 'transitionCase',
                'policy': 'PROPOSAL_ONLY_UNTIL_AUTHORIZED_EXECUTION',
                'required_entry_operation': 'createActionProposal',
                'direct_effect_forbidden': True,
            }
            path = root / 'specs/ui/screen-action-contracts.yaml'
            path.parent.mkdir(parents=True)
            path.write_text(yaml.safe_dump({'legacy_side_door_fences': [row, row]}), encoding='utf-8')
            operations = {
                'transitionCase': {'operation_kind': 'COMMAND'},
                'differentOperation': {'operation_kind': 'COMMAND'},
                'createActionProposal': {'operation_kind': 'COMMAND'},
            }
            result = Validation()
            fences = _proposal_only_fences(root, result, operations)
            self.assertEqual(fences, {})
            self.assertTrue(any('duplicate proposal-only fence triples' in error for error in result.errors))
            self.assertTrue(any('ambiguous proposal-only fence action keys' in error for error in result.errors))

            result = Validation()
            path.write_text(yaml.safe_dump({'legacy_side_door_fences': [row]}), encoding='utf-8')
            fences = _proposal_only_fences(root, result, operations)
            resolved = _action_operation(
                'CAS-002',
                {'id': 'transition', 'operation_id': 'differentOperation'},
                operations,
                fences,
                set(),
                result,
            )
            self.assertIsNone(resolved)
            self.assertTrue(any('proposal-only fence operation transitionCase != differentOperation' in error for error in result.errors))

            result = Validation()
            malformed = {**row, 'proposal_binding': {
                'actionKind': 'PROVIDER_CONTROL',
                'providerControl.operationId': 'differentOperation',
                'unexpected': True,
            }}
            path.write_text(yaml.safe_dump({'legacy_side_door_fences': [malformed]}), encoding='utf-8')
            _proposal_only_fences(root, result, operations)
            self.assertTrue(any('proposal_binding fields are not closed' in error for error in result.errors))
            self.assertTrue(any('proposal_binding operation differs' in error for error in result.errors))


if __name__ == '__main__':
    unittest.main()
