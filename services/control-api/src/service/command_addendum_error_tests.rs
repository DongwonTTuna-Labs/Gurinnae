use super::*;

#[test]
fn privacy_sqlstates_map_only_on_the_owned_privacy_surfaces() {
    for (sqlstate, expected) in [
        ("PVT06", ServiceError::IdentityProofInvalid),
        ("PVT07", ServiceError::PrivacyScopeInvalid),
        ("PVT08", ServiceError::RetentionVersionConflict),
        ("PVT09", ServiceError::RetentionStateInvalid),
    ] {
        for operation in ["createPrivacyCorrectionPlan", "transitionRetentionRequest"] {
            assert!(matches!(
                privacy_owner_error(operation, Some(sqlstate), None),
                Some(actual) if std::mem::discriminant(&actual) == std::mem::discriminant(&expected)
            ));
        }
    }
    assert!(matches!(
        privacy_owner_error("transitionRetentionRequest", Some("55000"), None),
        Some(ServiceError::DependencyUnavailable)
    ));
    assert!(matches!(
        privacy_owner_error("createPrivacyCorrectionPlan", Some("55000"), None),
        Some(ServiceError::DependencyUnavailable)
    ));
    assert!(privacy_owner_error("transitionRetentionRequest", Some("23514"), None).is_none());
    assert!(privacy_owner_error("submitActionDecision", Some("PVT06"), None).is_none());
}

#[test]
fn correction_active_hold_requires_the_exact_transition_owner_pair() {
    assert!(matches!(
        privacy_owner_error(
            "transitionRetentionRequest",
            Some("55000"),
            Some("privacy_correction_legal_hold_active"),
        ),
        Some(ServiceError::LegalHoldActive)
    ));
    for (operation, sqlstate, message) in [
        (
            "createPrivacyCorrectionPlan",
            Some("55000"),
            Some("privacy_correction_legal_hold_active"),
        ),
        (
            "transitionRetentionRequest",
            Some("55000"),
            Some("PRIVACY_CORRECTION_LEGAL_HOLD_ACTIVE"),
        ),
        (
            "transitionRetentionRequest",
            Some("55000"),
            Some("privacy_correction_legal_hold_active: changed"),
        ),
    ] {
        assert!(matches!(
            privacy_owner_error(operation, sqlstate, message),
            Some(ServiceError::DependencyUnavailable)
        ));
    }
}

#[test]
fn calendar_stale_requires_the_exact_owned_sqlstate_and_message_pair() {
    assert!(matches!(
        privacy_owner_error(
            "transitionRetentionRequest",
            Some("23514"),
            Some("BUSINESS_CALENDAR_STALE"),
        ),
        Some(ServiceError::BusinessCalendarStale)
    ));
    for (operation, sqlstate, message) in [
        (
            "createPrivacyCorrectionPlan",
            Some("23514"),
            Some("BUSINESS_CALENDAR_STALE"),
        ),
        (
            "transitionRetentionRequest",
            Some("23514"),
            Some("business_calendar_stale"),
        ),
        (
            "transitionRetentionRequest",
            Some("23514"),
            Some("BUSINESS_CALENDAR_STALE: changed"),
        ),
    ] {
        assert!(privacy_owner_error(operation, sqlstate, message).is_none());
    }
    assert!(matches!(
        privacy_owner_error(
            "transitionRetentionRequest",
            Some("55000"),
            Some("BUSINESS_CALENDAR_STALE"),
        ),
        Some(ServiceError::DependencyUnavailable)
    ));
}

#[test]
fn correction_target_unsupported_requires_the_exact_owned_pair() {
    assert!(matches!(
        privacy_owner_error(
            "createPrivacyCorrectionPlan",
            Some("0A000"),
            Some("PRIVACY_CORRECTION_TARGET_UNSUPPORTED"),
        ),
        Some(ServiceError::PrivacyCorrectionTargetUnsupported)
    ));
    for (operation, sqlstate, message) in [
        (
            "transitionRetentionRequest",
            Some("0A000"),
            Some("PRIVACY_CORRECTION_TARGET_UNSUPPORTED"),
        ),
        (
            "createPrivacyCorrectionPlan",
            Some("0A000"),
            Some("privacy_correction_target_unsupported"),
        ),
    ] {
        assert!(privacy_owner_error(operation, sqlstate, message).is_none());
    }
    assert!(matches!(
        privacy_owner_error(
            "createPrivacyCorrectionPlan",
            Some("55000"),
            Some("PRIVACY_CORRECTION_TARGET_UNSUPPORTED"),
        ),
        Some(ServiceError::DependencyUnavailable)
    ));
}
