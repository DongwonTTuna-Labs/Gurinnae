use std::collections::BTreeSet;

use gurine_domain::privacy::{
    CalendarWeekday, PrivacyDigest, PrivacyError, PrivacyIdentityState, PrivacyPolicyAuthority,
    PrivacyPolicyTimezone, PrivacyPolicyVersion, PrivacyRequestScope, PrivacyRequestState,
    PrivacyRequestSummary, PrivacyRequestType, PrivacyResponseCalendar, PrivacyResponsePolicy,
    PrivacyResponsePolicyDefinition, PrivacyScopeKind,
};
use sha2::{Digest as _, Sha256};
use time::{Date, Duration, Month, OffsetDateTime};
use uuid::Uuid;

const SHA: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

fn date(year: i32, month: Month, day: u8) -> Date {
    match Date::from_calendar_date(year, month, day) {
        Ok(value) => value,
        Err(error) => panic!("test date must be valid: {error}"),
    }
}

fn calendar(holidays: &[Date]) -> PrivacyResponseCalendar {
    let effective_at = timestamp(1_767_225_600);
    let as_of = timestamp(1_785_547_200);
    let review_expires_at = timestamp(1_798_761_600);
    match PrivacyResponseCalendar::try_new(
        Uuid::from_u128(1),
        PrivacyDigest::try_new(SHA).unwrap_or_else(|error| panic!("digest: {error}")),
        "Asia/Seoul",
        &[CalendarWeekday::Saturday, CalendarWeekday::Sunday],
        holidays.iter().copied().collect(),
        effective_at,
        review_expires_at,
        as_of,
    ) {
        Ok(value) => value,
        Err(error) => panic!("calendar: {error}"),
    }
}

fn timestamp(unix_seconds: i64) -> OffsetDateTime {
    OffsetDateTime::from_unix_timestamp(unix_seconds)
        .unwrap_or_else(|error| panic!("timestamp: {error}"))
}

fn policy() -> PrivacyResponsePolicy {
    PrivacyResponsePolicy::try_new(PrivacyResponsePolicyDefinition {
        version: PrivacyPolicyVersion::try_new("supervisor-decision-v1")
            .unwrap_or_else(|error| panic!("version: {error}")),
        policy_digest: PrivacyDigest::try_new(SHA)
            .unwrap_or_else(|error| panic!("digest: {error}")),
        authority: PrivacyPolicyAuthority::try_new("SUPERVISOR_DECISION_V1")
            .unwrap_or_else(|error| panic!("authority: {error}")),
        timezone: PrivacyPolicyTimezone::AsiaSeoul,
        access_business_days: 10,
        correction_business_days: 10,
        deletion_business_days: 10,
        restriction_business_days: 10,
        maximum_extension_business_days: 10,
        maximum_extension_count: 1,
        refusal_notice_business_days: 10,
    })
    .unwrap_or_else(|error| panic!("policy: {error}"))
}

#[test]
fn all_four_rights_remain_discriminated() {
    let rights = [
        PrivacyRequestType::Access,
        PrivacyRequestType::Correction,
        PrivacyRequestType::Deletion,
        PrivacyRequestType::Restriction,
    ];
    let labels = rights.map(PrivacyRequestType::as_str);
    assert_eq!(labels, ["ACCESS", "CORRECTION", "DELETION", "RESTRICTION"]);
}

#[test]
fn scope_variants_enforce_the_closed_shape() {
    let all = PrivacyRequestScope {
        scope_kind: PrivacyScopeKind::AllVerifiedSubjectData,
        object_refs: Vec::new(),
        date_from: None,
        date_to: None,
        include_derivatives: true,
        include_backups: true,
    };
    assert!(all.validate().is_ok());

    let invalid_range = PrivacyRequestScope {
        scope_kind: PrivacyScopeKind::DateRange,
        object_refs: Vec::new(),
        date_from: Some(date(2026, Month::August, 2)),
        date_to: Some(date(2026, Month::August, 1)),
        include_derivatives: false,
        include_backups: false,
    };
    assert_eq!(invalid_range.validate(), Err(PrivacyError::InvalidScope));
}

