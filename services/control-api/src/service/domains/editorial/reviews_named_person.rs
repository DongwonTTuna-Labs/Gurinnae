use gurine_publication_policy::natural_person::{
    LEGAL_OVERRIDE_RECEIPT_VERSION, LegalOverrideReason, LegalOverrideReceiptPreimage,
    legal_override_receipt_sha256,
};

use super::*;

struct NamedIndividualOverride<'a> {
    public_text_sha256: &'a str,
    source_sha256: &'a str,
    locator: &'a str,
    reason: LegalOverrideReason,
    reason_code: &'static str,
    editorial_decision_id: Uuid,
}

#[derive(Debug, Eq, PartialEq)]
struct ReviewStageSelection {
    stage: &'static str,
    capability: &'static str,
    assurance: &'static str,
    referenced_editorial_decision_id: Option<Uuid>,
}

pub(super) async fn record_review_stage(
    operation: &str,
    payload: &Map<String, Value>,
    snapshot_id: Uuid,
    snapshot_created_by: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<OwnerCommandReceipt, ServiceError> {
    let decision = normalized_decision(payload)?;
    let criteria = payload
        .get("criteria")
        .and_then(Value::as_object)
        .ok_or(ServiceError::InvalidRequest)?;
    let selection = review_stage_selection(criteria, decision)?;
    let request = build_review_stage_owner_request(
        payload,
        snapshot_id,
        snapshot_created_by,
        actor,
        decision,
        criteria,
        &selection,
    )?;
    if selection.stage == "LEGAL" {
        record_named_person_override(payload, snapshot_id, decision, actor, tx).await?;
    }
    let result = sqlx::query_scalar!(
        "SELECT editorial.record_named_person_review_stage_v1($1)",
        request,
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?
    .ok_or_else(unexpected_null)?;
    validate_review_stage_owner_result(operation, &result, snapshot_id)
}

fn normalized_decision(payload: &Map<String, Value>) -> Result<&'static str, ServiceError> {
    match string_value(payload, "decision") {
        Some("approve") | Some("APPROVE") => Ok("APPROVE"),
        Some("reject") | Some("REJECT") => Ok("REJECT"),
        Some("changes_required") | Some("CHANGES_REQUIRED") => Ok("CHANGES_REQUIRED"),
        _ => Err(ServiceError::InvalidRequest),
    }
}

fn review_stage_selection(
    criteria: &Map<String, Value>,
    decision: &str,
) -> Result<ReviewStageSelection, ServiceError> {
    let Some(override_value) = criteria.get("namedIndividualOverride") else {
        return Ok(ReviewStageSelection {
            stage: "EDITORIAL",
            capability: "review.editorial",
            assurance: if decision == "APPROVE" {
                "STEP_UP"
            } else {
                "ACTIVE_SESSION"
            },
            referenced_editorial_decision_id: None,
        });
    };
    if decision != "APPROVE" {
        return Err(ServiceError::PreconditionFailed);
    }
    let named_override = parse_named_individual_override(override_value)?;
    Ok(ReviewStageSelection {
        stage: "LEGAL",
        capability: "review.legal",
        assurance: "STEP_UP",
        referenced_editorial_decision_id: Some(named_override.editorial_decision_id),
    })
}

fn build_review_stage_owner_request(
    payload: &Map<String, Value>,
    snapshot_id: Uuid,
    snapshot_created_by: Uuid,
    actor: Uuid,
    decision: &str,
    criteria: &Map<String, Value>,
    selection: &ReviewStageSelection,
) -> Result<Value, ServiceError> {
    let reason = string_value(payload, "reason")
        .filter(|value| value.trim() == *value && (1..=4_000).contains(&value.chars().count()))
        .ok_or(ServiceError::InvalidRequest)?;
    required_internal_capability(payload, "_actorEffectiveCapability", selection.capability)?;
    if string_value(payload, "_actorAssuranceLevel") != Some(selection.assurance) {
        return Err(ServiceError::PreconditionFailed);
    }
    let step_up_authorization_id = optional_internal_uuid(payload, "_actorStepUpAuthorizationId")?;
    if (selection.assurance == "STEP_UP") != step_up_authorization_id.is_some() {
        return Err(ServiceError::PreconditionFailed);
    }
    let actor_assertion_jti = required_internal_uuid(payload, "_actorAssertionJti")?;
    let actor_action_digest = required_internal_sha256(payload, "_actorActionDigest")?;
    let actor_idempotency_key_sha256 =
        required_internal_sha256(payload, "_actorIdempotencyKeySha256")?;
    let actor_request_key_sha256 = required_internal_sha256(payload, "_actorRequestKeySha256")?;
    let request_id = required_internal_uuid(payload, "_requestId")?;
    let idempotency_key_sha256 = required_internal_sha256(payload, "_idempotencyKeySha256")?;
    let request_sha256 = required_internal_sha256(payload, "_requestSha256")?;
    Ok(json!({
        "decisionId":Uuid::new_v4(),
        "reviewSnapshotId":snapshot_id,
        "stage":selection.stage,
        "decision":decision,
        "reason":reason,
        "criteria":criteria,
        "reviewerIndependence":{
            "snapshotCreatedBy":snapshot_created_by,
            "reviewer":actor,
            "independent":true,
        },
        "reauthContextHash":sha256(format!("review:{snapshot_id}:{actor}").as_bytes()),
        "referencedEditorialDecisionId":selection.referenced_editorial_decision_id,
        "_actorId":actor,
        "_actorAssertionJti":actor_assertion_jti,
        "_actorAssuranceLevel":selection.assurance,
        "_actorEffectiveCapability":selection.capability,
        "_actorActionDigest":actor_action_digest,
        "_actorStepUpAuthorizationId":step_up_authorization_id,
        "_actorIdempotencyKeySha256":actor_idempotency_key_sha256,
        "_actorRequestKeySha256":actor_request_key_sha256,
        "_requestId":request_id,
        "_idempotencyKeySha256":idempotency_key_sha256,
        "_requestSha256":request_sha256,
    }))
}

async fn record_named_person_override(
    payload: &Map<String, Value>,
    snapshot_id: Uuid,
    decision: &str,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let criteria = payload
        .get("criteria")
        .and_then(Value::as_object)
        .ok_or(ServiceError::InvalidRequest)?;
    let Some(override_value) = criteria.get("namedIndividualOverride") else {
        return Ok(());
    };
    if decision != "APPROVE"
        || payload.get("_actorAssuranceLevel").and_then(Value::as_str) != Some("STEP_UP")
    {
        return Err(ServiceError::PreconditionFailed);
    }
    let named_override = parse_named_individual_override(override_value)?;
    let assessments = sqlx::query!(
        "SELECT assessment_id AS \"assessment_id!\",ruleset_version AS \"ruleset_version!\" \
         FROM editorial.named_person_publication_assessments \
         WHERE review_snapshot_id=$1 AND guard_context='PREVIEW' AND outcome='BLOCKED' \
           AND finding_count>0 AND public_text_sha256=$2 \
         ORDER BY assessment_id",
        snapshot_id,
        named_override.public_text_sha256,
    )
    .fetch_all(&mut **tx)
    .await
    .map_err(db)?;
    let [assessment] = assessments.as_slice() else {
        return Err(ServiceError::PreconditionFailed);
    };
    let request = build_override_owner_request(
        payload,
        actor,
        assessment.assessment_id,
        &assessment.ruleset_version,
        &named_override,
    )?;
    let result = sqlx::query_scalar!(
        "SELECT editorial.record_named_person_legal_override_v1($1)",
        request,
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?
    .ok_or_else(unexpected_null)?;
    validate_override_owner_result(&result)
}

fn optional_internal_uuid(
    payload: &Map<String, Value>,
    key: &str,
) -> Result<Option<Uuid>, ServiceError> {
    match payload.get(key) {
        Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Uuid::parse_str(value)
            .ok()
            .filter(|value| !value.is_nil())
            .map(Some)
            .ok_or(ServiceError::Persistence),
        _ => Err(ServiceError::Persistence),
    }
}

fn parse_named_individual_override(
    override_value: &Value,
) -> Result<NamedIndividualOverride<'_>, ServiceError> {
    let fields = override_value
        .as_object()
        .filter(|value| value.len() == 5)
        .ok_or(ServiceError::InvalidRequest)?;
    for key in [
        "publicTextSha256",
        "reasonCode",
        "officialSourceLocator",
        "officialSourceSha256",
        "editorialReviewDecisionId",
    ] {
        if !fields.contains_key(key) {
            return Err(ServiceError::InvalidRequest);
        }
    }
    let locator = fields
        .get("officialSourceLocator")
        .and_then(Value::as_str)
        .filter(|value| value.trim() == *value && (1..=2_048).contains(&value.chars().count()))
        .ok_or(ServiceError::InvalidRequest)?;
    let (reason, reason_code) = match fields.get("reasonCode").and_then(Value::as_str) {
        Some("PUBLIC_FIGURE") => (LegalOverrideReason::PublicFigure, "PUBLIC_FIGURE"),
        Some("OFFICIAL_DISPOSITION_QUOTE") => (
            LegalOverrideReason::OfficialDispositionQuote,
            "OFFICIAL_DISPOSITION_QUOTE",
        ),
        _ => return Err(ServiceError::InvalidRequest),
    };
    Ok(NamedIndividualOverride {
        public_text_sha256: required_sha256(fields, "publicTextSha256")?,
        source_sha256: required_sha256(fields, "officialSourceSha256")?,
        locator,
        reason,
        reason_code,
        editorial_decision_id: required_uuid(fields, "editorialReviewDecisionId")?,
    })
}

fn build_override_owner_request(
    payload: &Map<String, Value>,
    actor: Uuid,
    assessment_id: Uuid,
    ruleset_version: &str,
    named_override: &NamedIndividualOverride<'_>,
) -> Result<Value, ServiceError> {
    let reviewer_id = actor.to_string();
    let receipt_sha256 = legal_override_receipt_sha256(&LegalOverrideReceiptPreimage {
        public_text_sha256: named_override.public_text_sha256,
        ruleset_version,
        reason: named_override.reason,
        official_source_locator: named_override.locator,
        official_source_sha256: named_override.source_sha256,
        legal_reviewer_id: &reviewer_id,
    });
    let legal_override = json!({
        "receiptVersion":LEGAL_OVERRIDE_RECEIPT_VERSION,
        "publicTextSha256":named_override.public_text_sha256,
        "rulesetVersion":ruleset_version,
        "reasonCode":named_override.reason_code,
        "officialSourceLocator":named_override.locator,
        "officialSourceSha256":named_override.source_sha256,
        "legalReviewerId":actor,
        "receiptSha256":receipt_sha256,
        "editorialReviewDecisionId":named_override.editorial_decision_id,
    });
    Ok(json!({
        "assessmentId":assessment_id,
        "legalOverride":legal_override,
        "_actorId":actor,
        "_actorAssertionJti":required_internal_uuid(payload,"_actorAssertionJti")?,
        "_actorAssuranceLevel":"STEP_UP",
        "_actorEffectiveCapability":required_internal_capability(
            payload,"_actorEffectiveCapability","review.legal"
        )?,
        "_actorActionDigest":required_internal_sha256(payload,"_actorActionDigest")?,
        "_actorStepUpAuthorizationId":required_internal_uuid(
            payload,"_actorStepUpAuthorizationId"
        )?,
        "_actorIdempotencyKeySha256":required_internal_sha256(
            payload,"_actorIdempotencyKeySha256"
        )?,
        "_actorRequestKeySha256":required_internal_sha256(
            payload,"_actorRequestKeySha256"
        )?,
        "_requestId":required_internal_uuid(payload,"_requestId")?,
        "_idempotencyKeySha256":required_internal_sha256(
            payload,"_idempotencyKeySha256"
        )?,
        "_requestSha256":required_internal_sha256(payload,"_requestSha256")?,
    }))
}

fn required_uuid(fields: &Map<String, Value>, key: &str) -> Result<Uuid, ServiceError> {
    fields
        .get(key)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .filter(|value| !value.is_nil())
        .ok_or(ServiceError::InvalidRequest)
}

fn required_sha256<'a>(fields: &'a Map<String, Value>, key: &str) -> Result<&'a str, ServiceError> {
    fields
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| is_sha256(value))
        .ok_or(ServiceError::InvalidRequest)
}

