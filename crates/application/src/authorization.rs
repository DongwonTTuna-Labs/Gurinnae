use std::collections::BTreeSet;

use thiserror::Error;
use uuid::Uuid;

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum AssuranceLevel {
    AnonymousProof,
    ScopedToken,
    ActiveSession,
    RecentSession,
    StepUp,
}

#[derive(Clone, Debug)]
pub struct ActorContext {
    pub user_id: Uuid,
    pub session_id: Uuid,
    pub capabilities: BTreeSet<String>,
    pub auth_time: i64,
    pub step_up_at: Option<i64>,
    pub roles_version: i64,
}

#[derive(Clone, Copy)]
pub struct AuthorizationRequirement<'a> {
    pub capability: &'a str,
    pub assurance: AssuranceLevel,
    pub now: i64,
    pub recent_max_age_seconds: i64,
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum AuthorizationError {
    #[error("required capability is absent")]
    CapabilityDenied,
    #[error("required assurance is absent or stale")]
    AssuranceDenied,
}

pub fn authorize(
    actor: &ActorContext,
    requirement: AuthorizationRequirement<'_>,
) -> Result<(), AuthorizationError> {
    if !requirement.capability.is_empty() && !actor.capabilities.contains(requirement.capability) {
        return Err(AuthorizationError::CapabilityDenied);
    }
    let recent = actor.step_up_at.unwrap_or(actor.auth_time);
    let assurance_satisfied = match requirement.assurance {
        AssuranceLevel::AnonymousProof
        | AssuranceLevel::ScopedToken
        | AssuranceLevel::ActiveSession => true,
        AssuranceLevel::RecentSession => {
            requirement.now - recent <= requirement.recent_max_age_seconds
        }
        AssuranceLevel::StepUp => actor
            .step_up_at
            .is_some_and(|step_up| requirement.now - step_up <= 300),
    };
    if !assurance_satisfied {
        return Err(AuthorizationError::AssuranceDenied);
    }
    Ok(())
}
