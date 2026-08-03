use gurine_detection::engine;
use serde_json::{Value, json};

use super::*;

fn frozen() -> Value {
    json!({
        "schema_version": "conflict-detection-input.v2",
        "rule_id": "OFFICER_OVERLAP_AWARD",
        "rule_version_id": "00000000-0000-0000-0000-000000000001",
        "rule_version_digest": "a".repeat(64),
        "coverage_status": "BLOCKED",
        "coverage": {
            "contracts_complete": false,
            "procurement_notices_complete": false,
            "procurement_awards_complete": false,
            "bidder_participations_complete": false,
            "typed_relationships_complete": false,
            "strong_identifier_facts_complete": false,
            "bidder_participation_authority": "koneps-structured-bidder-participation",
        },
        "contracts": [],
        "procurement_notices": [],
        "procurement_awards": [],
        "bidder_participations": [],
        "typed_relationship_assertions": [],
        "strong_identifier_facts": [],
        "suppliers": [],
        "sanctions": [],
    })
}

macro_rules! materialized {
    ($rule_id:expr, $configuration:expr, $frozen:expr $(,)?) => {{
        let result = materialize_conflict_rule_input($rule_id, &$configuration, $frozen);
        assert!(result.is_ok(), "materialization failed: {result:?}");
        let Ok(value) = result else {
            return;
        };
        value
    }};
}

fn blocker(rule_id: &str, input: &Value) -> Option<String> {
    let evaluated = engine::evaluate(rule_id, input).ok()?;
    evaluated
        .get("blockers")?
        .as_array()?
        .first()?
        .as_str()
        .map(str::to_owned)
}

fn policy(rule_id: &str) -> Value {
    match rule_id {
        "OFFICER_OVERLAP_AWARD" => json!({"minimum_distinct_suppliers": 2}),
        "OWNERSHIP_LINKED_COMPETITORS" => json!({
            "minimum_linked_participants": 2,
            "maximum_relationship_hops": 2,
        }),
        "BID_ROTATION" => json!({
            "minimum_notice_count": 3,
            "window_days": 60,
            "minimum_bidders_per_notice": 3,
            "minimum_distinct_winners": 3,
            "cluster_metric": "LOSING_BID_RANGE_BPS",
            "cluster_tolerance_bps": 200,
            "currency": "KRW",
            "tie_handling": "BLOCK",
        }),
        "REVOLVING_DOOR_CONTRACT" => json!({
            "cooling_period_days": 730,
            "procurement_method_allowlist": ["SINGLE_SOURCE"],
            "cooling_boundary": "DEPARTURE_EXCLUSIVE_COOLING_END_INCLUSIVE",
        }),
        "SANCTIONED_SUCCESSOR" => json!({
            "maximum_new_entity_age_days": 365,
            "post_sanction_award_window_days": 180,
            "sanction_effective_date_semantics": "START_DATE_INCLUSIVE",
            "link_match_mode": "STRONG_IDENTIFIER_OR_APPROVED_OFFICER",
        }),
        _ => Value::Null,
    }
}

#[test]
fn configuration_policy_is_the_only_policy_authority() {
    let mut frozen = frozen();
    frozen["policy"] = json!({"minimum_distinct_suppliers": 99});
    let result = materialized!(
        "OFFICER_OVERLAP_AWARD",
        json!({
            "policy": {"minimum_distinct_suppliers": 2},
            "minimum_distinct_suppliers": 77,
        }),
        &frozen,
    );
    assert_eq!(result.value["policy"]["minimum_distinct_suppliers"], 2);
    assert_eq!(result.value.as_object().map(|value| value.len()), Some(4));
}

#[test]
fn absent_policy_is_blocked_by_each_rule_without_defaults() {
    let frozen = frozen();
    let cases = [
        ("OFFICER_OVERLAP_AWARD", "REQUIRED_FIELD_MISSING"),
        ("OWNERSHIP_LINKED_COMPETITORS", "POLICY_MISSING"),
        ("BID_ROTATION", "REQUIRED_FIELD_MISSING"),
        ("REVOLVING_DOOR_CONTRACT", "REQUIRED_FIELD_MISSING"),
        ("SANCTIONED_SUCCESSOR", "RULE_POLICY_INACTIVE"),
    ];
    for (rule_id, expected) in cases {
        let result = materialized!(rule_id, json!({}), &frozen);
        assert_eq!(blocker(rule_id, &result.value).as_deref(), Some(expected));
    }
}