#[test]
fn date_range_scope_uses_only_iso_date_strings() {
    let input = r#"{
      "scopeKind":"DATE_RANGE",
      "objectRefs":[],
      "dateFrom":"2026-08-01",
      "dateTo":"2026-08-31",
      "includeDerivatives":false,
      "includeBackups":false
    }"#;
    let first: PrivacyRequestScope =
        serde_json::from_str(input).unwrap_or_else(|error| panic!("scope parse: {error}"));
    let second: PrivacyRequestScope =
        serde_json::from_str(input).unwrap_or_else(|error| panic!("scope parse: {error}"));
    assert_eq!(first, second);
    assert_eq!(first.date_from, Some(date(2026, Month::August, 1)));
    assert_eq!(first.date_to, Some(date(2026, Month::August, 31)));

    let canonical = serde_json::to_string(&first)
        .unwrap_or_else(|error| panic!("scope serialization: {error}"));
    assert_eq!(
        canonical,
        r#"{"scopeKind":"DATE_RANGE","objectRefs":[],"dateFrom":"2026-08-01","dateTo":"2026-08-31","includeDerivatives":false,"includeBackups":false}"#
    );
    assert_eq!(
        canonical,
        serde_json::to_string(&second)
            .unwrap_or_else(|error| panic!("scope serialization: {error}"))
    );
    assert_eq!(
        Sha256::digest(canonical.as_bytes()),
        Sha256::digest(
            serde_json::to_string(&second)
                .unwrap_or_else(|error| panic!("scope serialization: {error}"))
                .as_bytes()
        )
    );

    for malformed in [
        r#"{"scopeKind":"DATE_RANGE","objectRefs":[],"dateFrom":[2026,214,1],"dateTo":"2026-08-31","includeDerivatives":false,"includeBackups":false}"#,
        r#"{"scopeKind":"DATE_RANGE","objectRefs":[],"dateFrom":20260801,"dateTo":"2026-08-31","includeDerivatives":false,"includeBackups":false}"#,
        r#"{"scopeKind":"DATE_RANGE","objectRefs":[],"dateFrom":"2026-8-01","dateTo":"2026-08-31","includeDerivatives":false,"includeBackups":false}"#,
        r#"{"scopeKind":"DATE_RANGE","objectRefs":[],"dateFrom":"+2026-08-01","dateTo":"2026-08-31","includeDerivatives":false,"includeBackups":false}"#,
    ] {
        assert!(serde_json::from_str::<PrivacyRequestScope>(malformed).is_err());
    }
}

#[test]
fn response_policy_identifiers_match_the_database_closed_regexes() {
    let future = PrivacyPolicyVersion::try_new("privacy-response.v2_2027-01")
        .unwrap_or_else(|error| panic!("future version: {error}"));
    let authority = PrivacyPolicyAuthority::try_new("LEGAL_REVIEW_BOARD_2027")
        .unwrap_or_else(|error| panic!("authority: {error}"));
    assert_eq!(future.as_str(), "privacy-response.v2_2027-01");
    assert_eq!(authority.as_str(), "LEGAL_REVIEW_BOARD_2027");

    for invalid in [
        "Privacy-response-v2".to_owned(),
        "privacy/response/v2".to_owned(),
        format!("p{}", "a".repeat(100)),
    ] {
        assert_eq!(
            PrivacyPolicyVersion::try_new(invalid),
            Err(PrivacyError::InvalidDeadlinePolicy)
        );
    }
    for invalid in [
        "AB".to_owned(),
        "LEGAL-REVIEW".to_owned(),
        "legal_review".to_owned(),
        format!("A{}", "B".repeat(100)),
    ] {
        assert_eq!(
            PrivacyPolicyAuthority::try_new(invalid),
            Err(PrivacyError::InvalidDeadlinePolicy)
        );
    }
}

