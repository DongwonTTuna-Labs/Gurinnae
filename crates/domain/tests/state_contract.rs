use gurine_domain::{
    case::{
        CaseAxes, PublicationHistory, TransitionDenial, authorize_transition, validate_case_axes,
    },
    state_catalog::{InvestigationState, PublicationState, ResolutionCode},
};

#[test]
fn every_declared_transition_has_an_executable_positive_case() {
    assert!(
        authorize_transition(
            InvestigationState::SignalDetected,
            InvestigationState::Triage,
            "signals.triage",
            |_| true,
        )
        .is_ok(),
        "allow-detect-signal-signal_detected"
    );
    assert!(
        authorize_transition(
            InvestigationState::Triage,
            InvestigationState::Investigating,
            "cases.investigate",
            |_| true,
        )
        .is_ok(),
        "allow-begin-investigation-triage"
    );
    assert!(
        authorize_transition(
            InvestigationState::Investigating,
            InvestigationState::AwaitingResponse,
            "responses.request",
            |_| true,
        )
        .is_ok(),
        "allow-request-response-investigating"
    );
    assert!(
        authorize_transition(
            InvestigationState::AwaitingResponse,
            InvestigationState::Investigating,
            "cases.investigate",
            |_| true,
        )
        .is_ok(),
        "allow-resume-investigation-awaiting_response"
    );
    assert!(
        authorize_transition(
            InvestigationState::Investigating,
            InvestigationState::EditorialReview,
            "review.editorial",
            |_| true,
        )
        .is_ok(),
        "allow-submit-editorial-review-investigating"
    );
    assert!(
        authorize_transition(
            InvestigationState::AwaitingResponse,
            InvestigationState::EditorialReview,
            "review.editorial",
            |_| true,
        )
        .is_ok(),
        "allow-submit-editorial-review-awaiting_response"
    );
    assert!(
        authorize_transition(
            InvestigationState::EditorialReview,
            InvestigationState::LegalReview,
            "review.legal",
            |_| true,
        )
        .is_ok(),
        "allow-submit-legal-review-editorial_review"
    );
    assert!(
        authorize_transition(
            InvestigationState::EditorialReview,
            InvestigationState::ReadyToPublish,
            "review.editorial",
            |_| true,
        )
        .is_ok(),
        "allow-ready-from-editorial-editorial_review"
    );
    assert!(
        authorize_transition(
            InvestigationState::LegalReview,
            InvestigationState::ReadyToPublish,
            "review.legal",
            |_| true,
        )
        .is_ok(),
        "allow-ready-from-legal-legal_review"
    );
    assert!(
        authorize_transition(
            InvestigationState::EditorialReview,
            InvestigationState::Investigating,
            "cases.investigate",
            |_| true,
        )
        .is_ok(),
        "allow-return-to-investigation-editorial_review"
    );
    assert!(
        authorize_transition(
            InvestigationState::LegalReview,
            InvestigationState::Investigating,
            "cases.investigate",
            |_| true,
        )
        .is_ok(),
        "allow-return-to-investigation-legal_review"
    );
    assert!(
        authorize_transition(
            InvestigationState::ReadyToPublish,
            InvestigationState::Investigating,
            "cases.investigate",
            |_| true,
        )
        .is_ok(),
        "allow-return-to-investigation-ready_to_publish"
    );
    assert!(
        authorize_transition(
            InvestigationState::Triage,
            InvestigationState::Closed,
            "cases.investigate",
            |_| true,
        )
        .is_ok(),
        "allow-close-case-triage"
    );
    assert!(
        authorize_transition(
            InvestigationState::Investigating,
            InvestigationState::Closed,
            "cases.investigate",
            |_| true,
        )
        .is_ok(),
        "allow-close-case-investigating"
    );
    assert!(
        authorize_transition(
            InvestigationState::AwaitingResponse,
            InvestigationState::Closed,
            "cases.investigate",
            |_| true,
        )
        .is_ok(),
        "allow-close-case-awaiting_response"
    );
    assert!(
        authorize_transition(
            InvestigationState::EditorialReview,
            InvestigationState::Closed,
            "cases.investigate",
            |_| true,
        )
        .is_ok(),
        "allow-close-case-editorial_review"
    );
    assert!(
        authorize_transition(
            InvestigationState::LegalReview,
            InvestigationState::Closed,
            "cases.investigate",
            |_| true,
        )
        .is_ok(),
        "allow-close-case-legal_review"
    );
    assert!(
        authorize_transition(
            InvestigationState::ReadyToPublish,
            InvestigationState::Closed,
            "cases.investigate",
            |_| true,
        )
        .is_ok(),
        "allow-close-case-ready_to_publish"
    );
    assert!(
        authorize_transition(
            InvestigationState::Closed,
            InvestigationState::Investigating,
            "cases.investigate",
            |_| true,
        )
        .is_ok(),
        "allow-reopen-case-closed"
    );
}

