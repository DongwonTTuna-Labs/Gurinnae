use super::*;

#[path = "specialized_group_1_suggestion.rs"]
mod suggestion;
pub(super) use suggestion::arm_acceptagentsuggestion_rejectagentsuggestion;

pub(super) async fn arm_activateruleversion_scheduleruleactivation(
    operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    _actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let version = uuid_value(payload, &["ruleVersionId"]).ok_or(ServiceError::InvalidRequest)?;
    let digest = string_value(payload, "evaluationDigest")
        .filter(|value| is_sha256(value))
        .ok_or(ServiceError::InvalidRequest)?;
    let evaluated: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM core.rule_evaluations WHERE rule_version_id=$1 \
         AND status='SUCCEEDED' AND result_digest=$2)",
    )
    .bind(version)
    .bind(digest)
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?;
    if !evaluated {
        return Err(ServiceError::InvalidRequest);
    }
    let effective_at =
        timestamp_value(payload, "effectiveAt")?.ok_or(ServiceError::InvalidRequest)?;
    let rollout = if operation == "scheduleRuleActivation" {
        Some(string_value(payload, "rollout").ok_or(ServiceError::InvalidRequest)?)
    } else {
        Some("ALL")
    };
    if operation == "activateRuleVersion" && effective_at > OffsetDateTime::now_utc() {
        return Err(ServiceError::InvalidRequest);
    }
    if operation == "activateRuleVersion" {
        sqlx::query(
            "UPDATE core.rule_versions SET status='RETIRED',retired_at=clock_timestamp() \
             WHERE rule_id=(SELECT rule_id FROM core.rule_versions WHERE id=$1) \
               AND status='ACTIVE' AND id<>$1",
        )
        .bind(version)
        .execute(&mut **tx)
        .await
        .map_err(db)?;
    }
    let status = if operation == "activateRuleVersion" {
        "ACTIVE"
    } else {
        "SCHEDULED"
    };
    let changed = sqlx::query(
        "UPDATE core.rule_versions SET status=$2,effective_at=$3, \
         activation_evaluation_digest=$4,activation_rollout=$5,activation_reason=$6 \
         WHERE id=$1 AND status IN ('DRAFT','SHADOW','SCHEDULED')",
    )
    .bind(version)
    .bind(status)
    .bind(effective_at)
    .bind(digest)
    .bind(rollout)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::VersionConflict);
    }

    Ok(())
}

pub(super) async fn arm_addclaim(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
    sqlx::query(
        "INSERT INTO editorial.claims(id,case_id,claim_type,text,limitations, \
         validation_status,created_by) VALUES($1,$2,$3::editorial.claim_type,$4,$5,'DRAFT',$6)",
    )
    .bind(id)
    .bind(case_id)
    .bind(string_value(payload, "claimType").ok_or(ServiceError::InvalidRequest)?)
    .bind(string_value(payload, "text").ok_or(ServiceError::InvalidRequest)?)
    .bind(
        payload
            .get("limitations")
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?,
    )
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    replace_claim_relations(id, payload, tx).await?;

    Ok(())
}

pub(super) async fn arm_addevidence(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
    sqlx::query(
        "INSERT INTO editorial.evidence(id,case_id,evidence_type,title,source_document_id, \
         source_url,source_locator,content_sha256,classification,verification_status, \
         description,created_by) VALUES($1,$2,$3,$4,$5,$6,$7,$8, \
         $9::editorial.evidence_classification,'PENDING',$10,$11)",
    )
    .bind(id)
    .bind(case_id)
    .bind(string_value(payload, "evidenceType").ok_or(ServiceError::InvalidRequest)?)
    .bind(string_value(payload, "title").ok_or(ServiceError::InvalidRequest)?)
    .bind(uuid_value(payload, &["sourceDocumentId"]))
    .bind(payload.get("sourceUrl").and_then(Value::as_str))
    .bind(string_value(payload, "locator").ok_or(ServiceError::InvalidRequest)?)
    .bind(string_value(payload, "contentHash").ok_or(ServiceError::InvalidRequest)?)
    .bind(string_value(payload, "classification").ok_or(ServiceError::InvalidRequest)?)
    .bind(payload.get("notes").and_then(Value::as_str))
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_assigncorrection(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let correction = uuid_value(payload, &["correctionId"]).ok_or(ServiceError::InvalidRequest)?;
    let assignee = uuid_value(payload, &["assigneeUserId"]).ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query("UPDATE editorial.corrections SET assigned_user_id=$2 WHERE id=$1")
        .bind(correction)
        .bind(assignee)
        .execute(&mut **tx)
        .await
        .map_err(db)?
        .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }
    upsert_task(
        tx,
        "CORRECTION",
        correction,
        "Correction review",
        "OPEN",
        "HIGH",
        Some(assignee),
        actor,
        None,
    )
    .await?;

    Ok(())
}