#[test]
fn ten_business_days_bind_weekends_and_explicit_holidays() {
    let start = date(2026, Month::August, 3);
    let liberation_day_substitute = date(2026, Month::August, 17);
    let due = policy().request_due_date(
        &calendar(&[liberation_day_substitute]),
        PrivacyRequestType::Access,
        start,
    );
    assert_eq!(due, Ok(date(2026, Month::August, 18)));
}

#[test]
fn extension_is_one_time_and_must_be_requested_before_expiry() {
    let current_due_date = date(2026, Month::August, 18);
    let requested_at = timestamp(1_786_944_400);
    let current_due_at = timestamp(1_787_030_400);
    assert!(
        policy()
            .extension_due_date(
                &calendar(&[]),
                current_due_date,
                10,
                0,
                requested_at,
                current_due_at,
            )
            .is_ok()
    );
    assert_eq!(
        policy().extension_due_date(
            &calendar(&[]),
            current_due_date,
            10,
            1,
            requested_at,
            current_due_at,
        ),
        Err(PrivacyError::ExtensionNotAllowed)
    );
    assert_eq!(
        policy().extension_due_date(
            &calendar(&[]),
            current_due_date,
            10,
            0,
            current_due_at,
            current_due_at,
        ),
        Err(PrivacyError::ExtensionNotAllowed)
    );
}

#[test]
fn policy_uses_request_specific_due_days_from_the_approved_row() {
    let restored = PrivacyResponsePolicy::try_new(PrivacyResponsePolicyDefinition {
        version: PrivacyPolicyVersion::try_new("approved-policy-v2")
            .unwrap_or_else(|error| panic!("version: {error}")),
        policy_digest: PrivacyDigest::try_new(SHA)
            .unwrap_or_else(|error| panic!("digest: {error}")),
        authority: PrivacyPolicyAuthority::try_new("LEGAL_REVIEWED_POLICY")
            .unwrap_or_else(|error| panic!("authority: {error}")),
        timezone: PrivacyPolicyTimezone::AsiaSeoul,
        access_business_days: 2,
        correction_business_days: 3,
        deletion_business_days: 4,
        restriction_business_days: 5,
        maximum_extension_business_days: 4,
        maximum_extension_count: 2,
        refusal_notice_business_days: 6,
    })
    .unwrap_or_else(|error| panic!("policy: {error}"));
    let start = date(2026, Month::August, 3);
    let calendar = calendar(&[]);

    assert_eq!(
        restored.request_due_date(&calendar, PrivacyRequestType::Access, start),
        Ok(date(2026, Month::August, 5))
    );
    assert_eq!(
        restored.request_due_date(&calendar, PrivacyRequestType::Correction, start),
        Ok(date(2026, Month::August, 6))
    );
    assert_eq!(
        restored.request_due_date(&calendar, PrivacyRequestType::Deletion, start),
        Ok(date(2026, Month::August, 7))
    );
    assert_eq!(
        restored.request_due_date(&calendar, PrivacyRequestType::Restriction, start),
        Ok(date(2026, Month::August, 10))
    );
}

#[test]
fn extension_uses_the_closed_requested_days_within_the_policy_maximum() {
    let current_due_date = date(2026, Month::August, 18);
    let requested_at = timestamp(1_786_944_400);
    let current_due_at = timestamp(1_787_030_400);
    let policy = policy();
    let calendar = calendar(&[]);

    assert_eq!(
        policy.extension_due_date(
            &calendar,
            current_due_date,
            3,
            0,
            requested_at,
            current_due_at,
        ),
        Ok(date(2026, Month::August, 21))
    );
    assert_eq!(
        policy.extension_due_date(
            &calendar,
            current_due_date,
            0,
            0,
            requested_at,
            current_due_at,
        ),
        Err(PrivacyError::ExtensionNotAllowed)
    );
    assert_eq!(
        policy.extension_due_date(
            &calendar,
            current_due_date,
            11,
            0,
            requested_at,
            current_due_at,
        ),
        Err(PrivacyError::ExtensionNotAllowed)
    );
}

