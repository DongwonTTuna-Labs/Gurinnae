from __future__ import annotations

from typing import Any

from .design_operations import OperationFacts
from .design_support import DesignDocuments, nonempty


class PrivateOperationClosureValidator:
    def __init__(
        self,
        documents: DesignDocuments,
        operations: OperationFacts,
    ) -> None:
        self._result = documents.result
        self._state_machines = documents.state_machines
        self._operations = operations
        self._referenced_control: set[str] = set()
        self._referenced_application: set[str] = set()
        self._referenced_billing: set[str] = set()
        self._control_targets: dict[str, set[str]] = {}
        self._application_targets: dict[str, set[str]] = {}
        self._billing_targets: dict[str, set[str]] = {}

    def observe_edge(
        self,
        machine_name: str,
        edge: dict[str, Any],
    ) -> None:
        private_operation_id = edge.get("private_operation")
        private_command_id = edge.get("private_command")
        private_billing_operation_id = edge.get("private_billing_operation")
        actor = edge.get("actor")
        self._result.require(
            sum(
                value is not None
                for value in (
                    private_command_id,
                    private_billing_operation_id,
                )
            )
            <= 1,
            f"{machine_name}: edge cannot mix private application and private billing executors",
        )
        if private_operation_id is not None:
            self._referenced_control.add(private_operation_id)
            self._control_targets.setdefault(
                private_operation_id, set()
            ).add(machine_name)
            self._result.require(
                private_operation_id in self._operations.private_control_ids,
                f"{machine_name}: edge references unknown private control operation {private_operation_id}",
            )
        if private_command_id is not None:
            self._referenced_application.add(private_command_id)
            self._application_targets.setdefault(
                private_command_id, set()
            ).add(machine_name)
            self._result.require(
                private_command_id
                in self._operations.private_application_ids
                and nonempty(actor),
                f"{machine_name}: edge references unknown private application command {private_command_id} or lacks its executor actor",
            )
        if private_billing_operation_id is not None:
            self._referenced_billing.add(private_billing_operation_id)
            self._billing_targets.setdefault(
                private_billing_operation_id, set()
            ).add(machine_name)
            self._result.require(
                private_billing_operation_id
                in self._operations.private_billing_command_ids
                and nonempty(actor),
                f"{machine_name}: edge references unknown private billing command {private_billing_operation_id} or lacks its executor actor",
            )

    def validate_lifecycles(self) -> None:
        private_control_bindings = self._state_machines.get(
            "private_control_lifecycle_bindings", {}
        ).get("current_bindings", {})
        self._result.require(
            set(private_control_bindings)
            == self._operations.private_control_ids
            == self._referenced_control,
            "private control operation registry, lifecycle binding and edge set are not exact",
        )
        self._validate_targets(
            private_control_bindings,
            self._control_targets,
            "private control lifecycle binding does not equal its machine-edge targets",
        )
        private_application_bindings = self._state_machines.get(
            "private_application_lifecycle_bindings", {}
        ).get("current_bindings", {})
        self._result.require(
            set(private_application_bindings)
            == self._operations.private_application_ids
            == self._referenced_application,
            "private application command registry, lifecycle binding and edge set are not exact",
        )
        self._validate_targets(
            private_application_bindings,
            self._application_targets,
            "private application lifecycle binding does not equal its machine-edge targets",
        )
        private_billing_bindings = self._state_machines.get(
            "private_billing_gateway_lifecycle_bindings", {}
        ).get("current_bindings", {})
        self._result.require(
            set(private_billing_bindings)
            == self._operations.private_billing_command_ids
            == self._referenced_billing,
            "private billing command registry, lifecycle binding and edge set are not exact",
        )
        self._validate_targets(
            private_billing_bindings,
            self._billing_targets,
            "private billing lifecycle binding does not equal its machine-edge targets",
        )

    def _validate_targets(
        self,
        bindings: dict[str, Any],
        machine_targets: dict[str, set[str]],
        message: str,
    ) -> None:
        for operation_id, targets in bindings.items():
            target_roots = {
                target.split(".", 1)[0]
                for target in targets
                if isinstance(target, str)
            }
            self._result.require(
                target_roots == machine_targets.get(operation_id, set()),
                f"{operation_id}: {message}",
            )


def validate_payment_runtime_closure(
    documents: DesignDocuments,
    binding_by: dict[str, dict[str, Any]],
    alias_by_aggregate: dict[str, dict[str, Any]],
) -> None:
    result = documents.result
    payment_runtime = binding_by.get("PaymentRuntime", {})
    expected_relations = {
        "ops.cash_application_facts",
        "ops.tax_invoice_issuance_receipts",
        "ops.payment_method_bindings",
        "ops.payment_charge_attempts",
        "ops.provider_webhook_receipts",
        "ops.donation_facts",
    }
    expected_operations = {
        "private.GetDonationFixtureOffer",
        "private.QueueDonationIntent",
        "private.ReceivePaymentWebhook",
    }
    expected_events = {
        "donation.fact_recorded.v1",
        "notification.payment_review_requested.v1",
    }
    result.require(
        set(payment_runtime.get("relations", [])) == expected_relations
        and set(payment_runtime.get("operations", [])) == expected_operations
        and set(payment_runtime.get("events", [])) == expected_events,
        "PaymentRuntime must exactly own the six payment relations, three private HTTP operations and two events",
    )
    expected_invariants = {
        "owner_function_surface": "closed typed operations only; table names, arbitrary SQL and generic JSON are forbidden",
        "payment_effect": "no contract, entitlement, factual or editorial priority, publication, detection or public-access mutation",
        "public_projection": "private donation facts may create only a funding snapshot candidate; publication requires the existing independently reviewed FundingDisclosure path",
        "private_fact_read": "projection-worker uses an exact SECURITY DEFINER owner lookup; direct ops.donation_facts SELECT is forbidden",
        "governance_binding": "when revisionId or revisionDigest is present, the database owner recomputes and locks it; caller-trusted governance bindings are forbidden",
        "production_payment": "disabled; deterministic TEST_MODE_ONLY fixtures have no production authority",
    }
    result.require(
        payment_runtime.get("invariants") == expected_invariants,
        "PaymentRuntime typed owner, payment-effect and public-projection invariants drifted",
    )
    action_proposal = binding_by.get("ActionProposal", {})
    result.require(
        "ops.action_approval_economics_import_details"
        in action_proposal.get("relations", [])
        and "private.ExecuteEconomicsImport"
        in action_proposal.get("operations", []),
        "economics import approval detail and executor must remain owned by ActionProposal",
    )
    funding_disclosure = binding_by.get("FundingDisclosure", {})
    result.require(
        "downloadTransparencyReport"
        in funding_disclosure.get("operations", []),
        "downloadTransparencyReport must remain owned by FundingDisclosure",
    )
    result.require(
        {
            aggregate: alias_by_aggregate.get(aggregate, {}).get(
                "canonical_noun"
            )
            for aggregate in ("DonationFact", "PaymentReviewTask")
        }
        == {
            "DonationFact": "PaymentRuntime",
            "PaymentReviewTask": "PaymentRuntime",
        },
        "payment event aggregate aliases must resolve exactly to PaymentRuntime",
    )
