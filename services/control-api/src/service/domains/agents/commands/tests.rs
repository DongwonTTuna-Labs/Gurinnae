use super::*;

const STORED_DIGEST: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const OTHER_DIGEST: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

fn suggestion_context() -> SuggestionContext {
    SuggestionContext {
        id: Uuid::from_u128(1),
        expected_version: 7,
        stored_payload_sha256: STORED_DIGEST.to_owned(),
        suggestion_type: "HYPOTHESIS".to_owned(),
        case_id: Uuid::from_u128(2),
        case_version: 23,
        payload: json!({"kind": "HYPOTHESIS"}),
        input_snapshot_sha256: OTHER_DIGEST.to_owned(),
    }
}

fn suggestion_input(payload_sha256: Option<&str>) -> SuggestionInput {
    SuggestionInput {
        id: Uuid::from_u128(1),
        expected_version: 7,
        payload_sha256: payload_sha256.map(ToOwned::to_owned),
        reason: "근거 확인 완료".to_owned(),
    }
}

#[test]
fn accepted_audit_binds_locked_digest_when_request_omits_digest() {
    let context = suggestion_context();
    let input = suggestion_input(None);

    let details = suggestion_audit_details(&context, &input, "ACCEPT");

    assert_eq!(
        details.get("payloadSha256").and_then(Value::as_str),
        Some(STORED_DIGEST)
    );
}

#[test]
fn accepted_audit_never_copies_a_caller_digest() {
    let context = suggestion_context();
    let input = suggestion_input(Some(OTHER_DIGEST));

    let details = suggestion_audit_details(&context, &input, "ACCEPT");

    assert_eq!(
        details.get("payloadSha256").and_then(Value::as_str),
        Some(STORED_DIGEST)
    );
}

#[test]
fn caller_digest_mismatch_remains_a_version_conflict() {
    let context = suggestion_context();
    let input = suggestion_input(Some(OTHER_DIGEST));

    assert!(matches!(
        validate_suggestion_binding(7, &input, &context),
        Err(ServiceError::VersionConflict)
    ));
}

#[test]
fn matching_or_omitted_caller_digest_preserves_the_locked_binding() {
    let context = suggestion_context();

    assert!(validate_suggestion_binding(7, &suggestion_input(None), &context).is_ok());
    assert!(
        validate_suggestion_binding(7, &suggestion_input(Some(STORED_DIGEST)), &context).is_ok()
    );
}

#[test]
fn missing_or_invalid_stored_digest_fails_closed() {
    assert!(matches!(
        require_stored_payload_sha256(None),
        Err(ServiceError::Persistence)
    ));
    assert!(matches!(
        require_stored_payload_sha256(Some("not-a-sha256".to_owned())),
        Err(ServiceError::Persistence)
    ));
}

#[test]
fn hypothesis_action_target_binds_the_locked_current_case_version() {
    let context = suggestion_context();
    let case_id = context.case_id.to_string();

    let request = materialized_action_request(&context, "HYPOTHESIS", "CASE", "근거 확인 완료");

    assert_eq!(
        request
            .pointer("/draft/target/version")
            .and_then(Value::as_i64),
        Some(23)
    );
    assert_eq!(
        request.pointer("/draft/target/id").and_then(Value::as_str),
        Some(case_id.as_str())
    );
}

#[test]
fn non_hypothesis_action_target_preserves_its_existing_initial_version() {
    let context = suggestion_context();

    let request = materialized_action_request(&context, "TASK", "TASK", "근거 확인 완료");

    assert_eq!(
        request
            .pointer("/draft/target/version")
            .and_then(Value::as_i64),
        Some(1)
    );
}