#[test]
fn unavailable_production_sources_win_before_record_validation() {
    let frozen = frozen();
    let cases = [
        ("OFFICER_OVERLAP_AWARD", "SOURCE_COVERAGE_INCOMPLETE"),
        (
            "OWNERSHIP_LINKED_COMPETITORS",
            "STRUCTURED_BIDDER_SOURCE_UNAVAILABLE",
        ),
        ("BID_ROTATION", "STRUCTURED_PARTICIPANT_SOURCE_UNAVAILABLE"),
        (
            "REVOLVING_DOOR_CONTRACT",
            "OFFICIAL_REEMPLOYMENT_SOURCE_UNAVAILABLE",
        ),
        ("SANCTIONED_SUCCESSOR", "SANCTION_SOURCE_NOT_READY"),
    ];
    for (rule_id, expected) in cases {
        let result = materialized!(rule_id, json!({"policy": policy(rule_id)}), &frozen);
        assert_eq!(blocker(rule_id, &result.value).as_deref(), Some(expected));
    }
}

#[test]
fn blocked_authority_status_wins_before_malformed_frozen_rows() {
    let mut frozen = frozen();
    for key in [
        "contracts_complete",
        "procurement_notices_complete",
        "procurement_awards_complete",
        "bidder_participations_complete",
        "typed_relationships_complete",
        "strong_identifier_facts_complete",
    ] {
        frozen["coverage"][key] = true.into();
    }
    for key in [
        "contracts",
        "procurement_notices",
        "procurement_awards",
        "bidder_participations",
        "typed_relationship_assertions",
        "strong_identifier_facts",
        "suppliers",
        "sanctions",
    ] {
        frozen[key] = json!(["malformed-row"]);
    }
    let cases = [
        ("OFFICER_OVERLAP_AWARD", "SOURCE_COVERAGE_INCOMPLETE"),
        (
            "OWNERSHIP_LINKED_COMPETITORS",
            "STRUCTURED_BIDDER_SOURCE_UNAVAILABLE",
        ),
        ("BID_ROTATION", "STRUCTURED_PARTICIPANT_SOURCE_UNAVAILABLE"),
        (
            "REVOLVING_DOOR_CONTRACT",
            "OFFICIAL_REEMPLOYMENT_SOURCE_UNAVAILABLE",
        ),
        ("SANCTIONED_SUCCESSOR", "SANCTION_SOURCE_NOT_READY"),
    ];
    for (rule_id, expected) in cases {
        let result = materialized!(rule_id, json!({"policy": policy(rule_id)}), &frozen);
        assert_eq!(blocker(rule_id, &result.value).as_deref(), Some(expected));
    }
}

#[test]
fn partial_input_is_not_relabelled_as_an_unavailable_authority() {
    let mut frozen = frozen();
    frozen["coverage_status"] = "PARTIAL".into();
    frozen["coverage"]["typed_relationships_complete"] = true.into();
    frozen["coverage"]["procurement_notices_complete"] = true.into();
    frozen["coverage"]["procurement_awards_complete"] = true.into();
    frozen["coverage"]["strong_identifier_facts_complete"] = true.into();

    let officer = materialized!(
        "OFFICER_OVERLAP_AWARD",
        json!({"policy": policy("OFFICER_OVERLAP_AWARD")}),
        &frozen,
    );
    assert_eq!(
        blocker("OFFICER_OVERLAP_AWARD", &officer.value).as_deref(),
        Some("SOURCE_COVERAGE_INCOMPLETE")
    );

    let ownership = materialized!(
        "OWNERSHIP_LINKED_COMPETITORS",
        json!({"policy": policy("OWNERSHIP_LINKED_COMPETITORS")}),
        &frozen,
    );
    assert_eq!(
        ownership.value["procurement"]["structured_participant_source"]["status"],
        "STRUCTURED_COMPLETE"
    );
    assert_eq!(
        blocker("OWNERSHIP_LINKED_COMPETITORS", &ownership.value).as_deref(),
        Some("STRUCTURED_BIDDER_COVERAGE_INCOMPLETE")
    );

    let rotation = materialized!(
        "BID_ROTATION",
        json!({"policy": policy("BID_ROTATION")}),
        &frozen,
    );
    assert_eq!(
        rotation.value["participant_source"]["status"],
        "STRUCTURED_COMPLETE"
    );
    assert_eq!(
        blocker("BID_ROTATION", &rotation.value).as_deref(),
        Some("PERIOD_COVERAGE_INCOMPLETE")
    );

    let revolving = materialized!(
        "REVOLVING_DOOR_CONTRACT",
        json!({"policy": policy("REVOLVING_DOOR_CONTRACT")}),
        &frozen,
    );
    assert_eq!(
        revolving.value["source_coverage"]["official_reemployment_source_available"],
        true
    );
    assert_eq!(
        blocker("REVOLVING_DOOR_CONTRACT", &revolving.value).as_deref(),
        Some("OFFICIAL_REEMPLOYMENT_COVERAGE_INCOMPLETE")
    );

    let sanctioned = materialized!(
        "SANCTIONED_SUCCESSOR",
        json!({"policy": policy("SANCTIONED_SUCCESSOR")}),
        &frozen,
    );
    assert_eq!(sanctioned.value["sanction_source_status"], "READY");
    assert_eq!(
        blocker("SANCTIONED_SUCCESSOR", &sanctioned.value).as_deref(),
        Some("INSUFFICIENT_CONTEXT")
    );
}