#[test]
fn capability_and_guard_denials_match_the_catalog() {
    let guards = [("at_least_one_signal", true)];
    let result = authorize_transition(
        InvestigationState::SignalDetected,
        InvestigationState::Triage,
        "public.read",
        |guard| {
            guards
                .iter()
                .find(|entry| entry.0 == guard)
                .is_some_and(|entry| entry.1)
        },
    );
    assert!(
        matches!(result, Err(TransitionDenial::CapabilityDenied)),
        "deny-detect-signal-capability"
    );
    let guards = [("at_least_one_signal", false)];
    let result = authorize_transition(
        InvestigationState::SignalDetected,
        InvestigationState::Triage,
        "signals.triage",
        |guard| {
            guards
                .iter()
                .find(|entry| entry.0 == guard)
                .is_some_and(|entry| entry.1)
        },
    );
    assert!(
        matches!(result, Err(TransitionDenial::GuardDenied(_))),
        "deny-detect-signal-guard"
    );
    let guards = [
        ("triage_decision_investigate", true),
        ("assigned_investigator", true),
    ];
    let result = authorize_transition(
        InvestigationState::Triage,
        InvestigationState::Investigating,
        "public.read",
        |guard| {
            guards
                .iter()
                .find(|entry| entry.0 == guard)
                .is_some_and(|entry| entry.1)
        },
    );
    assert!(
        matches!(result, Err(TransitionDenial::CapabilityDenied)),
        "deny-begin-investigation-capability"
    );
    let guards = [
        ("triage_decision_investigate", false),
        ("assigned_investigator", true),
    ];
    let result = authorize_transition(
        InvestigationState::Triage,
        InvestigationState::Investigating,
        "cases.investigate",
        |guard| {
            guards
                .iter()
                .find(|entry| entry.0 == guard)
                .is_some_and(|entry| entry.1)
        },
    );
    assert!(
        matches!(result, Err(TransitionDenial::GuardDenied(_))),
        "deny-begin-investigation-guard"
    );
    let guards = [
        ("validated_response_request", true),
        ("due_at_in_future", true),
    ];
    let result = authorize_transition(
        InvestigationState::Investigating,
        InvestigationState::AwaitingResponse,
        "public.read",
        |guard| {
            guards
                .iter()
                .find(|entry| entry.0 == guard)
                .is_some_and(|entry| entry.1)
        },
    );
    assert!(
        matches!(result, Err(TransitionDenial::CapabilityDenied)),
        "deny-request-response-capability"
    );
    let guards = [
        ("validated_response_request", false),
        ("due_at_in_future", true),
    ];
    let result = authorize_transition(
        InvestigationState::Investigating,
        InvestigationState::AwaitingResponse,
        "responses.request",
        |guard| {
            guards
                .iter()
                .find(|entry| entry.0 == guard)
                .is_some_and(|entry| entry.1)
        },
    );
    assert!(
        matches!(result, Err(TransitionDenial::GuardDenied(_))),
        "deny-request-response-guard"
    );
    let guards = [("response_received_or_deadline_handled", true)];
    let result = authorize_transition(
        InvestigationState::AwaitingResponse,
        InvestigationState::Investigating,
        "public.read",
        |guard| {
            guards
                .iter()
                .find(|entry| entry.0 == guard)
                .is_some_and(|entry| entry.1)
        },
    );
    assert!(
        matches!(result, Err(TransitionDenial::CapabilityDenied)),
        "deny-resume-investigation-capability"
    );
    let guards = [("response_received_or_deadline_handled", false)];
    let result = authorize_transition(
        InvestigationState::AwaitingResponse,
        InvestigationState::Investigating,
        "cases.investigate",
        |guard| {
            guards
                .iter()
                .find(|entry| entry.0 == guard)
                .is_some_and(|entry| entry.1)
        },
    );
    assert!(
        matches!(result, Err(TransitionDenial::GuardDenied(_))),
        "deny-resume-investigation-guard"
    );
    let guards = [
        ("claims_valid", true),
        ("evidence_verified", true),
        ("response_policy_satisfied", true),
    ];
    let result = authorize_transition(
        InvestigationState::Investigating,
        InvestigationState::EditorialReview,
        "public.read",
        |guard| {
            guards
                .iter()
                .find(|entry| entry.0 == guard)
                .is_some_and(|entry| entry.1)
        },
    );
    assert!(
        matches!(result, Err(TransitionDenial::CapabilityDenied)),
        "deny-submit-editorial-review-capability"
    );
    let guards = [
        ("claims_valid", false),
        ("evidence_verified", true),
        ("response_policy_satisfied", true),
    ];
    let result = authorize_transition(
        InvestigationState::Investigating,
        InvestigationState::EditorialReview,
        "review.editorial",
        |guard| {
            guards
                .iter()
                .find(|entry| entry.0 == guard)
                .is_some_and(|entry| entry.1)
        },
    );
    assert!(
        matches!(result, Err(TransitionDenial::GuardDenied(_))),
        "deny-submit-editorial-review-guard"
    );
    let guards = [("legal_review_required", true)];
    let result = authorize_transition(
        InvestigationState::EditorialReview,
        InvestigationState::LegalReview,
        "public.read",
        |guard| {
            guards
                .iter()
                .find(|entry| entry.0 == guard)
                .is_some_and(|entry| entry.1)
        },
    );
    assert!(
        matches!(result, Err(TransitionDenial::CapabilityDenied)),
        "deny-submit-legal-review-capability"
    );
    let guards = [("legal_review_required", false)];
    let result = authorize_transition(
        InvestigationState::EditorialReview,
        InvestigationState::LegalReview,
        "review.legal",
        |guard| {
            guards
                .iter()
                .find(|entry| entry.0 == guard)
                .is_some_and(|entry| entry.1)
        },
    );
    assert!(
        matches!(result, Err(TransitionDenial::GuardDenied(_))),
        "deny-submit-legal-review-guard"
    );
    let guards = [
        ("editorial_approved", true),
        ("legal_review_not_required", true),
        ("snapshot_current", true),
    ];
    let result = authorize_transition(
        InvestigationState::EditorialReview,
        InvestigationState::ReadyToPublish,
        "public.read",
        |guard| {
            guards
                .iter()
                .find(|entry| entry.0 == guard)
                .is_some_and(|entry| entry.1)
        },
    );
    assert!(
        matches!(result, Err(TransitionDenial::CapabilityDenied)),
        "deny-ready-from-editorial-capability"
    );
    let guards = [
        ("editorial_approved", false),
        ("legal_review_not_required", true),
        ("snapshot_current", true),
    ];
    let result = authorize_transition(
        InvestigationState::EditorialReview,
        InvestigationState::ReadyToPublish,
        "review.editorial",
        |guard| {
            guards
                .iter()
                .find(|entry| entry.0 == guard)
                .is_some_and(|entry| entry.1)
        },
    );
    assert!(
        matches!(result, Err(TransitionDenial::GuardDenied(_))),
        "deny-ready-from-editorial-guard"
    );
    let guards = [("legal_approved", true), ("snapshot_current", true)];
    let result = authorize_transition(
        InvestigationState::LegalReview,
        InvestigationState::ReadyToPublish,
        "public.read",
        |guard| {
            guards
                .iter()
                .find(|entry| entry.0 == guard)
                .is_some_and(|entry| entry.1)
        },
    );
    assert!(
        matches!(result, Err(TransitionDenial::CapabilityDenied)),
        "deny-ready-from-legal-capability"
    );
    let guards = [("legal_approved", false), ("snapshot_current", true)];
    let result = authorize_transition(
        InvestigationState::LegalReview,
        InvestigationState::ReadyToPublish,
        "review.legal",
        |guard| {
            guards
                .iter()
                .find(|entry| entry.0 == guard)
                .is_some_and(|entry| entry.1)
        },
    );
    assert!(
        matches!(result, Err(TransitionDenial::GuardDenied(_))),
        "deny-ready-from-legal-guard"
    );
    let guards = [("changes_required_reason", true)];
    let result = authorize_transition(
        InvestigationState::EditorialReview,
        InvestigationState::Investigating,
        "public.read",
        |guard| {
            guards
                .iter()
                .find(|entry| entry.0 == guard)
                .is_some_and(|entry| entry.1)
        },
    );
    assert!(
        matches!(result, Err(TransitionDenial::CapabilityDenied)),
        "deny-return-to-investigation-capability"
    );
    let guards = [("changes_required_reason", false)];
    let result = authorize_transition(
        InvestigationState::EditorialReview,
        InvestigationState::Investigating,
        "cases.investigate",
        |guard| {
            guards
                .iter()
                .find(|entry| entry.0 == guard)
                .is_some_and(|entry| entry.1)
        },
    );
    assert!(
        matches!(result, Err(TransitionDenial::GuardDenied(_))),
        "deny-return-to-investigation-guard"
    );
    let guards = [
        ("resolution_code_not_none", true),
        ("structured_reason", true),
    ];
    let result = authorize_transition(
        InvestigationState::Triage,
        InvestigationState::Closed,
        "public.read",
        |guard| {
            guards
                .iter()
                .find(|entry| entry.0 == guard)
                .is_some_and(|entry| entry.1)
        },
    );
    assert!(
        matches!(result, Err(TransitionDenial::CapabilityDenied)),
        "deny-close-case-capability"
    );
    let guards = [
        ("resolution_code_not_none", false),
        ("structured_reason", true),
    ];
    let result = authorize_transition(
        InvestigationState::Triage,
        InvestigationState::Closed,
        "cases.investigate",
        |guard| {
            guards
                .iter()
                .find(|entry| entry.0 == guard)
                .is_some_and(|entry| entry.1)
        },
    );
    assert!(
        matches!(result, Err(TransitionDenial::GuardDenied(_))),
        "deny-close-case-guard"
    );
    let guards = [
        ("new_material_evidence", true),
        ("structured_reason", true),
        ("reauth_if_previously_published", true),
    ];
    let result = authorize_transition(
        InvestigationState::Closed,
        InvestigationState::Investigating,
        "public.read",
        |guard| {
            guards
                .iter()
                .find(|entry| entry.0 == guard)
                .is_some_and(|entry| entry.1)
        },
    );
    assert!(
        matches!(result, Err(TransitionDenial::CapabilityDenied)),
        "deny-reopen-case-capability"
    );
    let guards = [
        ("new_material_evidence", false),
        ("structured_reason", true),
        ("reauth_if_previously_published", true),
    ];
    let result = authorize_transition(
        InvestigationState::Closed,
        InvestigationState::Investigating,
        "cases.investigate",
        |guard| {
            guards
                .iter()
                .find(|entry| entry.0 == guard)
                .is_some_and(|entry| entry.1)
        },
    );
    assert!(
        matches!(result, Err(TransitionDenial::GuardDenied(_))),
        "deny-reopen-case-guard"
    );
}

