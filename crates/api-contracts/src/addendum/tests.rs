use super::{
    control_operation, persistence_owner, request_schema, response_schema, validate_control_command,
};
use serde_json::{Map, Value, json};

fn decision_payload(action_kind: &str) -> Map<String, Value> {
    json!({
        "proposalId": "00000000-0000-4000-8000-000000000001",
        "actionKind": action_kind,
        "assignmentId": "00000000-0000-4000-8000-000000000002",
        "expectedProposalVersion": 1,
        "expectedAssignmentVersion": 1,
        "expectedApprovalDigest": "0".repeat(64),
        "decision": {"kind": "APPROVE"}
    })
    .as_object()
    .cloned()
    .unwrap_or_default()
}

#[test]
fn provider_decision_requires_one_closed_operation_discriminator() {
    let mut valid = decision_payload("PROVIDER_CONTROL");
    valid.insert(
        "providerOperationId".into(),
        Value::String("upgradeProviderModel".into()),
    );
    assert!(validate_control_command("submitActionDecision", &valid));

    let missing = decision_payload("PROVIDER_CONTROL");
    assert!(!validate_control_command("submitActionDecision", &missing));

    valid.insert(
        "providerOperationId".into(),
        Value::String("unknownProviderEffect".into()),
    );
    assert!(!validate_control_command("submitActionDecision", &valid));
}

#[test]
fn non_provider_decision_forbids_provider_discriminator_and_extra_fields() {
    let mut valid = decision_payload("TASK");
    assert!(validate_control_command("submitActionDecision", &valid));

    valid.insert(
        "providerOperationId".into(),
        Value::String("testProviderConnection".into()),
    );
    assert!(!validate_control_command("submitActionDecision", &valid));

    valid.remove("providerOperationId");
    valid.insert("undocumented".into(), Value::Bool(true));
    assert!(!validate_control_command("submitActionDecision", &valid));
}

#[test]
fn retention_transition_uses_v2_common_and_variant_field_catalog() {
    assert_eq!(
        request_schema("transitionRetentionRequest"),
        Some("TransitionRetentionRequestRequestV2")
    );
    assert_eq!(
        response_schema("transitionRetentionRequest"),
        Some("RetentionRequestDecisionReceiptV2")
    );
    let mut payload = json!({
        "retentionRequestId": "00000000-0000-4000-8000-000000000001",
        "expectedDecisionVersion": 0,
        "transition": "VERIFY_IDENTITY",
        "reasonCode": "OPERATOR_REVIEW",
        "reason": "검증된 운영 사유",
        "identityProofReceiptId": "00000000-0000-4000-8000-000000000002"
    })
    .as_object()
    .cloned()
    .unwrap_or_default();
    assert!(validate_control_command(
        "transitionRetentionRequest",
        &payload
    ));

    payload.remove("identityProofReceiptId");
    payload.insert("inventorySnapshotDigest".into(), json!("0".repeat(64)));
    assert!(!validate_control_command(
        "transitionRetentionRequest",
        &payload
    ));
}

#[test]
fn privacy_correction_plan_operation_is_closed_step_up_and_producer_only()
-> Result<(), &'static str> {
    let operation = control_operation("createPrivacyCorrectionPlan")
        .ok_or("privacy correction plan producer must be routed")?;
    assert_eq!(
        operation.path,
        "/v1/internal/commands/create-privacy-correction-plan"
    );
    assert_eq!(operation.capability, "privacy.requests.manage");
    assert_eq!(operation.assurance_level, "STEP_UP");
    assert!(operation.step_up_required);
    assert_eq!(operation.success_status, 201);
    assert_eq!(
        request_schema(operation.id),
        Some("CreatePrivacyCorrectionPlanRequestV1")
    );
    assert_eq!(
        response_schema(operation.id),
        Some("PrivacyCorrectionPlanReceiptV1")
    );
    assert_eq!(
        persistence_owner(operation.id),
        Some("ops.privacy_correction_plans_v1")
    );

    let mut payload = json!({
        "retentionRequestId":"10000000-0000-4000-8000-000000000001",
        "expectedDecisionVersion":2,
        "targetObjectType":"RESPONSE",
        "targetObjectId":"10000000-0000-4000-8000-000000000002",
        "fieldPath":"/displayName",
        "currentValueDigest":"a".repeat(64),
        "requestedValue":"정정된 표시 이름",
        "evidenceIds":["10000000-0000-4000-8000-000000000003"],
        "reason":"증거와 일치하도록 정정 계획을 기록함"
    })
    .as_object()
    .cloned()
    .unwrap_or_default();
    assert!(validate_control_command(operation.id, &payload));

    payload.insert(
        "requestedValueCiphertextBase64".to_owned(),
        json!("caller-supplied"),
    );
    assert!(
        !validate_control_command(operation.id, &payload),
        "caller-supplied sealed fields must remain outside the public contract"
    );
    Ok(())
}

#[test]
fn response_organization_identity_operation_is_closed_and_step_up() -> Result<(), &'static str> {
    let operation = control_operation("verifyResponseOrganizationIdentity")
        .ok_or("response identity operation must be routed")?;
    assert_eq!(
        operation.path,
        "/v1/internal/commands/verify-response-organization-identity"
    );
    assert_eq!(operation.capability, "responses.review");
    assert_eq!(operation.assurance_level, "STEP_UP");
    assert!(operation.step_up_required);
    assert_eq!(
        request_schema(operation.id),
        Some("VerifyResponseOrganizationIdentityRequestV1")
    );
    assert_eq!(
        response_schema(operation.id),
        Some("VerifyResponseOrganizationIdentityReceiptV1")
    );
    assert_eq!(
        persistence_owner(operation.id),
        Some("editorial.response_organization_identity_assertions_v1")
    );

    let mut payload = json!({
        "responseId": "10000000-0000-4000-8000-000000000001",
        "organizationId": "10000000-0000-4000-8000-000000000002",
        "publicationForm": "REDACTED",
        "verificationMethod": "OFFICIAL_DOCUMENT",
        "officialChannelSourceId": "10000000-0000-4000-8000-000000000003",
        "reason": "공식 채널 확인",
        "expectedVersion": 1
    })
    .as_object()
    .cloned()
    .unwrap_or_default();
    assert!(validate_control_command(operation.id, &payload));

    payload.insert(
        "communicationVerificationId".to_owned(),
        json!("10000000-0000-4000-8000-000000000004"),
    );
    assert!(!validate_control_command(operation.id, &payload));
    Ok(())
}