#[test]
fn ownership_identity_status_is_never_invented() {
    let mut frozen = frozen();
    frozen["coverage_status"] = "COMPLETE".into();
    frozen["coverage"]["bidder_participations_complete"] = true.into();
    frozen["coverage"]["typed_relationships_complete"] = true.into();
    frozen["procurement_notices"] = json!([{
        "id": "NOTICE-1",
        "bid_opened_at": "2026-01-15",
    }]);
    frozen["bidder_participations"] = json!([
        {
            "notice_id": "NOTICE-1",
            "supplier_id": "SUP-1",
            "participation_status": "VALID",
            "identity_status": "UNVERIFIED",
            "coverage_status": "COMPLETE",
        },
        {
            "notice_id": "NOTICE-1",
            "supplier_id": "SUP-2",
            "participation_status": "VALID",
            "identity_status": "VERIFIED",
            "coverage_status": "COMPLETE",
        },
    ]);
    frozen["suppliers"] = json!([
        {"id": "SUP-1", "identity_status": "UNVERIFIED"},
        {"id": "SUP-2", "identity_status": "VERIFIED"},
    ]);
    frozen["typed_relationship_assertions"] = json!([{
        "relationship_id": "REL-1",
        "relationship_kind": "OWNERSHIP",
        "subject_kind": "SUPPLIER",
        "object_kind": "SUPPLIER",
        "subject_entity_id": "SUP-1",
        "object_entity_id": "SUP-2",
        "verification_status": "VERIFIED",
        "public_use_status": "APPROVED",
        "validity_coverage_status": "COMPLETE",
        "valid_from": "2025-01-01",
        "valid_to": "2027-01-01",
    }]);
    let result = materialized!(
        "OWNERSHIP_LINKED_COMPETITORS",
        json!({"policy": policy("OWNERSHIP_LINKED_COMPETITORS")}),
        &frozen,
    );
    assert_eq!(
        result.value["relationships"][0]["source_identity_status"],
        "UNVERIFIED"
    );
    assert_eq!(
        blocker("OWNERSHIP_LINKED_COMPETITORS", &result.value).as_deref(),
        Some("PARTICIPANT_IDENTITY_INCOMPLETE")
    );
}

#[test]
fn bid_opened_at_is_not_filled_from_notice_dates() {
    let mut frozen = frozen();
    frozen["coverage_status"] = "COMPLETE".into();
    frozen["coverage"]["bidder_participations_complete"] = true.into();
    frozen["procurement_notices"] = json!([{
        "id": "NOTICE-1",
        "bid_opened_at": null,
        "published_on": "2026-01-01",
        "closes_on": "2026-01-14",
    }]);
    let result = materialized!(
        "OWNERSHIP_LINKED_COMPETITORS",
        json!({"policy": policy("OWNERSHIP_LINKED_COMPETITORS")}),
        &frozen,
    );
    assert!(result.value["procurement"]["bid_opened_at"].is_null());
}

#[test]
fn former_role_uses_departed_on_and_excludes_person_display_data() {
    let mut frozen = frozen();
    frozen["coverage_status"] = "COMPLETE".into();
    frozen["coverage"]["typed_relationships_complete"] = true.into();
    frozen["typed_relationship_assertions"] = json!([{
        "relationship_id": "FORMER-1",
        "relationship_kind": "FORMER_OFFICIAL_ROLE",
        "subject_kind": "PERSON",
        "object_kind": "AGENCY",
        "object_entity_id": "AGENCY-1",
        "person_identifier_digest": "b".repeat(64),
        "person_name": "노출 금지 이름",
        "person_title": "노출 금지 직책",
        "valid_from": "2020-01-01",
        "valid_to": "2024-01-01",
        "departed_on": "2024-01-01",
        "validity_coverage_status": "COMPLETE",
        "verification_status": "VERIFIED",
        "public_use_status": "APPROVED",
        "independent_human_verification": true,
        "source_kind": "PUBLIC_OFFICIAL_ETHICS_NOTICE",
        "source_locators": ["c".repeat(64)],
        "evidence_ids": ["EVIDENCE-1"],
    }]);
    let result = materialized!(
        "REVOLVING_DOOR_CONTRACT",
        json!({"policy": policy("REVOLVING_DOOR_CONTRACT")}),
        &frozen,
    );
    assert_eq!(
        result.value["former_official_roles"][0]["departed_on"],
        "2024-01-01"
    );
    let rendered = result.value.to_string();
    assert!(!rendered.contains("노출 금지 이름"));
    assert!(!rendered.contains("노출 금지 직책"));
    assert!(!rendered.contains("https://"));
}

