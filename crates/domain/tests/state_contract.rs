use gurine_domain::{
    case::{
        CaseAxes, PublicationHistory, TransitionDenial, authorize_transition, validate_case_axes,
    },
    state_catalog::{InvestigationState, PublicationState, ResolutionCode},
};

fn allowed(from: InvestigationState, to: InvestigationState, capability: &str, label: &str) {
    assert!(
        authorize_transition(from, to, capability, |_| true).is_ok(),
        "{label}"
    );
}

fn denied_capability(
    from: InvestigationState,
    to: InvestigationState,
    guards: &[(&str, bool)],
    label: &str,
) {
    let result = authorize_transition(from, to, "public.read", |guard| {
        guards
            .iter()
            .find(|entry| entry.0 == guard)
            .is_some_and(|entry| entry.1)
    });
    assert!(
        matches!(result, Err(TransitionDenial::CapabilityDenied)),
        "{label}"
    );
}

fn denied_guard(
    from: InvestigationState,
    to: InvestigationState,
    capability: &str,
    guards: &[(&str, bool)],
    label: &str,
) {
    let result = authorize_transition(from, to, capability, |guard| {
        guards
            .iter()
            .find(|entry| entry.0 == guard)
            .is_some_and(|entry| entry.1)
    });
    assert!(
        matches!(result, Err(TransitionDenial::GuardDenied(_))),
        "{label}"
    );
}

#[rustfmt::skip]
const ALLOWED: &[(InvestigationState, InvestigationState, &str, &str)] = &[
    (InvestigationState::SignalDetected, InvestigationState::Triage, "signals.triage", "allow-detect-signal-signal_detected"),
    (InvestigationState::Triage, InvestigationState::Investigating, "cases.investigate", "allow-begin-investigation-triage"),
    (InvestigationState::Investigating, InvestigationState::AwaitingResponse, "responses.request", "allow-request-response-investigating"),
    (InvestigationState::AwaitingResponse, InvestigationState::Investigating, "cases.investigate", "allow-resume-investigation-awaiting_response"),
    (InvestigationState::Investigating, InvestigationState::EditorialReview, "review.editorial", "allow-submit-editorial-review-investigating"),
    (InvestigationState::AwaitingResponse, InvestigationState::EditorialReview, "review.editorial", "allow-submit-editorial-review-awaiting_response"),
    (InvestigationState::EditorialReview, InvestigationState::LegalReview, "review.legal", "allow-submit-legal-review-editorial_review"),
    (InvestigationState::EditorialReview, InvestigationState::ReadyToPublish, "review.editorial", "allow-ready-from-editorial-editorial_review"),
    (InvestigationState::LegalReview, InvestigationState::ReadyToPublish, "review.legal", "allow-ready-from-legal-legal_review"),
    (InvestigationState::EditorialReview, InvestigationState::Investigating, "cases.investigate", "allow-return-to-investigation-editorial_review"),
    (InvestigationState::LegalReview, InvestigationState::Investigating, "cases.investigate", "allow-return-to-investigation-legal_review"),
    (InvestigationState::ReadyToPublish, InvestigationState::Investigating, "cases.investigate", "allow-return-to-investigation-ready_to_publish"),
    (InvestigationState::Triage, InvestigationState::Closed, "cases.investigate", "allow-close-case-triage"),
    (InvestigationState::Investigating, InvestigationState::Closed, "cases.investigate", "allow-close-case-investigating"),
    (InvestigationState::AwaitingResponse, InvestigationState::Closed, "cases.investigate", "allow-close-case-awaiting_response"),
    (InvestigationState::EditorialReview, InvestigationState::Closed, "cases.investigate", "allow-close-case-editorial_review"),
    (InvestigationState::LegalReview, InvestigationState::Closed, "cases.investigate", "allow-close-case-legal_review"),
    (InvestigationState::ReadyToPublish, InvestigationState::Closed, "cases.investigate", "allow-close-case-ready_to_publish"),
    (InvestigationState::Closed, InvestigationState::Investigating, "cases.investigate", "allow-reopen-case-closed"),
];