#[test]
fn disabled_and_bounded_extension_policy_round_trips_closed_rows() {
    let build = |maximum_extension_business_days, maximum_extension_count| {
        PrivacyResponsePolicy::try_new(PrivacyResponsePolicyDefinition {
            version: PrivacyPolicyVersion::try_new("approved-policy-v2")
                .unwrap_or_else(|error| panic!("version: {error}")),
            policy_digest: PrivacyDigest::try_new(SHA)
                .unwrap_or_else(|error| panic!("digest: {error}")),
            authority: PrivacyPolicyAuthority::try_new("LEGAL_REVIEWED_POLICY")
                .unwrap_or_else(|error| panic!("authority: {error}")),
            timezone: PrivacyPolicyTimezone::AsiaSeoul,
            access_business_days: 10,
            correction_business_days: 10,
            deletion_business_days: 10,
            restriction_business_days: 10,
            maximum_extension_business_days,
            maximum_extension_count,
            refusal_notice_business_days: 10,
        })
    };
    let disabled = build(0, 0).unwrap_or_else(|error| panic!("disabled policy: {error}"));
    let current_due_date = date(2026, Month::August, 18);
    let requested_at = timestamp(1_786_944_400);
    let current_due_at = timestamp(1_787_030_400);
    assert_eq!(
        disabled.extension_due_date(
            &calendar(&[]),
            current_due_date,
            1,
            0,
            requested_at,
            current_due_at,
        ),
        Err(PrivacyError::ExtensionNotAllowed)
    );
    assert_eq!(build(0, 1), Err(PrivacyError::InvalidDeadlinePolicy));
    assert_eq!(build(1, 0), Err(PrivacyError::InvalidDeadlinePolicy));
    assert_eq!(build(366, 1), Err(PrivacyError::InvalidDeadlinePolicy));
    assert_eq!(build(1, 11), Err(PrivacyError::InvalidDeadlinePolicy));
}

#[test]
fn missing_or_wrong_calendar_authority_fails_closed() {
    let result = PrivacyResponseCalendar::try_new(
        Uuid::from_u128(1),
        PrivacyDigest::try_new(SHA).unwrap_or_else(|error| panic!("digest: {error}")),
        "UTC",
        &[CalendarWeekday::Saturday, CalendarWeekday::Sunday],
        BTreeSet::new(),
        timestamp(1_767_225_600),
        timestamp(1_798_761_600),
        timestamp(1_785_547_200),
    );
    assert_eq!(result, Err(PrivacyError::CalendarUnavailable));
}

#[test]
fn pending_identity_never_synthesizes_a_due_date() {
    let created_at = timestamp(1_785_547_200);
    let summary = PrivacyRequestSummary::try_new(
        Uuid::from_u128(2),
        PrivacyRequestType::Access,
        PrivacyRequestState::Received,
        "KR",
        PrivacyDigest::try_new(SHA).unwrap_or_else(|error| panic!("digest: {error}")),
        PrivacyIdentityState::PendingVerification,
        None,
        None,
        created_at,
        created_at,
    );
    assert!(summary.is_ok());

    let fake_due = PrivacyRequestSummary::try_new(
        Uuid::from_u128(2),
        PrivacyRequestType::Access,
        PrivacyRequestState::Received,
        "KR",
        PrivacyDigest::try_new(SHA).unwrap_or_else(|error| panic!("digest: {error}")),
        PrivacyIdentityState::PendingVerification,
        None,
        Some(created_at + Duration::days(10)),
        created_at,
        created_at,
    );
    assert_eq!(fake_due, Err(PrivacyError::InvalidProjection));
}
