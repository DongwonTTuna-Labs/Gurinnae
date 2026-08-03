#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml


ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / "specs/ui/navigation-action-contracts.yaml"

ROUTE_PARAMETER_TYPES = {
    "agencySlug": "public-slug",
    "caseId": "uuid",
    "caseSlug": "public-slug",
    "contractId": "uuid",
    "correctionId": "uuid",
    "evidenceId": "uuid",
    "jobId": "uuid",
    "revision": "int64>=1",
    "ruleId": "rule-id",
    "runId": "uuid",
    "signalId": "uuid",
    "snapshotId": "uuid",
    "sourceId": "source-id",
    "supplierSlug": "public-slug",
    "systemPath": "not-found|maintenance|degraded|offline|error",
    "userId": "uuid",
    "version": "rule-version",
}

SAFE_QUERY_KEYS = {
    "PUB-003": ["limit", "publicationState", "agencyId", "supplierId", "ruleId", "publishedFrom", "publishedTo", "hasResponse", "hasCorrection", "sort"],
    "PUB-007": ["limit", "q", "agencyType", "jurisdiction", "sort"],
    "PUB-009": ["limit", "q", "businessStatus", "identityStatus", "sort"],
    "PUB-011": ["limit", "q", "agencyId", "supplierId", "contractStatus", "procurementMethod", "signedFrom", "signedTo", "amountMin", "amountMax", "sort", "format"],
    "PUB-016": ["limit", "status", "sort"],
    "PUB-018": ["limit", "publicationState", "publishedFrom", "publishedTo", "sort"],
    "INT-001": [],
    "INT-002": ["taskStatus", "taskType", "overdueOnly", "limit", "sort"],
    "INT-003": ["q", "types", "status", "limit", "sort"],
    "INT-004": ["unreadOnly", "notificationType", "limit", "sort"],
    "SIG-001": ["signalStatus", "severity", "ruleId", "assignedUserId", "limit", "sort"],
    "CAS-001": ["investigationState", "publicationState", "resolutionCode", "priority", "assigneeUserId", "limit", "sort"],
    "CAS-004": ["caseId", "verificationStatus", "classification", "evidenceType", "limit", "sort"],
    "CAS-010": ["caseId", "status", "agentType", "limit", "sort"],
    "CAS-012": ["caseId", "eventType", "actorId", "from", "to", "limit", "sort"],
    "CAS-016": ["caseId", "action", "actorId", "from", "to", "limit", "sort", "auditExportId"],
    "REV-001": ["reviewStatus", "reviewType", "assigneeUserId", "overdueOnly", "limit", "sort"],
    "COR-001": ["status", "assigneeUserId", "overdueOnly", "limit", "sort"],
    "SRC-001": ["enabled", "status", "connectorType", "limit", "sort"],
    "SRC-003": ["sourceId", "status", "mode", "limit", "sort"],
    "RULE-001": ["status", "ruleFamily", "limit", "sort"],
    "OPS-002": ["queue", "jobStatus", "jobType", "limit", "sort"],
    "OPS-005": ["enabled", "providerType", "routingStatus", "limit", "sort"],
    "AUD-001": ["q", "action", "actorId", "objectType", "outcome", "from", "to", "limit", "sort", "auditExportId"],
    "ADM-001": ["status", "roleId", "q", "limit", "sort"],
    "ADM-003": ["riskLevel", "systemRole", "limit", "sort"],
}


def update(row: dict[str, Any], value: dict[str, Any]) -> None:
    for key, item in value.items():
        if isinstance(item, dict) and isinstance(row.get(key), dict):
            update(row[key], item)
        else:
            row[key] = item


def remove_stale_gap_markers(value: Any) -> None:
    if isinstance(value, dict):
        for key in list(value):
            item = value[key]
            if isinstance(item, str) and (
                "UNRESOLVED" in item or item == "undefined_in_sources"
            ):
                del value[key]
            else:
                remove_stale_gap_markers(item)
    elif isinstance(value, list):
        value[:] = [
            item
            for item in value
            if not (
                isinstance(item, str)
                and ("UNRESOLVED" in item or item == "undefined_in_sources")
            )
        ]
        for item in value:
            remove_stale_gap_markers(item)


