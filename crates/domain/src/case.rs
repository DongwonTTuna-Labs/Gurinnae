use crate::state_catalog::{InvestigationState, PublicationState, ResolutionCode};

#[derive(Clone, Copy, Debug)]
pub struct CaseTransition {
    pub id: &'static str,
    pub from: &'static [InvestigationState],
    pub to: InvestigationState,
    pub capability: &'static str,
    pub guards: &'static [&'static str],
    pub audit_action: &'static str,
    pub domain_events: &'static [&'static str],
}

pub const CASE_TRANSITIONS: &[CaseTransition] = &[
    CaseTransition {
        id: "detect-signal",
        from: &[InvestigationState::SignalDetected],
        to: InvestigationState::Triage,
        capability: "signals.triage",
        guards: &["at_least_one_signal"],
        audit_action: "case.triage.started",
        domain_events: &["case.state_transitioned.v1"],
    },
    CaseTransition {
        id: "begin-investigation",
        from: &[InvestigationState::Triage],
        to: InvestigationState::Investigating,
        capability: "cases.investigate",
        guards: &["triage_decision_investigate", "assigned_investigator"],
        audit_action: "case.investigation.started",
        domain_events: &["case.state_transitioned.v1"],
    },
    CaseTransition {
        id: "request-response",
        from: &[InvestigationState::Investigating],
        to: InvestigationState::AwaitingResponse,
        capability: "responses.request",
        guards: &["validated_response_request", "due_at_in_future"],
        audit_action: "case.response.awaited",
        domain_events: &["case.state_transitioned.v1"],
    },
    CaseTransition {
        id: "resume-investigation",
        from: &[InvestigationState::AwaitingResponse],
        to: InvestigationState::Investigating,
        capability: "cases.investigate",
        guards: &["response_received_or_deadline_handled"],
        audit_action: "case.investigation.resumed",
        domain_events: &["case.state_transitioned.v1"],
    },
    CaseTransition {
        id: "submit-editorial-review",
        from: &[
            InvestigationState::Investigating,
            InvestigationState::AwaitingResponse,
        ],
        to: InvestigationState::EditorialReview,
        capability: "review.editorial",
        guards: &[
            "claims_valid",
            "evidence_verified",
            "response_policy_satisfied",
        ],
        audit_action: "case.editorial_review.started",
        domain_events: &["case.state_transitioned.v1"],
    },
    CaseTransition {
        id: "submit-legal-review",
        from: &[InvestigationState::EditorialReview],
        to: InvestigationState::LegalReview,
        capability: "review.legal",
        guards: &["legal_review_required"],
        audit_action: "case.legal_review.started",
        domain_events: &["case.state_transitioned.v1"],
    },
    CaseTransition {
        id: "ready-from-editorial",
        from: &[InvestigationState::EditorialReview],
        to: InvestigationState::ReadyToPublish,
        capability: "review.editorial",
        guards: &[
            "editorial_approved",
            "legal_review_not_required",
            "snapshot_current",
        ],
        audit_action: "case.ready_to_publish",
        domain_events: &["case.state_transitioned.v1"],
    },
    CaseTransition {
        id: "ready-from-legal",
        from: &[InvestigationState::LegalReview],
        to: InvestigationState::ReadyToPublish,
        capability: "review.legal",
        guards: &["legal_approved", "snapshot_current"],
        audit_action: "case.ready_to_publish",
        domain_events: &["case.state_transitioned.v1"],
    },
    CaseTransition {
        id: "return-to-investigation",
        from: &[
            InvestigationState::EditorialReview,
            InvestigationState::LegalReview,
            InvestigationState::ReadyToPublish,
        ],
        to: InvestigationState::Investigating,
        capability: "cases.investigate",
        guards: &["changes_required_reason"],
        audit_action: "case.investigation.reopened",
        domain_events: &["case.state_transitioned.v1"],
    },
    CaseTransition {
        id: "close-case",
        from: &[
            InvestigationState::Triage,
            InvestigationState::Investigating,
            InvestigationState::AwaitingResponse,
            InvestigationState::EditorialReview,
            InvestigationState::LegalReview,
            InvestigationState::ReadyToPublish,
        ],
        to: InvestigationState::Closed,
        capability: "cases.investigate",
        guards: &["resolution_code_not_none", "structured_reason"],
        audit_action: "case.closed",
        domain_events: &["case.state_transitioned.v1"],
    },
    CaseTransition {
        id: "reopen-case",
        from: &[InvestigationState::Closed],
        to: InvestigationState::Investigating,
        capability: "cases.investigate",
        guards: &[
            "new_material_evidence",
            "structured_reason",
            "reauth_if_previously_published",
        ],
        audit_action: "case.reopened",
        domain_events: &["case.state_transitioned.v1"],
    },
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TransitionDenial {
    UndeclaredTransition,
    CapabilityDenied,
    GuardDenied(&'static str),
}

pub fn authorize_transition(
    from: InvestigationState,
    to: InvestigationState,
    capability: &str,
    guard_satisfied: impl Fn(&str) -> bool,
) -> Result<&'static CaseTransition, TransitionDenial> {
    let transition = CASE_TRANSITIONS
        .iter()
        .find(|transition| transition.from.contains(&from) && transition.to == to)
        .ok_or(TransitionDenial::UndeclaredTransition)?;
    if transition.capability != capability {
        return Err(TransitionDenial::CapabilityDenied);
    }
    if let Some(guard) = transition
        .guards
        .iter()
        .find(|guard| !guard_satisfied(guard))
    {
        return Err(TransitionDenial::GuardDenied(guard));
    }
    Ok(transition)
}

#[derive(Clone, Copy, Debug)]
pub struct CaseAxes {
    pub investigation: InvestigationState,
    pub publication: PublicationState,
    pub resolution: ResolutionCode,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct PublicationHistory {
    pub prior_immutable_revision: bool,
    pub visible_tombstone: bool,
    pub structured_reason: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AxisViolation {
    PublicationBeforeReady,
    ExplainedWithoutResolution,
    CorrectedWithoutHistory,
    RetractedWithoutTombstone,
    ClosedWithoutResolution,
}

pub fn validate_case_axes(
    axes: CaseAxes,
    history: PublicationHistory,
) -> Result<(), AxisViolation> {
    if axes.publication != PublicationState::NeverPublished
        && !matches!(
            axes.investigation,
            InvestigationState::ReadyToPublish | InvestigationState::Closed
        )
    {
        return Err(AxisViolation::PublicationBeforeReady);
    }
    if axes.publication == PublicationState::PublishedExplained
        && axes.resolution != ResolutionCode::Explained
    {
        return Err(AxisViolation::ExplainedWithoutResolution);
    }
    if axes.publication == PublicationState::Corrected && !history.prior_immutable_revision {
        return Err(AxisViolation::CorrectedWithoutHistory);
    }
    if axes.publication == PublicationState::Retracted
        && !(history.visible_tombstone && history.structured_reason)
    {
        return Err(AxisViolation::RetractedWithoutTombstone);
    }
    if axes.investigation == InvestigationState::Closed && axes.resolution == ResolutionCode::None {
        return Err(AxisViolation::ClosedWithoutResolution);
    }
    Ok(())
}
