use super::*;

#[expect(clippy::too_many_arguments, reason = "tool result projection binds request, response, transcript, and provider receipt")]
pub(super) async fn persist_tool_call(
    state: &State,
    turn: &ProviderTurnIdentity,
    _agent_type: &str,
    tool_call_id: Uuid,
    call: &gurine_agent_orchestration::runtime::ToolCall,
    result: &Value,
    transcript_sha256: &str,
    receipt_id: Uuid,
    pending_source_fetch: Option<&PendingSourceFetch>,
) -> Result<(), Failure> {
    let result_canonical = canonical_bytes(result)?;
    let result_sha256 = sha256(&result_canonical);
    let tool_id = call.request.tool_id().wire_name();
    let call_text = call.call_id.to_string();
    let now = time::OffsetDateTime::now_utc();
    let mut tx = state.pool.begin().await.map_err(database)?;
    sqlx::Executor::execute(
        &mut *tx,
        sqlx::query_scalar!(
            "SELECT ops.complete_agent_tool_call_v2($1,$2,$3,CAST($4 AS char(64)),$5,$6,CAST($7 AS char(64)),CAST($8 AS char(64)),$9)",
            tool_call_id,
            turn.run_id,
            &call_text,
            &result_sha256,
            result,
            result_canonical,
            sha256(b"response-valid"),
            transcript_sha256,
            now,
        ),
    )
    .await
    .map_err(database)?;
    if let Some(source) = pending_source_fetch
        && let Err(error) = super::persist_research_fetch(&mut tx, turn, tool_call_id, &call.call_id.to_string(), &result_sha256, source).await
    {
        let _ = tx.rollback().await;
        delete_orphan(state, source).await;
        return Err(error);
    }
    if let Err(error) = super::insert_tool_result_source_uses(&mut tx, turn, tool_call_id, tool_id, &result_sha256, Some(receipt_id)).await {
        let _ = tx.rollback().await;
        if let Some(source) = pending_source_fetch { delete_orphan(state, source).await; }
        return Err(error);
    }
    let summary = sqlx::query!(
        "SELECT count(*)::int AS count, encode(extensions.digest(convert_to(array_to_string(array_agg(source_use_sha256::text ORDER BY source_use_sha256),','),'UTF8'),'sha256'),'hex') AS digest FROM ops.agent_source_uses WHERE agent_run_id=$1 AND tool_call_id=$2 AND use_kind='TOOL_RESULT'",
        turn.run_id,
        tool_call_id,
    )
    .fetch_one(&mut *tx)
    .await;
    let summary = match summary {
        Ok(row) => row,
        Err(error) => { let _ = tx.rollback().await; if let Some(source) = pending_source_fetch { delete_orphan(state, source).await; } return Err(database(error)); }
    };
    let source_use_count: i32 = match required(summary.count) {
        Ok(value) => value,
        Err(error) => { let _ = tx.rollback().await; if let Some(source) = pending_source_fetch { delete_orphan(state, source).await; } return Err(database(error)); }
    };
    let source_use_set_sha256: String = match required(summary.digest) {
        Ok(value) => value,
        Err(error) => { let _ = tx.rollback().await; if let Some(source) = pending_source_fetch { delete_orphan(state, source).await; } return Err(database(error)); }
    };
    if let Err(error) = sqlx::Executor::execute(
        &mut *tx,
        sqlx::query_scalar!(
            "SELECT ops.finalize_agent_tool_call_source_uses($1,$2,CAST($3 AS char(64)))",
            tool_call_id,
            source_use_count,
            source_use_set_sha256,
        ),
    )
    .await
    {
        let _ = tx.rollback().await;
        if let Some(source) = pending_source_fetch { delete_orphan(state, source).await; }
        return Err(database(error));
    }
    if let Err(error) = tx.commit().await {
        if let Some(source) = pending_source_fetch { delete_orphan(state, source).await; }
        return Err(database(error));
    }
    Ok(())
}

async fn delete_orphan(state: &State, source: &PendingSourceFetch) {
    if let Some(store) = state.object_store.as_ref()
        && let Err(error) = store.delete(&source.object_key).await
    {
        tracing::error!(object_key=%source.object_key, error=%error, "research object orphan reconciliation failed");
    }
}
