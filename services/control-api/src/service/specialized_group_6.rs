use super::*;

pub(super) async fn arm_unlinksignalfromcase(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    _actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
    let signal = uuid_value(payload, &["signalId"]).ok_or(ServiceError::InvalidRequest)?;
    let changed =
        sqlx::query("DELETE FROM editorial.case_signals WHERE case_id=$1 AND signal_id=$2")
            .bind(case_id)
            .bind(signal)
            .execute(&mut **tx)
            .await
            .map_err(db)?
            .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }
    sqlx::query(
        "UPDATE core.anomaly_signals SET status= \
         CASE WHEN assigned_user_id IS NULL THEN 'NEW'::core.signal_status \
              ELSE 'ASSIGNED'::core.signal_status END WHERE id=$1",
    )
    .bind(signal)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_updatebudgetlimit(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let scope = string_value(payload, "scope").ok_or(ServiceError::InvalidRequest)?;
    let daily = decimal_string(payload, "dailyLimit")?;
    let monthly = decimal_string(payload, "monthlyLimit")?;
    if daily < rust_decimal::Decimal::ZERO || monthly < daily {
        return Err(ServiceError::InvalidRequest);
    }
    let changed = sqlx::query(
        "UPDATE ops.budget_limits SET daily_limit=$2,monthly_limit=$3,currency=$4, \
         updated_by=$5,updated_at=clock_timestamp() WHERE scope=$1",
    )
    .bind(scope)
    .bind(daily)
    .bind(monthly)
    .bind(string_value(payload, "currency").ok_or(ServiceError::InvalidRequest)?)
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }

    Ok(())
}

pub(super) async fn arm_updateclaim(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    _actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let claim = uuid_value(payload, &["claimId"]).ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query(
        "UPDATE editorial.claims SET text=COALESCE($2,text),limitations=COALESCE($3,limitations) \
         WHERE id=$1",
    )
    .bind(claim)
    .bind(payload.get("text").and_then(Value::as_str))
    .bind(payload.get("limitations").cloned())
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }
    if payload.contains_key("evidenceIds") || payload.contains_key("responseIds") {
        replace_claim_relations(claim, payload, tx).await?;
    }

    Ok(())
}

pub(super) async fn arm_updatecorrectiondraft(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    _actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let correction = uuid_value(payload, &["correctionId"]).ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query(
        "UPDATE editorial.corrections SET summary=COALESCE($2,summary),reason=COALESCE($3,reason), \
         affected_claim_ids=COALESCE($4,affected_claim_ids), \
         replacement_content=COALESCE($5,replacement_content) \
         WHERE id=$1 AND status='DRAFT'",
    )
    .bind(correction)
    .bind(payload.get("summary").and_then(Value::as_str))
    .bind(payload.get("reason").and_then(Value::as_str))
    .bind(payload.get("affectedClaimIds").cloned())
    .bind(payload.get("replacementContent").cloned())
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }

    Ok(())
}

pub(super) async fn arm_updateevidence(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    _actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let evidence = uuid_value(payload, &["evidenceId"]).ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query(
        "UPDATE editorial.evidence SET title=COALESCE($2,title), \
         source_locator=COALESCE($3,source_locator), \
         classification=COALESCE($4::editorial.evidence_classification,classification), \
         description=COALESCE($5,description) WHERE id=$1",
    )
    .bind(evidence)
    .bind(payload.get("title").and_then(Value::as_str))
    .bind(payload.get("locator").and_then(Value::as_str))
    .bind(payload.get("classification").and_then(Value::as_str))
    .bind(payload.get("notes").and_then(Value::as_str))
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }

    Ok(())
}

pub(super) async fn arm_updatehypothesis(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let hypothesis = uuid_value(payload, &["hypothesisId"]).ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query(
        "UPDATE editorial.hypotheses SET statement=COALESCE($2,statement), \
         status=COALESCE($3,status),unknowns=COALESCE($4,unknowns) WHERE id=$1",
    )
    .bind(hypothesis)
    .bind(payload.get("statement").and_then(Value::as_str))
    .bind(payload.get("status").and_then(Value::as_str))
    .bind(payload.get("unknowns").cloned())
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }
    if payload.contains_key("supportingEvidenceIds")
        || payload.contains_key("contradictingEvidenceIds")
    {
        replace_hypothesis_relations(hypothesis, payload, actor, tx).await?;
    }

    Ok(())
}

