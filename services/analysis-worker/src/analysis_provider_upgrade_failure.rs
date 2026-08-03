async fn reconcile_relay_upgrade_failure(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    job: &ClaimedJob,
    code: &str,
) -> Result<(), JobError> {
    let Some(attempt_id) = job
        .payload
        .get("providerModelUpgradeAttemptId")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
    else {
        return Ok(());
    };
    let Some(row) = sqlx::query!(
        "SELECT a.provider_id,a.target_model_id,a.attempt_kind,a.owner_user_id, \
           a.expected_provider_version,a.connection_test_id,a.gateway_receipt_sha256::text AS gateway_receipt_sha256, \
           a.usage_evidence_sha256::text AS usage_evidence_sha256,a.status, \
           p.version AS provider_version,p.routing_policy \
         FROM ops.provider_model_upgrade_attempts a \
         JOIN ops.provider_configs p ON p.id=a.provider_id WHERE a.id=$1 FOR UPDATE OF a,p",
        attempt_id,
    )
    .fetch_optional(&mut **tx)
    .await
    .map_err(JobError::Database)?
    else {
        return Ok(());
    };
    if matches!(row.status.as_str(), "SUCCEEDED" | "FAILED" | "SUPPRESSED") {
        return Ok(());
    }
    let completed_at = OffsetDateTime::now_utc();
    mark_relay_upgrade_attempt_failed(tx, attempt_id, code, completed_at).await?;
    reconcile_relay_connection_test_failure(
        tx,
        row.provider_id,
        row.connection_test_id,
        code,
        completed_at,
    )
    .await?;
    let before_model = row
        .routing_policy
        .get("model")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let evidence = json!({
        "attemptId":attempt_id,
        "errorCode":code,
        "providerId":row.provider_id,
        "providerVersion":row.provider_version,
        "targetModelId":row.target_model_id,
    });
    let evidence_sha256 = sha256(
        &canonical_bytes(&evidence).map_err(relay_failure_job_error)?,
    );
    let events = relay_upgrade_failure_events(
        tx,
        attempt_id,
        &row.attempt_kind,
        row.owner_user_id,
        code,
        &evidence_sha256,
    )
    .await?;
    insert_relay_upgrade_failure_receipt(
        tx,
        attempt_id,
        row.provider_id,
        &row.target_model_id,
        &row.attempt_kind,
        row.provider_version,
        before_model.as_deref(),
        row.routing_policy
            .pointer("/dataPolicy/policySha256")
            .and_then(Value::as_str),
        row.gateway_receipt_sha256.as_deref(),
        row.usage_evidence_sha256.as_deref(),
        events,
        completed_at,
    )
    .await
}

async fn mark_relay_upgrade_attempt_failed(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    attempt_id: Uuid,
    code: &str,
    completed_at: OffsetDateTime,
) -> Result<(), JobError> {
    sqlx::query!(
        "UPDATE ops.provider_model_upgrade_attempts SET status='FAILED',last_error_code=$2, \
           started_at=COALESCE(started_at,CAST($3 AS timestamptz)), \
           completed_at=CAST($3 AS timestamptz), \
           cooldown_until=CASE WHEN attempt_kind='AUTO' \
             THEN CAST($3 AS timestamptz) + interval '6 hours' ELSE NULL END \
         WHERE id=$1 AND status IN ('QUEUED','RUNNING')",
        attempt_id,
        code,
        completed_at,
    )
    .execute(&mut **tx)
    .await
    .map_err(JobError::Database)?;
    Ok(())
}

