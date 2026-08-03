{
    let rendering_id = event
    .payload
    .get("renderingId")
    .and_then(serde_json::Value::as_str)
    .and_then(|value| Uuid::parse_str(value).ok())
    .ok_or(WorkerError::Contract)?;
let expected_version = event
    .payload
    .get("expectedVersion")
    .and_then(serde_json::Value::as_i64)
    .unwrap_or(1);
let request_digest = event
    .payload
    .get("requestDigest")
    .and_then(serde_json::Value::as_str)
    .filter(|value| value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
    .map(str::to_owned)
    .unwrap_or_else(|| sha256_hex(event.id.as_bytes()));
    let target_state = event
    .payload
    .get("approval")
    .and_then(|value| value.get("decision"))
    .and_then(serde_json::Value::as_str)
    .map(|value| if value == "APPROVED" { "APPROVED" } else { "REJECTED" })
    .unwrap_or("AWAITING_APPROVAL");
    let approval = event.payload.get("approval").cloned().unwrap_or_else(|| serde_json::json!({}));
    if !approval.is_object() || approval.as_object().is_none_or(|v| v.is_empty()) {
        let changed = sqlx::query("UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' WHERE consumer='notification-worker' AND event_id=$1 AND processed_at IS NULL")
            .bind(event.id).execute(&state.pool).await.map_err(|_| WorkerError::Database)?.rows_affected();
        if changed != 1 { return Err(WorkerError::Database); }
        state.worker.complete(&state.pool, job, serde_json::json!({"reconciled": true})).await.map_err(WorkerError::Job)?;
        return Ok(());
    }
let approval_digest = approval.get("approvalDigest").and_then(serde_json::Value::as_str);
let policy_digest = approval.get("policyDecisionDigest").and_then(serde_json::Value::as_str);
let receipt_digest = approval.get("approvalReceiptDigest").and_then(serde_json::Value::as_str);
let expires_at = approval.get("approvalExpiresAt").and_then(serde_json::Value::as_str)
    .map(|value| time::OffsetDateTime::parse(value, &time::format_description::well_known::Rfc3339).map_err(|_| WorkerError::Contract)).transpose()?;
sqlx::query(
    "SELECT (ops.transition_communication_rendering(ROW($1::uuid,$2::bigint,$3::text,$4::text,$5::char(64),$6::char(64),$7::char(64),$8::timestamptz,$9::char(64))::ops.communication_rendering_transition_v1)).*",
)
.bind(rendering_id)
.bind(expected_version)
.bind(target_state)
.bind(approval.get("reason").and_then(serde_json::Value::as_str).unwrap_or("rendering lifecycle"))
.bind(approval_digest)
.bind(policy_digest)
.bind(receipt_digest)
.bind(expires_at)
.bind(request_digest)
.fetch_one(&state.pool)
.await
.map_err(|_| WorkerError::Database)?;
let changed = sqlx::query("UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' WHERE consumer='notification-worker' AND event_id=$1 AND processed_at IS NULL")
    .bind(event.id).execute(&state.pool).await.map_err(|_| WorkerError::Database)?.rows_affected();
if changed != 1 { return Err(WorkerError::Database); }
state.worker.complete(&state.pool, job, serde_json::json!({"renderingId":rendering_id,"state":target_state})).await.map_err(WorkerError::Job)
}