def main() -> None:
    document = yaml.safe_load(TARGET.read_text(encoding="utf-8"))
    rows = document["navigation_contracts"]
    profiles = document["invalid_behavior_profiles"]
    profiles["missing_contract_fail_closed"] = profiles.pop("unresolved_contract")
    for row in rows.values():
        if row.get("invalid_behavior") == "unresolved_contract":
            row["invalid_behavior"] = "missing_contract_fail_closed"
    decisions: dict[str, dict[str, Any]] = {
        "PUB-001.search": {"required_context": {"entered_search_query": {"source": "search_form.q", "query_key": "q", "type": "string[1..512]"}}, "preserved_query_keys": ["q"]},
        "PUB-001.subscribe": {"required_context": {"scope_type": {"value": "CORRECTIONS", "transport": "query:scope", "type": "CORRECTIONS"}}},
        "PUB-004.request-correction": {"required_context": {"target_case": {"source": "current_case.caseSlug", "transport": "query:case", "type": "public-slug"}}},
        "PUB-005.compare": {"target": {"fragment": "comparison"}, "required_context": {"comparison_revision": {"source": "comparison_selector.revision", "transport": "query:compareTo", "type": "int64>=1"}}},
        "PUB-006.view-rule": {"required_context": {"reproduced_rule_version": {"source": "reproduction.ruleVersion", "transport": "query:version", "type": "rule-version"}}},
        "PUB-014.view-related-cases": {"required_context": {"ruleId": {"source": "current_route.ruleId", "query_key": "ruleId", "type": "rule-id"}}, "preserved_query_keys": ["ruleId"]},
        "PUB-017.view-related-rules": {"required_context": {"sourceId": {"source": "current_route.sourceId", "query_key": "sourceId", "type": "source-id"}}, "preserved_query_keys": ["sourceId"]},
        "PUB-021.view-data-policy": {"target": {"screen_id": "PUB-020", "route": "/data", "fragment": "license"}},
        "PUB-028.manage-request": {"required_context": {"correction_request_receipt_session": {"source": "current_scoped_session", "type": "scoped-correction-receipt-session"}}},
        "PUB-031.privacy-contact": {"target": {"screen_id": "PUB-026", "route": "/contact", "fragment": "form"}, "required_context": {"contact_topic": {"value": "PRIVACY", "transport": "query:topic", "type": "contact-topic"}}},
        "PUB-033.report-accessibility": {"target": {"screen_id": "PUB-026", "route": "/contact", "fragment": "form"}, "required_context": {"contact_topic": {"value": "ACCESSIBILITY_PROBLEM", "transport": "query:topic", "type": "contact-topic"}}},
        "PUB-033.request-alternative": {"target": {"screen_id": "PUB-026", "route": "/contact", "fragment": "form"}, "required_context": {"contact_topic": {"value": "ALTERNATIVE_FORMAT", "transport": "query:topic", "type": "contact-topic"}}},
        "PUB-034.view-status": {"target": {"screen_id": "PUB-034", "route": "/{systemPath}", "fragment": "status"}, "bindings": {"systemPath": {"source": "current_route.systemPath", "type": ROUTE_PARAMETER_TYPES["systemPath"]}}, "concrete_path": "current_route.systemPath"},
        "RSP-001.report-problem": {"target": {"screen_id": "RSP-008", "route": "/respond/unavailable", "fragment": "actions"}, "required_context": {"reason": {"value": "ACCESS_PROBLEM", "transport": "scoped-session-state"}}},
        "RSP-006.submit-supplement": {"target": {"screen_id": "RSP-006", "route": "/respond/receipt", "fragment": "next"}, "required_context": {"mode": {"value": "SUPPLEMENT_GUIDANCE_ONLY", "transport": "local-fragment"}}},
        "RSP-008.request-new-link": {"target": {"screen_id": "PUB-026", "route": "/contact", "fragment": "form"}, "required_context": {"contact_topic": {"value": "RESPONSE_LINK_REISSUE", "transport": "query:topic", "type": "contact-topic"}}},
        "RSP-008.contact-owner": {"target": {"screen_id": "PUB-026", "route": "/contact", "fragment": "form"}, "required_context": {"contact_topic": {"value": "RESPONSE_OWNER_CONTACT", "transport": "query:topic", "type": "contact-topic"}}},
        "AUTH-002.cancel": {"target": {"kind": "ACTION_BOUND_SAFE_RETURN", "source": "signed_step_up_context.return_to", "allowlist": "catalog-internal-routes", "fallback_screen_id": "INT-002", "fallback_route": "/internal/my-work"}, "preserved_query_keys": ["signed_step_up_context.allowlisted_query"]},
        "INT-001.open-task": {"target": {"kind": "VALIDATED_INTERNAL_HREF", "source": "selected_task.href", "schema": "TaskSummary.href"}, "bindings": {"task_target": {"source": "selected_task.href", "type": "catalog-internal-uri-reference"}}},
        "INT-002.open-task": {"target": {"kind": "VALIDATED_INTERNAL_HREF", "source": "selected_task.href", "schema": "TaskSummary.href"}, "bindings": {"task_target": {"source": "selected_task.href", "type": "catalog-internal-uri-reference"}}},
        "INT-001.open-incident": {"required_context": {"selected_incident_identity": {"source": "selected_incident.incidentId", "transport": "query:incidentId", "type": "uuid"}}},
        "INT-003.open-result": {"target": {"kind": "DISCRIMINATED_INTERNAL_SEARCH_HREF", "source": "selected_result.href", "schema": "InternalRecordsSearchResultItem.href", "allowed_types": ["CASE", "SIGNAL", "EVIDENCE", "AGENT_RUN", "AUDIT_EVENT"]}, "bindings": {"result_target": {"source": "selected_result.href", "type": "catalog-internal-uri-reference"}}},
        "INT-004.open": {"target": {"kind": "VALIDATED_INTERNAL_HREF", "source": "selected_notification.href", "schema": "Notification.href"}, "bindings": {"notification_target": {"source": "selected_notification.href", "type": "nullable-catalog-internal-uri-reference"}}},
        "CAS-002.start-next": {"target": {"kind": "VALIDATED_INTERNAL_HREF", "source": "case_overview.nextRequiredActions[selected].href", "schema": "TaskAction.href"}, "bindings": {"next_task_target": {"source": "case_overview.nextRequiredActions[selected].href", "type": "catalog-internal-uri-reference"}}},
        "CAS-008.open-submission": {"required_context": {"selected_submission_identity": {"source": "selected_submission.submissionId", "transport": "query:submissionId", "type": "uuid"}}},
        "CAS-012.open-event": {"required_context": {"selected_event_identity": {"source": "selected_event.eventId", "transport": "query:eventId", "type": "event-id"}}},
        "CAS-013.open-blocker": {"target": {"kind": "VALIDATED_INTERNAL_HREF", "source": "selected_blocker.resolutionAction.href", "schema": "ReviewBlockerResolutionAction.href"}, "bindings": {"blocker_target": {"source": "selected_blocker.resolutionAction.href", "type": "catalog-internal-uri-reference"}}},
        "CAS-014.open-review": {"bindings": {"snapshotId": {"availability": "required non-null reviewSnapshotId from current publication preview"}}},
        "CAS-015.open-request": {"bindings": {"correctionId": {"relation_from_request": "selected_request.currentCorrectionId must be a non-null UUID linked to that request"}}},
        "CAS-016.open-event": {"required_context": {"selected_event_identity": {"source": "selected_event.eventId", "transport": "query:eventId", "type": "event-id"}}},
        "SRC-004.open-quarantine": {"required_context": {"selected_quarantine_record_identity": {"source": "selected_record.quarantineRecordId", "transport": "query:quarantineId", "type": "uuid"}}},
        "RULE-001.propose-version": {"target": {"screen_id": "RULE-002", "route": "/internal/rules/{ruleId}/versions/{version}", "fragment": "approval"}, "bindings": {"version": {"source": "selected_rule.currentVersion", "type": "rule-version"}}, "arrival_action": "RULE-002.create-draft"},
        "RULE-003.open-sample": {"target": {"kind": "VALIDATED_SAMPLE_HREF", "source": "selected_sample.href", "schema": "RuleEvaluationSampleV1.href", "allowed_types": ["SIGNAL", "CASE", "PUBLIC_CASE"]}, "bindings": {"sample_target": {"source": "selected_sample.href", "type": "catalog-authorized-uri-reference"}}},
        "OPS-001.open-incident": {"required_context": {"selected_incident_identity": {"source": "selected_incident.incidentId", "transport": "query:incidentId", "type": "uuid"}}},
        "OPS-004.open-provider": {"required_context": {"provider_filter": {"source": "selected_provider.providerId", "query_key": "providerId", "type": "provider-id"}}, "preserved_query_keys": ["providerId"]},
        "OPS-005.open-provider": {"required_context": {"selected_provider_identity": {"source": "selected_provider.providerId", "transport": "query:providerId", "type": "provider-id"}}},
        "AUD-001.open-event": {"required_context": {"selected_event_identity": {"source": "selected_event.eventId", "transport": "query:eventId", "type": "event-id"}}},
        "ADM-003.open-role": {"required_context": {"selected_role_identity": {"source": "selected_role.roleId", "transport": "query:roleId", "type": "role-id"}}},
    }
    for key, row in rows.items():
        source_screen = key.split(".", 1)[0]
        if row.get("preserved_query_keys") == ["UNRESOLVED:source-query-allowlist"]:
            row["preserved_query_keys"] = SAFE_QUERY_KEYS[source_screen]
        for binding in row.get("bindings", {}).values():
            if binding.get("type") == "exact_destination_request_type":
                parameter = next(
                    name for name, value in row["bindings"].items() if value is binding
                )
                binding["type"] = ROUTE_PARAMETER_TYPES[parameter]
        update(row, decisions.get(key, {}))
        row["status"] = "resolved"
        row.pop("candidate_screens", None)
        target = row.get("target")
        row["history_semantics"] = (
            "REPLACE_FRAGMENT"
            if isinstance(target, dict)
            and target.get("screen_id") == source_screen
            and target.get("fragment")
            else "PUSH"
        )
        row["availability_by_state"] = {
            "enabled": "all required typed bindings are present, authorized and current",
            "disabled": "any required binding is absent, invalid, stale or outside the route allowlist",
        }
        row["arrival_focus"] = "destination main heading, selected record heading, or named fragment heading"
        row["oracle"] = f"UX-NAV-{key.replace('.', '-').upper()}"
    document["status"] = "REVIEW_REQUIRED"
    document["scope"] = "all 102 authority navigation actions with owner-resolved destinations"
    document.pop("ambiguities", None)
    document["owner_decisions"] = [
        "Dynamic task and notification links use only server-produced href fields validated against the 95-route same-origin catalog.",
        "Response help and link-reissue paths use the public contact form without carrying response object identity in the URL.",
        "Additional-material navigation on RSP-006 opens guidance only; it does not invent a supplemental-submission API.",
        "Query preservation excludes cursor, token, proof and secret fields and uses only the exact per-screen allowlists in this file.",
    ]
    document["rules"] = [
        rule
        for rule in document["rules"]
        if "UNRESOLVED" not in rule
    ] + [
        "A missing destination discriminator, binding, safe query key or return context is a validation failure and never an implementation default."
    ]
    remove_stale_gap_markers(document)
    rendered = yaml.safe_dump(
        document,
        sort_keys=False,
        allow_unicode=True,
        width=130,
    )
    if "UNRESOLVED" in rendered or "undefined_in_sources" in rendered:
        for line in rendered.splitlines():
            if "UNRESOLVED" in line or "undefined_in_sources" in line:
                print(line)
        raise SystemExit("navigation closure still contains an unresolved marker")
    TARGET.write_text(rendered, encoding="utf-8")


if __name__ == "__main__":
    main()