struct DenialCase {
    from: InvestigationState,
    to: InvestigationState,
    capability: &'static str,
    guards: &'static [(&'static str, bool)],
    guard_denied: bool,
    label: &'static str,
}
const G_SIGNAL: &[(&str, bool)] = &[("at_least_one_signal", true)];
const G_SIGNAL_FALSE: &[(&str, bool)] = &[("at_least_one_signal", false)];
const G_TRIAGE: &[(&str, bool)] = &[
    ("triage_decision_investigate", true),
    ("assigned_investigator", true),
];
const G_TRIAGE_FALSE: &[(&str, bool)] = &[
    ("triage_decision_investigate", false),
    ("assigned_investigator", true),
];
const G_RESPONSE: &[(&str, bool)] = &[
    ("validated_response_request", true),
    ("due_at_in_future", true),
];
const G_RESPONSE_FALSE: &[(&str, bool)] = &[
    ("validated_response_request", false),
    ("due_at_in_future", true),
];
const G_RECEIVED: &[(&str, bool)] = &[("response_received_or_deadline_handled", true)];
const G_RECEIVED_FALSE: &[(&str, bool)] = &[("response_received_or_deadline_handled", false)];
const G_EDITORIAL: &[(&str, bool)] = &[
    ("claims_valid", true),
    ("evidence_verified", true),
    ("response_policy_satisfied", true),
];
const G_EDITORIAL_FALSE: &[(&str, bool)] = &[
    ("claims_valid", false),
    ("evidence_verified", true),
    ("response_policy_satisfied", true),
];
const G_LEGAL_REQUIRED: &[(&str, bool)] = &[("legal_review_required", true)];
const G_LEGAL_REQUIRED_FALSE: &[(&str, bool)] = &[("legal_review_required", false)];
const G_READY_EDITORIAL: &[(&str, bool)] = &[
    ("editorial_approved", true),
    ("legal_review_not_required", true),
    ("snapshot_current", true),
];
const G_READY_EDITORIAL_FALSE: &[(&str, bool)] = &[
    ("editorial_approved", false),
    ("legal_review_not_required", true),
    ("snapshot_current", true),
];
const G_READY_LEGAL: &[(&str, bool)] = &[("legal_approved", true), ("snapshot_current", true)];
const G_READY_LEGAL_FALSE: &[(&str, bool)] =
    &[("legal_approved", false), ("snapshot_current", true)];
const G_CHANGES: &[(&str, bool)] = &[("changes_required_reason", true)];
const G_CHANGES_FALSE: &[(&str, bool)] = &[("changes_required_reason", false)];
const G_CLOSE: &[(&str, bool)] = &[
    ("resolution_code_not_none", true),
    ("structured_reason", true),
];
const G_CLOSE_FALSE: &[(&str, bool)] = &[
    ("resolution_code_not_none", false),
    ("structured_reason", true),
];
const G_REOPEN: &[(&str, bool)] = &[
    ("new_material_evidence", true),
    ("structured_reason", true),
    ("reauth_if_previously_published", true),
];
const G_REOPEN_FALSE: &[(&str, bool)] = &[
    ("new_material_evidence", false),
    ("structured_reason", true),
    ("reauth_if_previously_published", true),
];