#[test]
fn raw_person_source_locator_is_rejected() {
    let mut frozen = frozen();
    frozen["coverage_status"] = "COMPLETE".into();
    frozen["coverage"]["typed_relationships_complete"] = true.into();
    frozen["typed_relationship_assertions"] = json!([{
        "relationship_id": "FORMER-RAW",
        "relationship_kind": "FORMER_OFFICIAL_ROLE",
        "subject_kind": "PERSON",
        "object_kind": "AGENCY",
        "object_entity_id": "AGENCY-1",
        "person_identifier_digest": "b".repeat(64),
        "valid_from": "2020-01-01",
        "valid_to": "2024-01-01",
        "departed_on": "2024-01-01",
        "validity_coverage_status": "COMPLETE",
        "verification_status": "VERIFIED",
        "public_use_status": "APPROVED",
        "independent_human_verification": true,
        "source_kind": "PUBLIC_OFFICIAL_ETHICS_NOTICE",
        "source_locators": ["https://official.example/person/1"],
        "evidence_ids": ["EVIDENCE-1"],
    }]);
    let result = materialize_conflict_rule_input(
        "REVOLVING_DOOR_CONTRACT",
        &json!({"policy": policy("REVOLVING_DOOR_CONTRACT")}),
        &frozen,
    );
    assert!(result.is_err());
}

#[test]
fn bid_decimals_are_strings_and_internal_coverage_is_not_exposed() {
    let mut frozen = frozen();
    frozen["coverage_status"] = "COMPLETE".into();
    frozen["coverage"]["bidder_participations_complete"] = true.into();
    frozen["coverage"]["procurement_notices_complete"] = true.into();
    frozen["procurement_notices"] = json!([{
        "id": "NOTICE-1",
        "agency_id": "AGENCY-1",
        "published_on": "2026-01-01",
    }]);
    frozen["bidder_participations"] = json!([{
        "notice_id": "NOTICE-1",
        "supplier_id": "SUP-1",
        "bid_amount": 1000.25,
        "currency": "KRW",
        "coverage_status": "COMPLETE",
    }]);
    frozen["procurement_awards"] = json!([{
        "notice_id": "NOTICE-1",
        "supplier_ids": ["SUP-1"],
    }]);
    let mut configured_policy = policy("BID_ROTATION");
    configured_policy["cluster_tolerance_bps"] = json!(200.5);
    let result = materialized!(
        "BID_ROTATION",
        json!({"policy": configured_policy}),
        &frozen,
    );
    assert_eq!(result.value["policy"]["cluster_tolerance_bps"], "200.5");
    assert_eq!(
        result.value["notices"][0]["participants"][0]["bid_amount"],
        "1000.25"
    );
    assert!(
        result.value["notices"][0]["participants"][0]
            .get("coverage_status")
            .is_none()
    );
}

#[test]
fn unproven_or_legacy_identifiers_are_not_strong_rule_facts() {
    let mut frozen = frozen();
    frozen["coverage_status"] = "PARTIAL".into();
    frozen["strong_identifier_facts"] = json!([
        {
            "supplier_id": "SUP-1",
            "scheme": "KOREAN_BUSINESS_NUMBER",
            "value_hash": "a".repeat(64),
            "verification_status": "VERIFIED",
            "proof_state": "PROVEN_V1",
        },
        {
            "supplier_id": "SUP-2",
            "scheme": "BUSINESS_NUMBER",
            "value_hash": "b".repeat(64),
            "verification_status": "VERIFIED",
            "proof_state": "PROVEN_V1",
        },
        {
            "supplier_id": "SUP-3",
            "scheme": "OPEN_DART_CORP_CODE",
            "value_hash": "c".repeat(64),
            "verification_status": "VERIFIED",
            "proof_state": "LEGACY_UNPROVEN",
        },
    ]);
    let result = materialized!(
        "SANCTIONED_SUCCESSOR",
        json!({"policy": policy("SANCTIONED_SUCCESSOR")}),
        &frozen,
    );
    assert_eq!(
        result.value["strong_identifier_facts"]
            .as_array()
            .map(Vec::len),
        Some(1)
    );
}

#[test]
fn identical_frozen_input_has_identical_materialized_digest() {
    let frozen = frozen();
    let configuration = json!({"policy": policy("BID_ROTATION")});
    let first = materialized!("BID_ROTATION", configuration.clone(), &frozen);
    let second = materialized!("BID_ROTATION", configuration, &frozen);
    assert_eq!(first.value, second.value);
    assert_eq!(first.input_sha256, second.input_sha256);
}
