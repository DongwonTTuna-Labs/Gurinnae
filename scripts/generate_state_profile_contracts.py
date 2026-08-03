#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any

import yaml


ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / "specs/ui/state-profile-contracts.yaml"


def eq(path: str, value: Any) -> dict[str, Any]:
    return {"path": path, "op": "eq", "value": value}


def gt(path: str, value: Any) -> dict[str, Any]:
    return {"path": path, "op": "gt", "value": value}


def semantics() -> dict[str, dict[str, Any]]:
    return {
        "initial-loading": {"family": "initial-read", "trigger": {"all": [eq("signals.blocking_pending", True), eq("signals.has_display_data", False)]}, "preserve": "none", "action_policy": "none", "focus": "main-heading", "live": "polite-once"},
        "loading": {"family": "initial-read", "trigger": {"all": [eq("signals.blocking_pending", True), eq("signals.has_display_data", False)]}, "preserve": "none", "action_policy": "none", "focus": "main-heading", "live": "polite-once"},
        "refreshing": {"family": "background-read", "trigger": {"all": [eq("signals.background_pending", True), eq("signals.has_display_data", True)]}, "preserve": "visible-data-and-focus", "action_policy": "keep-safe-actions", "focus": "preserve", "live": "polite-once-after-completion"},
        "empty": {"family": "confirmed-zero", "trigger": {"all": [eq("signals.blocking_pending", False), eq("signals.blocking_failure", False), eq("signals.authorized_record_count", 0), eq("signals.filter_count", 0), eq("signals.coverage_complete", True)]}, "preserve": "scope-and-freshness", "action_policy": "screen-empty-recovery", "focus": "empty-heading", "live": "polite-once"},
        "filtered-empty": {"family": "confirmed-filtered-zero", "trigger": {"all": [eq("signals.blocking_pending", False), eq("signals.blocking_failure", False), eq("signals.authorized_record_count", 0), gt("signals.filter_count", 0), eq("signals.coverage_complete", True)]}, "preserve": "query-filters-sort", "action_policy": "clear-or-edit-filter", "focus": "result-summary", "live": "polite-once"},
        "partial": {"family": "partial-data", "trigger": {"all": [eq("signals.has_display_data", True), eq("signals.required_slice_complete", False), eq("signals.blocking_failure", False)]}, "preserve": "available-data-freshness-and-missing-scope", "action_policy": "retry-missing-slice", "focus": "preserve", "live": "polite-once"},
        "stale": {"family": "stale-data", "trigger": {"all": [eq("signals.has_display_data", True), eq("signals.freshness_state", "STALE")]}, "preserve": "last-verified-data-and-as-of", "action_policy": "refresh-read-only", "focus": "stale-notice", "live": "polite-once"},
        "invalid-filter": {"family": "invalid-query", "trigger": {"all": [eq("signals.query_validation", "INVALID"), eq("signals.query_broadened", False)]}, "preserve": "entered-query-and-valid-filters", "action_policy": "correct-filter", "focus": "error-summary", "live": "assertive-once"},
        "error": {"family": "blocking-failure", "trigger": {"all": [eq("signals.blocking_failure", True), eq("signals.has_display_data", False)]}, "preserve": "truthful-saved-state-and-support-reference", "action_policy": "retry-when-safe", "focus": "error-heading", "live": "assertive-once"},
        "server-error": {"family": "save-or-submit-failure", "trigger": {"all": [eq("signals.server_failure", True), eq("signals.persisted_outcome", False)]}, "preserve": "draft-and-last-server-ack", "action_policy": "retry-same-idempotency-key-when-safe", "focus": "error-summary", "live": "assertive-once"},
        "offline": {"family": "connectivity-loss", "trigger": {"all": [eq("signals.connectivity", "OFFLINE"), eq("signals.persisted_outcome", False)]}, "preserve": "visible-data-local-input-and-last-server-ack", "action_policy": "disable-network-actions-until-online", "focus": "preserve", "live": "polite-once"},
        "success": {"family": "successful-read-or-submit", "trigger": {"all": [eq("signals.blocking_pending", False), eq("signals.blocking_failure", False), eq("signals.required_slice_complete", True), eq("signals.outcome_state", "SUCCESS")]}, "preserve": "current-authoritative-data-or-receipt", "action_policy": "screen-primary", "focus": "main-answer-or-receipt", "live": "polite-once-if-async"},
        "current": {"family": "current-content", "trigger": {"all": [eq("signals.content_revision_state", "CURRENT"), eq("signals.blocking_failure", False)]}, "preserve": "content-version-effective-date-owner", "action_policy": "policy-navigation", "focus": "main-heading", "live": "none"},
        "superseded": {"family": "superseded-content", "trigger": {"all": [eq("signals.content_revision_state", "SUPERSEDED"), eq("signals.current_revision_href_present", True)]}, "preserve": "historical-version-and-effective-period", "action_policy": "open-current-version", "focus": "superseded-notice", "live": "polite-once"},
        "draft": {"family": "editable-draft", "trigger": {"all": [eq("signals.draft_available", True), eq("signals.save_phase", "IDLE"), eq("signals.persisted_outcome", False)]}, "preserve": "server-ack-version-and-current-input", "action_policy": "screen-draft-actions", "focus": "current-field", "live": "none"},
        "saving": {"family": "save-in-flight", "trigger": {"all": [eq("signals.save_phase", "SAVING"), eq("signals.persisted_outcome", False)]}, "preserve": "input-focus-and-idempotency-key", "action_policy": "prevent-duplicate-submit", "focus": "preserve", "live": "polite-once"},
        "saved": {"family": "server-acknowledged-draft", "trigger": {"all": [eq("signals.save_phase", "IDLE"), eq("signals.server_ack_advanced", True), eq("signals.dirty_field_count", 0)]}, "preserve": "server-ack-version-and-saved-at", "action_policy": "continue-editing", "focus": "preserve", "live": "polite-once"},
        "validation-error": {"family": "field-validation", "trigger": {"all": [gt("signals.validation_error_count", 0), eq("signals.server_mutation_count", 0)]}, "preserve": "all-entered-values", "action_policy": "correct-linked-fields", "focus": "error-summary", "live": "assertive-once"},
        "session-expiring": {"family": "session-expiry-warning", "trigger": {"all": [eq("signals.session_valid", True), eq("signals.session_expiry_band", "WARNING")]}, "preserve": "draft-server-ack-and-safe-return", "action_policy": "renew-or-submit-safely", "focus": "preserve", "live": "assertive-once"},
        "unauthorized": {"family": "authentication-required", "trigger": {"all": [eq("signals.access_decision", "UNAUTHENTICATED"), eq("signals.object_existence_disclosed", False)]}, "preserve": "safe-return-and-truthful-draft-state", "action_policy": "authenticate", "focus": "access-heading", "live": "assertive-once"},
        "unauthenticated": {"family": "authentication-required", "trigger": {"all": [eq("signals.access_decision", "UNAUTHENTICATED"), eq("signals.object_existence_disclosed", False)]}, "preserve": "safe-return-and-truthful-draft-state", "action_policy": "authenticate", "focus": "access-heading", "live": "assertive-once"},
        "forbidden": {"family": "authorization-denied", "trigger": {"all": [eq("signals.access_decision", "FORBIDDEN"), eq("signals.object_existence_disclosed", False)]}, "preserve": "request-reference-without-object-detail", "action_policy": "request-access-or-safe-return", "focus": "access-heading", "live": "assertive-once"},
        "conflict": {"family": "optimistic-conflict", "trigger": {"all": [eq("signals.concurrency_result", "CONFLICT"), eq("signals.attempted_input_preserved", True)]}, "preserve": "attempted-input-server-version-and-readable-diff", "action_policy": "reload-compare-or-reapply-explicitly", "focus": "conflict-heading", "live": "assertive-once"},
        "degraded": {"family": "degraded-capability", "trigger": {"all": [eq("signals.required_capability_state", "DEGRADED"), eq("signals.claimed_healthy", False)]}, "preserve": "affected-scope-last-good-time-and-workaround", "action_policy": "bounded-recovery", "focus": "degraded-heading", "live": "assertive-once"},
        "blocked": {"family": "decision-or-work-blocked", "trigger": {"all": [gt("signals.blocker_count", 0), eq("signals.override_allowed", False)]}, "preserve": "target-digest-draft-and-blocker-evidence", "action_policy": "resolve-owned-blocker", "focus": "blocker-heading", "live": "assertive-once"},
        "ready": {"family": "decision-ready", "trigger": {"all": [eq("signals.target_current", True), eq("signals.blocker_count", 0), eq("signals.assurance_sufficient", True), eq("signals.conflict_clear", True)]}, "preserve": "target-content-and-decision-digest", "action_policy": "exact-decision", "focus": "decision-heading", "live": "none"},
        "reauth-required": {"family": "action-bound-reauth", "trigger": {"all": [eq("signals.target_current", True), eq("signals.assurance_sufficient", False), eq("signals.action_digest_present", True)]}, "preserve": "target-digest-reason-draft-and-safe-return", "action_policy": "reauthenticate-for-exact-action", "focus": "reauth-heading", "live": "assertive-once"},
        "submitting": {"family": "decision-submit-in-flight", "trigger": {"all": [eq("signals.submit_phase", "SUBMITTING"), eq("signals.persisted_outcome", False)]}, "preserve": "decision-digest-input-and-idempotency-key", "action_policy": "disable-duplicate-submit", "focus": "preserve", "live": "polite-once"},
        "receipt": {"family": "persisted-receipt", "trigger": {"all": [eq("signals.persisted_outcome", True), eq("signals.receipt_digest_verified", True)]}, "preserve": "receipt-target-digest-actor-time-and-links", "action_policy": "receipt-next-actions", "focus": "receipt-heading", "live": "polite-once"},
        "partial-failure": {"family": "post-effect-incomplete", "trigger": {"all": [eq("signals.effect_may_exist", True), eq("signals.receipt_chain_complete", False)]}, "preserve": "all-known-receipts-and-no-retry-fence", "action_policy": "reconcile-not-retry", "focus": "reconciliation-heading", "live": "assertive-once"},
        "healthy": {"family": "verified-healthy", "trigger": {"all": [eq("signals.telemetry_complete", True), eq("signals.slo_state", "HEALTHY"), eq("signals.open_incident_count", 0)]}, "preserve": "window-build-and-evidence-receipt", "action_policy": "operations-navigation", "focus": "status-heading", "live": "none"},
        "incident": {"family": "active-incident", "trigger": {"all": [gt("signals.open_incident_count", 0), eq("signals.incident_receipt_current", True)]}, "preserve": "severity-impact-owner-next-update-and-evidence", "action_policy": "open-incident", "focus": "incident-heading", "live": "assertive-once"},
        "telemetry-gap": {"family": "telemetry-unknown", "trigger": {"all": [eq("signals.telemetry_complete", False), eq("signals.claimed_healthy", False)]}, "preserve": "last-observation-gap-scope-and-escalation", "action_policy": "investigate-telemetry-gap", "focus": "telemetry-gap-heading", "live": "assertive-once"},
        "not-found": {"family": "nonleaking-not-found", "trigger": {"all": [eq("signals.access_decision", "NOT_FOUND_OR_HIDDEN"), eq("signals.object_existence_disclosed", False)]}, "preserve": "safe-navigation-only", "action_policy": "safe-home-or-search", "focus": "system-heading", "live": "assertive-once"},
        "session-expired": {"family": "session-expired", "trigger": {"all": [eq("signals.session_valid", False), eq("signals.session_expiry_band", "EXPIRED")]}, "preserve": "truthful-server-saved-state-and-safe-return", "action_policy": "authenticate-or-request-new-access", "focus": "system-heading", "live": "assertive-once"},
        "maintenance": {"family": "planned-unavailability", "trigger": {"all": [eq("signals.maintenance_active", True), eq("signals.maintenance_window_verified", True)]}, "preserve": "scope-start-end-status-reference", "action_policy": "status-or-safe-return", "focus": "system-heading", "live": "assertive-once"},
    }


