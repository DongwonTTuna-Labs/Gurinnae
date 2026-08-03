fn map_addendum_owner_error(operation: &str, error: sqlx::Error) -> ServiceError {
    let sqlstate = error
        .as_database_error()
        .and_then(sqlx::error::DatabaseError::code)
        .map(|code| code.into_owned());
    let message = error
        .as_database_error()
        .map(|database_error| database_error.message().to_owned());
    tracing::error!(
        operation,
        sql_state = sqlstate.as_deref().unwrap_or("NON_DATABASE"),
        "addendum owner command failed"
    );
    match funding_disclosure_owner_error(operation, sqlstate.as_deref(), message.as_deref())
        .or_else(|| privacy_owner_error(operation, sqlstate.as_deref(), message.as_deref()))
    {
        Some(error) => error,
        None => db(error),
    }
}

fn funding_disclosure_owner_error(
    operation: &str,
    sqlstate: Option<&str>,
    message: Option<&str>,
) -> Option<ServiceError> {
    let is_funding_action_operation = matches!(
        operation,
        "createActionProposal"
            | "updateActionDraft"
            | "previewActionDraft"
            | "submitActionForReview"
            | "claimActionReview"
            | "submitActionDecision"
    );
    if is_funding_action_operation
        && sqlstate == Some("55000")
        && message == Some("FUNDING_DISCLOSURE_AUTHORITY_UNAVAILABLE")
    {
        // The funding publisher authority is not decision-complete. Preserve
        // the documented redacted 500 boundary without claiming a configured
        // or retryable public capability.
        return Some(ServiceError::Persistence);
    }
    None
}

fn privacy_owner_error(
    operation: &str,
    sqlstate: Option<&str>,
    message: Option<&str>,
) -> Option<ServiceError> {
    if !matches!(
        operation,
        "createPrivacyCorrectionPlan" | "transitionRetentionRequest"
    ) {
        return None;
    }
    match sqlstate {
        Some("PVT06") => Some(ServiceError::IdentityProofInvalid),
        Some("PVT07") => Some(ServiceError::PrivacyScopeInvalid),
        Some("PVT08") => Some(ServiceError::RetentionVersionConflict),
        Some("PVT09") => Some(ServiceError::RetentionStateInvalid),
        Some("0A000")
            if operation == "createPrivacyCorrectionPlan"
                && message == Some("PRIVACY_CORRECTION_TARGET_UNSUPPORTED") =>
        {
            Some(ServiceError::PrivacyCorrectionTargetUnsupported)
        }
        Some("23514")
            if operation == "transitionRetentionRequest"
                && message == Some("BUSINESS_CALENDAR_STALE") =>
        {
            Some(ServiceError::BusinessCalendarStale)
        }
        Some("55000")
            if operation == "transitionRetentionRequest"
                && message == Some("privacy_correction_legal_hold_active") =>
        {
            Some(ServiceError::LegalHoldActive)
        }
        Some("55000") => Some(ServiceError::DependencyUnavailable),
        _ => None,
    }
}