pub(super) async fn arm_assignreview(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
    let snapshot = uuid_value(payload, &["reviewSnapshotId"]);
    let reviewer = uuid_value(payload, &["assigneeUserId"]).ok_or(ServiceError::InvalidRequest)?;
    let assignment_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO editorial.review_assignments(id,case_id,review_snapshot_id,reviewer_id, \
         status,assigned_by,assigned_at,due_at) \
         VALUES($1,$2,$3,$4,'ASSIGNED',$5,clock_timestamp(),$6) \
         ON CONFLICT(case_id,review_snapshot_id,reviewer_id) DO UPDATE SET \
         status='ASSIGNED',assigned_by=EXCLUDED.assigned_by,assigned_at=clock_timestamp(), \
         due_at=EXCLUDED.due_at,completed_at=NULL,version=editorial.review_assignments.version+1",
    )
    .bind(assignment_id)
    .bind(case_id)
    .bind(snapshot)
    .bind(reviewer)
    .bind(actor)
    .bind(timestamp_value(payload, "dueAt")?)
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    upsert_task(
        tx,
        "REVIEW",
        snapshot.unwrap_or(case_id),
        "Editorial review",
        "OPEN",
        "HIGH",
        Some(reviewer),
        actor,
        None,
    )
    .await?;

    Ok(())
}