pub(super) async fn arm_validateclaims(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    _actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let claim = uuid_value(payload, &["claimId"]).ok_or(ServiceError::InvalidRequest)?;
    let blockers: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM editorial.claim_evidence ce \
         JOIN editorial.evidence e ON e.id=ce.evidence_id \
         WHERE ce.claim_id=$1 AND e.verification_status<>'VERIFIED'",
    )
    .bind(claim)
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?;
    let status = if blockers == 0 { "VALID" } else { "BLOCKED" };
    let changed = sqlx::query("UPDATE editorial.claims SET validation_status=$2::core.claim_validation_status WHERE id=$1")
        .bind(claim).bind(status).execute(&mut **tx).await.map_err(db)?.rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }

    Ok(())
}

pub(super) async fn arm_verifyauditintegrity(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let mode = string_value(payload, "mode").ok_or(ServiceError::InvalidRequest)?;
    let from = uuid_value(payload, &["fromEventId"]);
    let to = uuid_value(payload, &["toEventId"]);
    let expected = payload.get("expectedChainHead").and_then(Value::as_str);
    match mode {
        "FULL" | "TAIL" if from.is_none() && to.is_none() => {}
        "RANGE" if from.is_some() && to.is_some() => {}
        _ => return Err(ServiceError::InvalidRequest),
    }
    if expected.is_some_and(|value| !is_sha256(value)) {
        return Err(ServiceError::InvalidRequest);
    }
    sqlx::query(
        "INSERT INTO ops.audit_verification_runs(id,mode,from_event_id,to_event_id, \
         expected_chain_head,status,requested_by) VALUES($1,$2,$3,$4,$5,'QUEUED',$6)",
    )
    .bind(id)
    .bind(mode)
    .bind(from)
    .bind(to)
    .bind(expected)
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_verifyevidence(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let evidence = uuid_value(payload, &["evidenceId"]).ok_or(ServiceError::InvalidRequest)?;
    let requested =
        string_value(payload, "verificationStatus").ok_or(ServiceError::InvalidRequest)?;
    let status = match requested {
        "verified" | "VERIFIED" => "VERIFIED",
        "rejected" | "REJECTED" => "REJECTED",
        "needs_work" | "NEEDS_WORK" => "NEEDS_WORK",
        _ => return Err(ServiceError::InvalidRequest),
    };
    let changed = sqlx::query(
        "UPDATE editorial.evidence SET verification_status=$2,verified_by=$3, \
         verified_at=CASE WHEN $2='VERIFIED' THEN clock_timestamp() ELSE NULL END WHERE id=$1",
    )
    .bind(evidence)
    .bind(status)
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }

    Ok(())
}