#[test]
fn official_channel_authority_operations_are_closed_and_step_up() -> Result<(), &'static str> {
    let attest = control_operation("attestOrganizationOfficialChannel")
        .ok_or("official-channel attestation must be routed")?;
    assert_eq!(
        attest.path,
        "/v1/internal/commands/attest-organization-official-channel"
    );
    assert_eq!(attest.capability, "responses.review");
    assert_eq!(attest.assurance_level, "STEP_UP");
    assert!(attest.step_up_required);
    assert_eq!(
        request_schema(attest.id),
        Some("AttestOrganizationOfficialChannelRequestV1")
    );
    assert_eq!(
        response_schema(attest.id),
        Some("AttestOrganizationOfficialChannelReceiptV1")
    );
    assert_eq!(
        persistence_owner(attest.id),
        Some("editorial.organization_official_channel_authority_receipts_v1")
    );

    let mut attest_payload = json!({
        "organizationKind":"AGENCY",
        "organizationId":"10000000-0000-4000-8000-000000000001",
        "verificationMethod":"OFFICIAL_DOCUMENT",
        "sourceId":"10000000-0000-4000-8000-000000000002",
        "expiresAt":"2027-08-01T00:00:00Z",
        "reason":"독립 검토자가 공식 채널을 확인함",
        "expectedAuthorityVersion":1
    })
    .as_object()
    .cloned()
    .unwrap_or_default();
    assert!(validate_control_command(attest.id, &attest_payload));
    attest_payload.insert("authorityReceiptDigest".into(), json!("0".repeat(64)));
    assert!(
        !validate_control_command(attest.id, &attest_payload),
        "caller-supplied authority digests must remain outside the command contract"
    );

    let revoke = control_operation("revokeOrganizationOfficialChannel")
        .ok_or("official-channel revocation must be routed")?;
    assert_eq!(revoke.capability, "responses.review");
    assert_eq!(revoke.assurance_level, "STEP_UP");
    assert_eq!(
        persistence_owner(revoke.id),
        Some("editorial.organization_official_channel_revocation_receipts_v1")
    );
    let revoke_payload = json!({
        "assertionId":"10000000-0000-4000-8000-000000000001",
        "reasonCode":"SOURCE_AUTHORITY_REVOKED",
        "reason":"공식 채널 권위가 철회됨"
    })
    .as_object()
    .cloned()
    .unwrap_or_default();
    assert!(validate_control_command(revoke.id, &revoke_payload));
    Ok(())
}

#[test]
fn entity_personhood_authority_operations_are_closed_and_step_up() -> Result<(), &'static str> {
    let classify = control_operation("classifyEntityPersonhood")
        .ok_or("entity personhood classification must be routed")?;
    assert_eq!(
        classify.path,
        "/v1/internal/commands/classify-entity-personhood"
    );
    assert_eq!(classify.capability, "users.manage");
    assert_eq!(classify.assurance_level, "STEP_UP");
    assert_eq!(
        request_schema(classify.id),
        Some("ClassifyEntityPersonhoodRequestV1")
    );
    assert_eq!(
        persistence_owner(classify.id),
        Some("ops.r6d_entity_personhood_classification_receipts_v1")
    );
    let mut classification = json!({
        "entityKind":"SUPPLIER",
        "entityId":"10000000-0000-4000-8000-000000000001",
        "classification":"NATURAL_PERSON",
        "evidenceSourceLocator":"https://public.example.invalid/registration/1",
        "expectedEntityUpdatedAt":"2026-08-01T00:00:00Z",
        "reason":"공개 등록 형태를 사람이 검토함"
    })
    .as_object()
    .cloned()
    .unwrap_or_default();
    assert!(validate_control_command(classify.id, &classification));
    classification.insert("receiptDigest".into(), json!("0".repeat(64)));
    assert!(!validate_control_command(classify.id, &classification));

    let closure = control_operation("attestEntityMaterialUseClosure")
        .ok_or("entity material-use closure must be routed")?;
    assert_eq!(
        closure.path,
        "/v1/internal/commands/attest-entity-material-use-closure"
    );
    assert_eq!(closure.capability, "users.manage");
    assert_eq!(closure.assurance_level, "STEP_UP");
    assert_eq!(
        response_schema(closure.id),
        Some("AttestEntityMaterialUseClosureReceiptV1")
    );
    assert_eq!(
        persistence_owner(closure.id),
        Some("ops.r6d_entity_material_use_closure_receipts_v1")
    );
    let closure_payload = json!({
        "entityKind":"SUPPLIER",
        "entityId":"10000000-0000-4000-8000-000000000001",
        "personhoodReceiptId":"10000000-0000-4000-8000-000000000002",
        "expectedEntityUpdatedAt":"2026-08-01T00:00:00Z",
        "reason":"계약과 공개 참조 종료를 사람이 확인함"
    })
    .as_object()
    .cloned()
    .unwrap_or_default();
    assert!(validate_control_command(closure.id, &closure_payload));
    Ok(())
}