pub(super) async fn arm_createresponserequest(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
    let email = normalized_email(
        string_value(payload, "recipientEmail").ok_or(ServiceError::InvalidRequest)?,
    )?;
    let encrypted = encrypt_control_field(
        field_keys,
        "editorial.response_requests",
        "recipient_email_encrypted",
        id,
        "email-address",
        email.as_bytes(),
    )?;
    sqlx::query(
        "INSERT INTO editorial.response_requests(id,case_id,party_type,party_name, \
         recipient_email_hash,recipient_email_encrypted,questions, \
         requested_publication_scope,due_at,status,created_by) \
         VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,'DRAFT',$10)",
    )
    .bind(id)
    .bind(case_id)
    .bind(string_value(payload, "partyType").ok_or(ServiceError::InvalidRequest)?)
    .bind(string_value(payload, "partyName").ok_or(ServiceError::InvalidRequest)?)
    .bind(sha256(email.as_bytes()))
    .bind(encrypted)
    .bind(
        payload
            .get("questions")
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?,
    )
    .bind(
        payload
            .get("requestedPublicationScope")
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?,
    )
    .bind(timestamp_value(payload, "dueAt")?.ok_or(ServiceError::InvalidRequest)?)
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_createruleversiondraft(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let rule_id = string_value(payload, "ruleId").ok_or(ServiceError::InvalidRequest)?;
    let version = payload
        .get("baseVersion")
        .and_then(Value::as_str)
        .map_or_else(
            || format!("draft-{}", id.simple()),
            |base| format!("{base}-draft-{}", id.simple()),
        );
    sqlx::query(
        "INSERT INTO core.rule_versions(id,rule_id,version,name,description,configuration, \
         code_digest,status,created_by) VALUES($1,$2,$3,$4,$5,$6,$7,'DRAFT',$8)",
    )
    .bind(id)
    .bind(rule_id)
    .bind(version)
    .bind(string_value(payload, "name").ok_or(ServiceError::InvalidRequest)?)
    .bind(string_value(payload, "description").ok_or(ServiceError::InvalidRequest)?)
    .bind(
        payload
            .get("configuration")
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?,
    )
    .bind(
        string_value(payload, "implementationDigest")
            .filter(|value| is_sha256(value))
            .ok_or(ServiceError::InvalidRequest)?,
    )
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_createcorrection(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let publication =
        uuid_value(payload, &["publicationId"]).ok_or(ServiceError::InvalidRequest)?;
    let row =
        sqlx::query("SELECT case_id,revision FROM editorial.publication_revisions WHERE id=$1")
            .bind(publication)
            .fetch_optional(&mut **tx)
            .await
            .map_err(db)?
            .ok_or(ServiceError::NotFound)?;
    sqlx::query(
        "INSERT INTO editorial.corrections(id,case_id,source_revision,summary,reason, \
         affected_claim_ids,replacement_content,status,created_by) \
         VALUES($1,$2,$3,$4,$5,$6,$7,'DRAFT',$8)",
    )
    .bind(id)
    .bind(row.try_get::<Uuid, _>("case_id").map_err(db)?)
    .bind(row.try_get::<i32, _>("revision").map_err(db)?)
    .bind(string_value(payload, "summary").ok_or(ServiceError::InvalidRequest)?)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .bind(
        payload
            .get("affectedClaimIds")
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?,
    )
    .bind(
        payload
            .get("replacementContent")
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?,
    )
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_createevidenceredaction(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let evidence = uuid_value(payload, &["evidenceId"]).ok_or(ServiceError::InvalidRequest)?;
    sqlx::query(
        "INSERT INTO editorial.evidence_redactions(id,evidence_id,ranges,redaction_type, \
         reason,replacement_text,status,created_by) VALUES($1,$2,$3,$4,$5,$6,'DRAFT',$7)",
    )
    .bind(id)
    .bind(evidence)
    .bind(
        payload
            .get("ranges")
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?,
    )
    .bind(string_value(payload, "redactionType").ok_or(ServiceError::InvalidRequest)?)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .bind(payload.get("replacementText").and_then(Value::as_str))
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_createhypothesis(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
    sqlx::query(
        "INSERT INTO editorial.hypotheses(id,case_id,statement,status,unknowns,created_by) \
         VALUES($1,$2,$3,'OPEN',$4,$5)",
    )
    .bind(id)
    .bind(case_id)
    .bind(string_value(payload, "statement").ok_or(ServiceError::InvalidRequest)?)
    .bind(
        payload
            .get("unknowns")
            .cloned()
            .unwrap_or_else(|| json!([])),
    )
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    replace_hypothesis_relations(id, payload, actor, tx).await?;

    Ok(())
}
pub(super) async fn apply_specialized_group_1(
    operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    session_id: Uuid,
    field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    match operation {
        "acceptAgentSuggestion" | "rejectAgentSuggestion" => {
            arm_acceptagentsuggestion_rejectagentsuggestion(
                operation, payload, id, actor, session_id, field_keys, tx,
            )
            .await?
        }
        "activateRuleVersion" | "scheduleRuleActivation" => {
            arm_activateruleversion_scheduleruleactivation(
                operation, payload, id, actor, session_id, field_keys, tx,
            )
            .await?
        }
        "addClaim" => {
            arm_addclaim(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "addEvidence" => {
            arm_addevidence(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "assignCorrection" => {
            arm_assigncorrection(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "assignReview" => {
            arm_assignreview(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "createResponseRequest" => {
            arm_createresponserequest(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        "createRuleVersionDraft" => {
            arm_createruleversiondraft(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        "createCorrection" => {
            arm_createcorrection(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "createEvidenceRedaction" => {
            arm_createevidenceredaction(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        "createHypothesis" => {
            arm_createhypothesis(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        _ => return Err(ServiceError::InvalidRequest),
    }
    Ok(())
}