#[rustfmt::skip]
const DENIALS: &[DenialCase] = &[
    DenialCase { from: InvestigationState::SignalDetected, to: InvestigationState::Triage, capability: "signals.triage", guards: G_SIGNAL, guard_denied: false, label: "deny-detect-signal-capability" },
    DenialCase { from: InvestigationState::SignalDetected, to: InvestigationState::Triage, capability: "signals.triage", guards: G_SIGNAL_FALSE, guard_denied: true, label: "deny-detect-signal-guard" },
    DenialCase { from: InvestigationState::Triage, to: InvestigationState::Investigating, capability: "cases.investigate", guards: G_TRIAGE, guard_denied: false, label: "deny-begin-investigation-capability" },
    DenialCase { from: InvestigationState::Triage, to: InvestigationState::Investigating, capability: "cases.investigate", guards: G_TRIAGE_FALSE, guard_denied: true, label: "deny-begin-investigation-guard" },
    DenialCase { from: InvestigationState::Investigating, to: InvestigationState::AwaitingResponse, capability: "responses.request", guards: G_RESPONSE, guard_denied: false, label: "deny-request-response-capability" },
    DenialCase { from: InvestigationState::Investigating, to: InvestigationState::AwaitingResponse, capability: "responses.request", guards: G_RESPONSE_FALSE, guard_denied: true, label: "deny-request-response-guard" },
    DenialCase { from: InvestigationState::AwaitingResponse, to: InvestigationState::Investigating, capability: "cases.investigate", guards: G_RECEIVED, guard_denied: false, label: "deny-resume-investigation-capability" },
    DenialCase { from: InvestigationState::AwaitingResponse, to: InvestigationState::Investigating, capability: "cases.investigate", guards: G_RECEIVED_FALSE, guard_denied: true, label: "deny-resume-investigation-guard" },
    DenialCase { from: InvestigationState::Investigating, to: InvestigationState::EditorialReview, capability: "review.editorial", guards: G_EDITORIAL, guard_denied: false, label: "deny-submit-editorial-review-capability" },
    DenialCase { from: InvestigationState::Investigating, to: InvestigationState::EditorialReview, capability: "review.editorial", guards: G_EDITORIAL_FALSE, guard_denied: true, label: "deny-submit-editorial-review-guard" },
    DenialCase { from: InvestigationState::EditorialReview, to: InvestigationState::LegalReview, capability: "review.legal", guards: G_LEGAL_REQUIRED, guard_denied: false, label: "deny-submit-legal-review-capability" },
    DenialCase { from: InvestigationState::EditorialReview, to: InvestigationState::LegalReview, capability: "review.legal", guards: G_LEGAL_REQUIRED_FALSE, guard_denied: true, label: "deny-submit-legal-review-guard" },
    DenialCase { from: InvestigationState::EditorialReview, to: InvestigationState::ReadyToPublish, capability: "review.editorial", guards: G_READY_EDITORIAL, guard_denied: false, label: "deny-ready-from-editorial-capability" },
    DenialCase { from: InvestigationState::EditorialReview, to: InvestigationState::ReadyToPublish, capability: "review.editorial", guards: G_READY_EDITORIAL_FALSE, guard_denied: true, label: "deny-ready-from-editorial-guard" },
    DenialCase { from: InvestigationState::LegalReview, to: InvestigationState::ReadyToPublish, capability: "review.legal", guards: G_READY_LEGAL, guard_denied: false, label: "deny-ready-from-legal-capability" },
    DenialCase { from: InvestigationState::LegalReview, to: InvestigationState::ReadyToPublish, capability: "review.legal", guards: G_READY_LEGAL_FALSE, guard_denied: true, label: "deny-ready-from-legal-guard" },
    DenialCase { from: InvestigationState::EditorialReview, to: InvestigationState::Investigating, capability: "cases.investigate", guards: G_CHANGES, guard_denied: false, label: "deny-return-to-investigation-capability" },
    DenialCase { from: InvestigationState::EditorialReview, to: InvestigationState::Investigating, capability: "cases.investigate", guards: G_CHANGES_FALSE, guard_denied: true, label: "deny-return-to-investigation-guard" },
    DenialCase { from: InvestigationState::Triage, to: InvestigationState::Closed, capability: "cases.investigate", guards: G_CLOSE, guard_denied: false, label: "deny-close-case-capability" },
    DenialCase { from: InvestigationState::Triage, to: InvestigationState::Closed, capability: "cases.investigate", guards: G_CLOSE_FALSE, guard_denied: true, label: "deny-close-case-guard" },
    DenialCase { from: InvestigationState::Closed, to: InvestigationState::Investigating, capability: "cases.investigate", guards: G_REOPEN, guard_denied: false, label: "deny-reopen-case-capability" },
    DenialCase { from: InvestigationState::Closed, to: InvestigationState::Investigating, capability: "cases.investigate", guards: G_REOPEN_FALSE, guard_denied: true, label: "deny-reopen-case-guard" },
];

#[test]
fn every_declared_transition_has_an_executable_positive_case() {
    for &(from, to, capability, label) in ALLOWED {
        allowed(from, to, capability, label);
    }
}

#[test]
fn capability_and_guard_denials_match_the_catalog() {
    for case in DENIALS {
        if case.guard_denied {
            denied_guard(case.from, case.to, case.capability, case.guards, case.label);
        } else {
            denied_capability(case.from, case.to, case.guards, case.label);
        }
    }
}

#[test]
fn cross_axis_examples_match_the_catalog() {
    let examples = [
        (
            InvestigationState::Investigating,
            PublicationState::PublishedAnomaly,
            ResolutionCode::None,
            false,
            "deny-published-before-ready",
        ),
        (
            InvestigationState::ReadyToPublish,
            PublicationState::NeverPublished,
            ResolutionCode::None,
            true,
            "allow-ready-unpublished",
        ),
        (
            InvestigationState::Closed,
            PublicationState::PublishedExplained,
            ResolutionCode::Explained,
            true,
            "allow-closed-explained",
        ),
        (
            InvestigationState::Closed,
            PublicationState::PublishedExplained,
            ResolutionCode::None,
            false,
            "deny-explained-without-resolution",
        ),
        (
            InvestigationState::Closed,
            PublicationState::NeverPublished,
            ResolutionCode::None,
            false,
            "deny-closed-with-none",
        ),
        (
            InvestigationState::Closed,
            PublicationState::NeverPublished,
            ResolutionCode::Archived,
            true,
            "allow-closed-archived",
        ),
    ];
    for (investigation, publication, resolution, valid, label) in examples {
        let result = validate_case_axes(
            CaseAxes {
                investigation,
                publication,
                resolution,
            },
            PublicationHistory::default(),
        );
        assert_eq!(result.is_ok(), valid, "{label}");
    }
}
