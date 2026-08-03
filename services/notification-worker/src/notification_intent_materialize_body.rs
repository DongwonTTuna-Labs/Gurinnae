{
    let intent_id = event
        .payload
        .get("intentId")
        .and_then(serde_json::Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or(WorkerError::Contract)?;
    let source: serde_json::Value = sqlx::query_scalar(
        "SELECT jsonb_build_object( \
           'intentId',id,'logicalIntentDigest',logical_intent_digest, \
           'sourceEventId',source_event_id, \
           'communicationClass',CASE \
             WHEN communication_class='SYSTEM_TRANSACTIONAL' THEN 'PUBLIC_SERVICE_OR_TRANSACTIONAL' \
             ELSE 'DISCRETIONARY_OR_RESTRICTED' END, \
           'purpose',CASE \
             WHEN communication_class='SYSTEM_TRANSACTIONAL' THEN 'SYSTEM_TRANSACTIONAL' \
             ELSE communication_class END, \
           'topicDigest',topic_scope_digest,'recipientSubjectId',recipient_subject_id, \
           'policyVersion',audience_policy_version) \
         FROM ops.communication_intents WHERE id=$1",
    )
    .bind(intent_id)
    .fetch_optional(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?
    .ok_or(WorkerError::Contract)?;
    if source != event.payload {
        return Err(WorkerError::Contract);
    }
    let request_digest = sha256_hex(event.id.as_bytes());
    let receipt = sqlx::query(
        "SELECT (ops.materialize_communication_intent(ROW($1::uuid,$2::bigint,$3::char(64))::ops.communication_intent_materialize_v1)).*",
    )
    .bind(intent_id)
    .bind(event.aggregate_version)
    .bind(&request_digest)
    .fetch_one(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?;
    let version: i64 = receipt.try_get("version").map_err(|_| WorkerError::Database)?;
    let renderings = sqlx::query(
        "SELECT id,rendering_digest FROM ops.communication_renderings \
         WHERE intent_id=$1 AND state='APPROVED' AND expires_at>clock_timestamp() \
         ORDER BY rendering_revision,id",
    )
    .bind(intent_id)
    .fetch_all(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?;
    let mut deliveries = Vec::with_capacity(renderings.len());
    for rendering in renderings {
        let rendering_id: Uuid = rendering.try_get("id").map_err(|_| WorkerError::Database)?;
        let rendering_digest: String = rendering
            .try_get("rendering_digest")
            .map_err(|_| WorkerError::Database)?;
        let queue_request_digest = sha256_hex(
            format!("{request_digest}:{rendering_id}:{rendering_digest}").as_bytes(),
        );
        let queued: serde_json::Value = sqlx::query_scalar(
            "SELECT ops.queue_approved_communication_rendering_v1($1,$2::char(64),$3::char(64))",
        )
        .bind(rendering_id)
        .bind(&rendering_digest)
        .bind(queue_request_digest)
        .fetch_one(&state.pool)
        .await
        .map_err(|_| WorkerError::Database)?;
        deliveries.push(queued);
    }
    let changed = sqlx::query(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' \
         WHERE consumer=$1 AND event_id=$2 AND processed_at IS NULL",
    )
    .bind(&event.consumer_id)
    .bind(event.id)
    .execute(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?
    .rows_affected();
    if changed != 1 {
        return Err(WorkerError::Database);
    }
    state
        .worker
        .complete(
            &state.pool,
            job,
            serde_json::json!({
                "intentId":intent_id,
                "materializedVersion":version,
                "approvedRenderingCount":deliveries.len(),
                "deliveries":deliveries,
            }),
        )
        .await
        .map_err(WorkerError::Job)
}