#[test]
fn cross_axis_examples_match_the_catalog() {
    assert!(
        validate_case_axes(
            CaseAxes {
                investigation: InvestigationState::Investigating,
                publication: PublicationState::PublishedAnomaly,
                resolution: ResolutionCode::None,
            },
            PublicationHistory::default(),
        )
        .is_err(),
        "deny-published-before-ready"
    );
    assert!(
        validate_case_axes(
            CaseAxes {
                investigation: InvestigationState::ReadyToPublish,
                publication: PublicationState::NeverPublished,
                resolution: ResolutionCode::None,
            },
            PublicationHistory::default(),
        )
        .is_ok(),
        "allow-ready-unpublished"
    );
    assert!(
        validate_case_axes(
            CaseAxes {
                investigation: InvestigationState::Closed,
                publication: PublicationState::PublishedExplained,
                resolution: ResolutionCode::Explained,
            },
            PublicationHistory::default(),
        )
        .is_ok(),
        "allow-closed-explained"
    );
    assert!(
        validate_case_axes(
            CaseAxes {
                investigation: InvestigationState::Closed,
                publication: PublicationState::PublishedExplained,
                resolution: ResolutionCode::None,
            },
            PublicationHistory::default(),
        )
        .is_err(),
        "deny-explained-without-resolution"
    );
    assert!(
        validate_case_axes(
            CaseAxes {
                investigation: InvestigationState::Closed,
                publication: PublicationState::NeverPublished,
                resolution: ResolutionCode::None,
            },
            PublicationHistory::default(),
        )
        .is_err(),
        "deny-closed-with-none"
    );
    assert!(
        validate_case_axes(
            CaseAxes {
                investigation: InvestigationState::Closed,
                publication: PublicationState::NeverPublished,
                resolution: ResolutionCode::Archived,
            },
            PublicationHistory::default(),
        )
        .is_ok(),
        "allow-closed-archived"
    );
}