fn required_internal_uuid(payload: &Map<String, Value>, key: &str) -> Result<Uuid, ServiceError> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .filter(|value| !value.is_nil())
        .ok_or(ServiceError::Persistence)
}

fn required_internal_sha256<'a>(
    payload: &'a Map<String, Value>,
    key: &str,
) -> Result<&'a str, ServiceError> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| is_sha256(value))
        .ok_or(ServiceError::Persistence)
}

fn required_internal_capability<'a>(
    payload: &'a Map<String, Value>,
    key: &str,
    expected: &str,
) -> Result<&'a str, ServiceError> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| *value == expected)
        .ok_or(ServiceError::Persistence)
}

fn validate_review_stage_owner_result(
    operation: &str,
    result: &Value,
    snapshot_id: Uuid,
) -> Result<OwnerCommandReceipt, ServiceError> {
    owner_result_has_exact_keys(
        result,
        &[
            "decisionId",
            "reviewSnapshotId",
            "aggregateVersion",
            "reviewStageReceiptId",
            "reviewStageReceiptDigest",
            "auditEventId",
            "acceptedAt",
            "outboxEventIds",
            "replayed",
        ],
    )?;
    let fields = result.as_object().ok_or(ServiceError::Persistence)?;
    required_owner_uuid(fields, "decisionId")?;
    if required_owner_uuid(fields, "reviewSnapshotId")? != snapshot_id {
        return Err(ServiceError::Persistence);
    }
    required_owner_uuid(fields, "reviewStageReceiptId")?;
    let aggregate_version = fields
        .get("aggregateVersion")
        .and_then(Value::as_i64)
        .filter(|value| *value >= 1)
        .ok_or(ServiceError::Persistence)?;
    let receipt_digest = fields
        .get("reviewStageReceiptDigest")
        .and_then(Value::as_str)
        .filter(|value| is_sha256(value))
        .ok_or(ServiceError::Persistence)?
        .to_owned();
    let audit_event_id = required_owner_uuid(fields, "auditEventId")?;
    let accepted_at = fields
        .get("acceptedAt")
        .and_then(Value::as_str)
        .filter(|value| OffsetDateTime::parse(value, &Rfc3339).is_ok())
        .ok_or(ServiceError::Persistence)?
        .to_owned();
    let expected_outbox_count = owner_outbox_cardinality(operation)?;
    let outbox_event_ids = fields
        .get("outboxEventIds")
        .and_then(Value::as_array)
        .filter(|values| values.len() == expected_outbox_count)
        .ok_or(ServiceError::Persistence)?
        .iter()
        .map(|value| {
            value
                .as_str()
                .and_then(|value| Uuid::parse_str(value).ok())
                .filter(|value| !value.is_nil())
                .ok_or(ServiceError::Persistence)
        })
        .collect::<Result<Vec<_>, _>>()?;
    if !fields.get("replayed").is_some_and(Value::is_boolean) {
        return Err(ServiceError::Persistence);
    }
    Ok(OwnerCommandReceipt {
        aggregate_id: snapshot_id,
        aggregate_version,
        audit_event_id,
        receipt_digest,
        accepted_at,
        outbox_event_ids,
        expected_outbox_count,
        response_fields: Map::new(),
    })
}