async fn reconcile_relay_connection_test_failure(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    provider_id: Uuid,
    connection_test_id: Option<Uuid>,
    code: &str,
    completed_at: OffsetDateTime,
) -> Result<(), JobError> {
    let Some(connection_test_id) = connection_test_id else {
        return Ok(());
    };
    let redacted = json!({"code":code,"redacted":true});
    sqlx::query!(
        "UPDATE ops.provider_connection_tests SET status='FAILED',redacted_result=$2, \
           started_at=COALESCE(started_at,$3),completed_at=$3 \
         WHERE id=$1 AND status IN ('QUEUED','RUNNING')",
        connection_test_id,
        redacted,
        completed_at,
    )
    .execute(&mut **tx)
    .await
    .map_err(JobError::Database)?;
    sqlx::query!(
        "UPDATE ops.provider_configs SET last_connection_test_at=$2, \
           last_connection_test_status='FAILED' WHERE id=$1",
        provider_id,
        completed_at,
    )
    .execute(&mut **tx)
    .await
    .map_err(JobError::Database)?;
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct RelayFailureEvents {
    audit_event_id: Option<Uuid>,
    incident_event_id: Option<Uuid>,
}

fn bound_relay_failure_events(
    attempt_kind: &str,
    audit_event_id: Option<Uuid>,
    incident_event_id: Option<Uuid>,
) -> Result<RelayFailureEvents, Failure> {
    match (attempt_kind, audit_event_id, incident_event_id) {
        ("AUTO", Some(audit_event_id), Some(incident_event_id)) => Ok(RelayFailureEvents {
            audit_event_id: Some(audit_event_id),
            incident_event_id: Some(incident_event_id),
        }),
        ("MANUAL", None, None) => Ok(RelayFailureEvents {
            audit_event_id: None,
            incident_event_id: None,
        }),
        _ => Err(Failure::Terminal(
            "PROVIDER_MODEL_UPGRADE_FAILURE_BINDING_INVALID",
            attempt_kind.to_owned(),
        )),
    }
}

async fn relay_upgrade_failure_events(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    attempt_id: Uuid,
    attempt_kind: &str,
    owner_user_id: Uuid,
    code: &str,
    evidence_sha256: &str,
) -> Result<RelayFailureEvents, JobError> {
    if attempt_kind == "MANUAL" {
        return bound_relay_failure_events(attempt_kind, None, None)
            .map_err(relay_failure_job_error);
    }
    let incident_event_id = sqlx::query_scalar!(
        "SELECT ops.record_relay_model_upgrade_failure_incident_v1( \
           $1,$2,$3,CAST($4 AS char(64)))",
        attempt_id,
        owner_user_id,
        code,
        evidence_sha256,
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(JobError::Database)?
    .ok_or_else(|| relay_failure_job_error(Failure::Terminal(
        "PROVIDER_MODEL_UPGRADE_FAILURE_BINDING_INVALID",
        attempt_id.to_string(),
    )))?;
    let audit_event_id = sqlx::query_scalar!(
        "SELECT audit_event_id FROM ops.incident_events WHERE id=$1",
        incident_event_id,
    )
    .fetch_optional(&mut **tx)
    .await
    .map_err(JobError::Database)?
    .ok_or_else(|| relay_failure_job_error(Failure::Terminal(
        "PROVIDER_MODEL_UPGRADE_FAILURE_BINDING_INVALID",
        incident_event_id.to_string(),
    )))?;
    bound_relay_failure_events(attempt_kind, Some(audit_event_id), Some(incident_event_id))
        .map_err(relay_failure_job_error)
}

#[expect(
    clippy::too_many_arguments,
    reason = "failure receipt repeats the complete non-applied upgrade evidence tuple"
)]
async fn insert_relay_upgrade_failure_receipt(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    attempt_id: Uuid,
    provider_id: Uuid,
    target_model_id: &str,
    attempt_kind: &str,
    provider_version: i64,
    before_model: Option<&str>,
    policy_sha256: Option<&str>,
    gateway_receipt_sha256: Option<&str>,
    usage_evidence_sha256: Option<&str>,
    events: RelayFailureEvents,
    recorded_at: OffsetDateTime,
) -> Result<(), JobError> {
    let receipt = RelayUpgradeReceipt::build(RelayUpgradeReceiptInput {
        receipt_id: Uuid::new_v4(),
        attempt_id,
        provider_id,
        target_model_id: target_model_id.to_owned(),
        attempt_kind: RelayUpgradeAttemptKind::parse(attempt_kind)
            .map_err(relay_failure_job_error)?,
        outcome: RelayUpgradeReceiptOutcome::Failed,
        before_provider_version: provider_version,
        after_provider_version: provider_version,
        before_model_id: before_model.map(str::to_owned),
        after_model_id: before_model.map(str::to_owned),
        policy_sha256: policy_sha256.map(str::to_owned),
        gateway_receipt_sha256: gateway_receipt_sha256.map(str::to_owned),
        usage_evidence_sha256: usage_evidence_sha256.map(str::to_owned),
        audit_event_id: events.audit_event_id,
        incident_event_id: events.incident_event_id,
        cost_event_id: None,
        recorded_at,
    })
    .map_err(relay_failure_job_error)?;
    sqlx::query!(
        "INSERT INTO ops.provider_model_upgrade_receipts( \
           id,attempt_id,provider_id,target_model_id,attempt_kind,outcome,before_provider_version, \
           after_provider_version,before_model_id,after_model_id,policy_sha256,gateway_receipt_sha256, \
           usage_evidence_sha256,audit_event_id,incident_event_id,receipt_canonical, \
           canonical_receipt,receipt_sha256,recorded_at) \
         VALUES($1,$2,$3,$4,$5,$6,$7,$7,$8,$8,CAST($9 AS char(64)),CAST($10 AS char(64)), \
           CAST($11 AS char(64)),$12,$13,$14,$15,CAST($16 AS char(64)),$17) \
         ON CONFLICT(attempt_id) DO NOTHING",
        receipt.receipt_id,
        attempt_id,
        provider_id,
        target_model_id,
        receipt.attempt_kind.as_str(),
        receipt.outcome.as_str(),
        provider_version,
        before_model,
        policy_sha256,
        gateway_receipt_sha256,
        usage_evidence_sha256,
        events.audit_event_id,
        events.incident_event_id,
        receipt.receipt_canonical,
        receipt.canonical_receipt,
        receipt.receipt_sha256,
        receipt.recorded_at,
    )
    .execute(&mut **tx)
    .await
    .map_err(JobError::Database)?;
    Ok(())
}