pub(super) async fn arm_createauditexport(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let seconds = payload
        .get("expiresInSeconds")
        .and_then(Value::as_i64)
        .filter(|value| (300..=86_400).contains(value))
        .ok_or(ServiceError::InvalidRequest)?;
    let expires_at = OffsetDateTime::now_utc()
        .checked_add(time::Duration::seconds(seconds))
        .ok_or(ServiceError::InvalidRequest)?;
    sqlx::query(
        "INSERT INTO ops.audit_exports(id,requested_by,from_at,to_at,format,scope,object_type,object_id,reason,watermark_policy,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)",
    )
    .bind(id)
    .bind(actor)
    .bind(timestamp_value(payload, "from")?.ok_or(ServiceError::InvalidRequest)?)
    .bind(timestamp_value(payload, "to")?.ok_or(ServiceError::InvalidRequest)?)
    .bind(string_value(payload, "format").ok_or(ServiceError::InvalidRequest)?)
    .bind(string_value(payload, "scope").ok_or(ServiceError::InvalidRequest)?)
    .bind(payload.get("objectType").and_then(Value::as_str))
    .bind(payload.get("objectId").and_then(Value::as_str))
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .bind(string_value(payload, "watermarkPolicy").ok_or(ServiceError::InvalidRequest)?)
    .bind(expires_at)
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    sqlx::query(
        "INSERT INTO ops.jobs(job_type,queue,payload,dedupe_key) VALUES('AUDIT_EXPORT','audit-export',$1,$2)",
    )
    .bind(json!({"auditExportId":id}))
    .bind(format!("audit-export:{id}"))
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_placelegalhold(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    sqlx::query(
        "INSERT INTO editorial.legal_holds(id,case_id,review_snapshot_id,object_type,object_id,scope,affected_ids,reason,authority_reference,expires_at,placed_by) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)",
    )
    .bind(id)
    .bind(uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?)
    .bind(uuid_value(payload, &["reviewSnapshotId"]).ok_or(ServiceError::InvalidRequest)?)
    .bind(string_value(payload, "objectType").ok_or(ServiceError::InvalidRequest)?)
    .bind(uuid_value(payload, &["objectId"]).ok_or(ServiceError::InvalidRequest)?)
    .bind(string_value(payload, "scope").ok_or(ServiceError::InvalidRequest)?)
    .bind(payload.get("affectedIds").cloned().unwrap_or_else(|| json!([])))
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .bind(string_value(payload, "authorityReference").ok_or(ServiceError::InvalidRequest)?)
    .bind(timestamp_value(payload, "expiresAt")?)
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_activatekillswitch(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let changed = sqlx::query("UPDATE ops.kill_switches SET scope=$2,state='ACTIVE',reason=$3,activated_by=$4,activated_at=clock_timestamp(),expires_at=$5,deactivated_by=NULL,deactivated_at=NULL,updated_at=clock_timestamp() WHERE id=$1")
        .bind(id).bind(payload.get("scope").cloned().ok_or(ServiceError::InvalidRequest)?)
        .bind(string_value(payload,"reason").ok_or(ServiceError::InvalidRequest)?)
        .bind(actor).bind(timestamp_value(payload,"expiresAt")?)
        .execute(&mut **tx).await.map_err(db)?.rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }

    Ok(())
}

pub(super) async fn arm_deactivatekillswitch(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    if let Some(target) = uuid_value(payload, &["killSwitchId", "id"]) {
        let changed=sqlx::query("UPDATE ops.kill_switches SET state='INACTIVE',deactivated_by=$2,deactivated_at=clock_timestamp(),updated_at=clock_timestamp() WHERE id=$1 AND state='ACTIVE'").bind(target).bind(actor).execute(&mut **tx).await.map_err(db)?.rows_affected();
        if changed == 0 {
            return Err(ServiceError::NotFound);
        }
    }

    Ok(())
}

pub(super) async fn arm_extendkillswitch(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    _actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let target =
        uuid_value(payload, &["killSwitchId", "id"]).ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query(
        "UPDATE ops.kill_switches SET expires_at= \
         GREATEST(COALESCE(expires_at,clock_timestamp()),clock_timestamp())+interval '1 hour', \
         updated_at=clock_timestamp() WHERE id=$1 AND state='ACTIVE'",
    )
    .bind(target)
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed == 0 {
        return Err(ServiceError::NotFound);
    }

    Ok(())
}

pub(super) async fn arm_marknotificationread(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    _actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    if let Some(target) = uuid_value(payload, &["notificationId", "id"]) {
        sqlx::query(
            "UPDATE ops.notifications SET read_at=COALESCE(read_at,clock_timestamp()) WHERE id=$1",
        )
        .bind(target)
        .execute(&mut **tx)
        .await
        .map_err(db)?;
    }

    Ok(())
}
pub(super) async fn apply_specialized_group_6(
    operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    session_id: Uuid,
    field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    match operation {
        "unlinkSignalFromCase" => {
            arm_unlinksignalfromcase(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        "updateBudgetLimit" => {
            arm_updatebudgetlimit(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "updateClaim" => {
            arm_updateclaim(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "updateCorrectionDraft" => {
            arm_updatecorrectiondraft(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        "updateEvidence" => {
            arm_updateevidence(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "updateHypothesis" => {
            arm_updatehypothesis(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "validateClaims" => {
            arm_validateclaims(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "verifyAuditIntegrity" => {
            arm_verifyauditintegrity(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        "verifyEvidence" => {
            arm_verifyevidence(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "createAuditExport" => {
            arm_createauditexport(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "placeLegalHold" => {
            arm_placelegalhold(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "activateKillSwitch" => {
            arm_activatekillswitch(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        "deactivateKillSwitch" => {
            arm_deactivatekillswitch(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        "extendKillSwitch" => {
            arm_extendkillswitch(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "markNotificationRead" => {
            arm_marknotificationread(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        _ => return Err(ServiceError::InvalidRequest),
    }
    Ok(())
}