def render() -> str:
    archetypes = yaml.safe_load((ROOT / "specs/ui/page-archetypes.yaml").read_text(encoding="utf-8"))
    shared = semantics()
    templates: list[dict[str, Any]] = []
    for profile, states in archetypes["state_profiles"].items():
        for state in states:
            contract = shared[state]
            templates.append(
                {
                    "profile_state_id": f"{profile}::{state}",
                    "profile": profile,
                    "state": state,
                    **contract,
                    "copy_frame": {
                        "heading": f"{{screen_title}} — {state}",
                        "summary": "{object_label}의 현재 범위와 영향을 설명한다.",
                        "preservation": f"보존 범위: {contract['preserve']}",
                        "next_step": f"허용 행동 정책: {contract['action_policy']}",
                    },
                    "retry_safety": (
                        "NO_BLIND_RETRY"
                        if state in {"error", "server-error", "conflict", "partial-failure", "submitting", "saving"}
                        else "STATE_SPECIFIC"
                    ),
                }
            )
    document = {
        "schema_version": 1,
        "specification_version": "13.1.0-owner-addendum",
        "status": "REVIEW_REQUIRED",
        "counts": {
            "profiles": len(archetypes["state_profiles"]),
            "unique_state_semantics": len(shared),
            "profile_state_templates": len(templates),
        },
        "runtime_signal_contract": {
            "type": "ScreenRuntimeSignalsV1",
            "additional_properties": False,
            "rule": "Every signal is bound by a screen contract to an operation result, persisted receipt, trusted session fact, or browser connectivity fact; a renderer cannot invent it.",
        },
        "selection_rules": [
            "A screen's explicit state_profile is authoritative.",
            "Background refresh and orthogonal overlays cannot replace the primary task state without declared precedence.",
            "A state is selected only when its typed trigger is true; trigger ties without coexistence or precedence fail closed.",
            "Saved and receipt require server or database acknowledgement; timer, toast and HTTP status alone are insufficient.",
        ],
        "templates": templates,
    }
    return yaml.safe_dump(document, sort_keys=False, allow_unicode=True, width=120)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    rendered = render()
    if args.check:
        if not TARGET.is_file() or TARGET.read_text(encoding="utf-8") != rendered:
            raise SystemExit("state profile contracts are stale")
        print("state profile contracts: PASS")
    else:
        TARGET.write_text(rendered, encoding="utf-8")


if __name__ == "__main__":
    main()