fn relay_failure_job_error(failure: Failure) -> JobError {
    JobError::Database(sqlx::Error::Protocol(failure_detail(&failure)))
}

#[cfg(test)]
mod relay_upgrade_failure_tests {
    use super::*;

    #[test]
    fn auto_failure_requires_actual_incident_and_audit_bindings() {
        let audit_event_id = Uuid::from_u128(1);
        let incident_event_id = Uuid::from_u128(2);
        let events = bound_relay_failure_events(
            "AUTO",
            Some(audit_event_id),
            Some(incident_event_id),
        )
        .expect("bound AUTO failure events");
        assert_eq!(events.audit_event_id, Some(audit_event_id));
        assert_eq!(events.incident_event_id, Some(incident_event_id));
        assert!(bound_relay_failure_events("AUTO", None, None).is_err());
        assert!(bound_relay_failure_events("AUTO", Some(audit_event_id), None).is_err());
        assert!(bound_relay_failure_events("AUTO", None, Some(incident_event_id)).is_err());
    }

    #[test]
    fn manual_failure_forbids_incident_and_audit_bindings() {
        let events = bound_relay_failure_events("MANUAL", None, None)
            .expect("unbound MANUAL failure events");
        assert_eq!(events.audit_event_id, None);
        assert_eq!(events.incident_event_id, None);
        assert!(bound_relay_failure_events("MANUAL", Some(Uuid::from_u128(1)), None).is_err());
        assert!(bound_relay_failure_events("MANUAL", None, Some(Uuid::from_u128(2))).is_err());
        assert!(bound_relay_failure_events(
            "MANUAL",
            Some(Uuid::from_u128(1)),
            Some(Uuid::from_u128(2)),
        )
        .is_err());
    }
}
