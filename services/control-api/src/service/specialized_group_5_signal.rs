use super::*;

pub(super) async fn arm_triagesignal(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let signal = uuid_value(payload, &["signalId"]).ok_or(ServiceError::InvalidRequest)?;
    let detail = payload.get("decisionDetail").and_then(Value::as_object);
    let decision = detail
        .and_then(|value| value.get("decision").and_then(Value::as_str))
        .or_else(|| string_value(payload, "decision"));
    let status = signal_status(decision)?;
    let expected_version = detail
        .and_then(|value| value.get("expectedSignalVersion").and_then(Value::as_i64))
        .or_else(|| payload.get("expectedVersion").and_then(Value::as_i64))
        .ok_or(ServiceError::InvalidRequest)?;
    let duplicate_target = detail
        .and_then(|value| value.get("duplicateSignalId").and_then(Value::as_str))
        .or_else(|| payload.get("duplicateSignalId").and_then(Value::as_str))
        .map(|raw| Uuid::parse_str(raw).map_err(|_| ServiceError::InvalidRequest))
        .transpose()?;
    if status == "DUPLICATE" {
        mark_duplicate_signal(
            payload,
            detail,
            signal,
            actor,
            expected_version,
            duplicate_target,
            tx,
        )
        .await?;
    } else {
        mark_signal_status(payload, detail, signal, status, expected_version, tx).await?;
    }
    upsert_task(
        tx,
        "SIGNAL",
        signal,
        "Signal triage",
        if matches!(status, "DISMISSED" | "DUPLICATE") {
            "DONE"
        } else {
            "OPEN"
        },
        "HIGH",
        None,
        actor,
        Some(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?),
    )
    .await?;
    Ok(())
}

fn signal_status(decision: Option<&str>) -> Result<&'static str, ServiceError> {
    match decision {
        Some("investigate") | Some("PROMOTE_TO_CASE") => Ok("ASSIGNED"),
        Some("dismiss") | Some("DISMISS") => Ok("DISMISSED"),
        Some("duplicate") | Some("MARK_DUPLICATE") => Ok("DUPLICATE"),
        Some("needs_data") | Some("NEEDS_DATA") => Ok("NEEDS_DATA"),
        Some("link") | Some("LINK_TO_CASE") => Ok("LINKED"),
        _ => Err(ServiceError::InvalidRequest),
    }
}

async fn mark_duplicate_signal(
    payload: &Map<String, Value>,
    detail: Option<&Map<String, Value>>,
    signal: Uuid,
    actor: Uuid,
    expected_version: i64,
    duplicate_target: Option<Uuid>,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let target = duplicate_target.ok_or(ServiceError::InvalidRequest)?;
    if target == signal {
        return Err(ServiceError::InvalidRequest);
    }
    let pair = sqlx::query(
        "SELECT id, version FROM core.anomaly_signals \
         WHERE id = ANY($1::uuid[]) ORDER BY id FOR UPDATE",
    )
    .bind(vec![signal, target])
    .fetch_all(&mut **tx)
    .await
    .map_err(db)?;
    if pair.len() != 2 {
        return Err(ServiceError::NotFound);
    }
    // A duplicate decision changes two aggregates. Require the target's
    // expected version in the request so a stale pair cannot be accepted.
    let target_expected = detail
        .and_then(|value| {
            value
                .get("expectedDuplicateSignalVersion")
                .and_then(Value::as_i64)
        })
        .or_else(|| {
            payload
                .get("expectedDuplicateSignalVersion")
                .and_then(Value::as_i64)
        })
        .ok_or(ServiceError::InvalidRequest)?;
    let target_version = pair
        .iter()
        .find(|row| row.try_get::<Uuid, _>("id").ok() == Some(target))
        .and_then(|row| row.try_get::<i64, _>("version").ok())
        .ok_or(ServiceError::NotFound)?;
    if target_expected != target_version {
        return Err(ServiceError::VersionConflict);
    }
    let relationship = detail
        .and_then(|value| value.get("duplicateRelationship").and_then(Value::as_str))
        .or_else(|| payload.get("duplicateRelationship").and_then(Value::as_str))
        .unwrap_or("SAME_LOGICAL_EVENT");
    if !matches!(
        relationship,
        "SAME_LOGICAL_EVENT" | "SAME_TARGET" | "SAME_SOURCE" | "OTHER"
    ) {
        return Err(ServiceError::InvalidRequest);
    }
    let reason = signal_reason(payload, detail)?;
    // Bind the rationale to the complete duplicate relation rather than to
    // free text alone; otherwise the same reason can be replayed for another
    // signal/target pair without changing its digest.
    let rationale_binding = json!({
        "signalId": signal,
        "expectedSignalVersion": expected_version,
        "duplicateSignalId": target,
        "expectedDuplicateSignalVersion": target_expected,
        "duplicateRelationship": relationship,
        "reason": reason,
    });
    let rationale_digest =
        sha256(&serde_json::to_vec(&rationale_binding).map_err(|_| ServiceError::InvalidRequest)?);
    let changed = sqlx::query(
        "UPDATE core.anomaly_signals
            SET status='DUPLICATE'::core.signal_status,
                duplicate_signal_id=$2, duplicate_relationship=$3,
                duplicate_reason_digest=$4, duplicate_marked_by=$5,
                duplicate_marked_at=clock_timestamp(), version=version+1
          WHERE id=$1 AND version=$6 AND status <> 'DUPLICATE'::core.signal_status",
    )
    .bind(signal)
    .bind(target)
    .bind(relationship)
    .bind(rationale_digest)
    .bind(actor)
    .bind(expected_version)
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::VersionConflict);
    }
    Ok(())
}

async fn mark_signal_status(
    payload: &Map<String, Value>,
    detail: Option<&Map<String, Value>>,
    signal: Uuid,
    status: &str,
    expected_version: i64,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let _reason = signal_reason(payload, detail)?;
    let changed = sqlx::query(
        "UPDATE core.anomaly_signals
            SET status=$2::core.signal_status,
                duplicate_signal_id=NULL, duplicate_relationship=NULL,
                duplicate_reason_digest=NULL, duplicate_marked_by=NULL,
                duplicate_marked_at=NULL, version=version+1
          WHERE id=$1 AND version=$3 AND status <> 'DUPLICATE'::core.signal_status",
    )
    .bind(signal)
    .bind(status)
    .bind(expected_version)
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::VersionConflict);
    }
    Ok(())
}

fn signal_reason<'a>(
    payload: &'a Map<String, Value>,
    detail: Option<&'a Map<String, Value>>,
) -> Result<&'a str, ServiceError> {
    string_value(payload, "reason")
        .or_else(|| detail.and_then(|value| value.get("reason").and_then(Value::as_str)))
        .ok_or(ServiceError::InvalidRequest)
}