fn validate_override_owner_result(result: &Value) -> Result<(), ServiceError> {
    owner_result_has_exact_keys(
        result,
        &[
            "overrideId",
            "overrideReceiptDigest",
            "overrideAuditEventId",
            "replayed",
        ],
    )?;
    let fields = result.as_object().ok_or(ServiceError::Persistence)?;
    required_owner_uuid(fields, "overrideId")?;
    required_owner_uuid(fields, "overrideAuditEventId")?;
    fields
        .get("overrideReceiptDigest")
        .and_then(Value::as_str)
        .filter(|value| is_sha256(value))
        .ok_or(ServiceError::Persistence)?;
    if !fields.get("replayed").is_some_and(Value::is_boolean) {
        return Err(ServiceError::Persistence);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn legal_override() -> Value {
        json!({
            "publicTextSha256":
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "reasonCode":"PUBLIC_FIGURE",
            "officialSourceLocator":"https://example.test/official",
            "officialSourceSha256":
                "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "editorialReviewDecisionId":"10000000-0000-4000-8000-000000000001",
        })
    }

    #[test]
    fn review_stage_selects_capability_and_assurance_independently() -> Result<(), ServiceError> {
        let editorial_approve = review_stage_selection(&Map::new(), "APPROVE")?;
        assert_eq!(
            editorial_approve,
            ReviewStageSelection {
                stage: "EDITORIAL",
                capability: "review.editorial",
                assurance: "STEP_UP",
                referenced_editorial_decision_id: None,
            }
        );
        let editorial_reject = review_stage_selection(&Map::new(), "REJECT")?;
        assert_eq!(editorial_reject.assurance, "ACTIVE_SESSION");

        let mut legal_criteria = Map::new();
        legal_criteria.insert("namedIndividualOverride".to_owned(), legal_override());
        let legal_approve = review_stage_selection(&legal_criteria, "APPROVE")?;
        assert_eq!(legal_approve.stage, "LEGAL");
        assert_eq!(legal_approve.capability, "review.legal");
        assert_eq!(legal_approve.assurance, "STEP_UP");
        assert!(matches!(
            review_stage_selection(&legal_criteria, "REJECT"),
            Err(ServiceError::PreconditionFailed)
        ));
        Ok(())
    }

    #[test]
    fn browser_cannot_supply_named_person_findings() {
        let mut override_value = legal_override();
        if let Some(fields) = override_value.as_object_mut() {
            fields.insert("findings".to_owned(), json!([{"candidate":"홍길동"}]));
        }
        assert!(matches!(
            parse_named_individual_override(&override_value),
            Err(ServiceError::InvalidRequest)
        ));
    }

    #[test]
    fn review_stage_owner_result_is_closed_and_enforces_outbox_cardinality()
    -> Result<(), ServiceError> {
        let snapshot_id = Uuid::parse_str("40000000-0000-4000-8000-000000000001")
            .map_err(|_| ServiceError::Persistence)?;
        let valid = json!({
            "decisionId":"40000000-0000-4000-8000-000000000002",
            "reviewSnapshotId":snapshot_id,
            "aggregateVersion":7,
            "reviewStageReceiptId":"40000000-0000-4000-8000-000000000003",
            "reviewStageReceiptDigest":
                "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
            "auditEventId":"40000000-0000-4000-8000-000000000004",
            "acceptedAt":"2026-08-01T00:00:00Z",
            "outboxEventIds":["40000000-0000-4000-8000-000000000005"],
            "replayed":false,
        });
        let receipt = validate_review_stage_owner_result("submitReview", &valid, snapshot_id)?;
        assert_eq!(receipt.aggregate_id, snapshot_id);
        assert_eq!(receipt.aggregate_version, 7);
        assert_eq!(receipt.expected_outbox_count, 1);

        let mut missing_outbox = valid.clone();
        missing_outbox["outboxEventIds"] = json!([]);
        assert!(matches!(
            validate_review_stage_owner_result("submitReview", &missing_outbox, snapshot_id),
            Err(ServiceError::Persistence)
        ));
        let mut extra_key = valid;
        extra_key["findings"] = json!([]);
        assert!(matches!(
            validate_review_stage_owner_result("submitReview", &extra_key, snapshot_id),
            Err(ServiceError::Persistence)
        ));
        Ok(())
    }

    #[test]
    fn override_owner_result_is_closed_and_requires_immutable_proofs() {
        let valid = json!({
            "overrideId":"10000000-0000-4000-8000-000000000001",
            "overrideReceiptDigest":
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "overrideAuditEventId":"10000000-0000-4000-8000-000000000002",
            "replayed":false,
        });
        assert!(validate_override_owner_result(&valid).is_ok());
        let mut missing = valid;
        missing["overrideReceiptDigest"] = Value::Null;
        assert!(matches!(
            validate_override_owner_result(&missing),
            Err(ServiceError::Persistence)
        ));
    }
}
