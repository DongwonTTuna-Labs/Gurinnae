use super::*;

struct ToolCallSourceUseContext<'a> {
    turn: &'a ProviderTurnIdentity,
    tool_call_id: Uuid,
    call_id: &'a str,
    tool_id: &'a str,
    result_sha256: &'a str,
    receipt_id: Uuid,
    pending_source_fetch: Option<&'a PendingSourceFetch>,
    corpus_parent_source_use_ids: Option<&'a [Uuid]>,
}

struct ToolResultSourceUseSummary {
    count: i32,
    set_sha256: String,
}

#[expect(
    clippy::too_many_arguments,
    reason = "tool result projection binds request, response, transcript, and provider receipt"
)]
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
    corpus_parent_source_use_ids: Option<&[Uuid]>,
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
    let context = ToolCallSourceUseContext {
        turn,
        tool_call_id,
        call_id: &call_text,
        tool_id,
        result_sha256: &result_sha256,
        receipt_id,
        pending_source_fetch,
        corpus_parent_source_use_ids,
    };
    if let Err(error) = persist_tool_call_source_uses(&mut tx, &context).await {
        let _ = tx.rollback().await;
        if let Some(source) = pending_source_fetch {
            delete_orphan(state, source).await;
        }
        return Err(error);
    }
    if let Err(error) = tx.commit().await {
        if let Some(source) = pending_source_fetch {
            delete_orphan(state, source).await;
        }
        return Err(database(error));
    }
    Ok(())
}

async fn persist_tool_call_source_uses(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    context: &ToolCallSourceUseContext<'_>,
) -> Result<(), Failure> {
    if let Some(source) = context.pending_source_fetch {
        super::persist_research_fetch(
            tx,
            context.turn,
            context.tool_call_id,
            context.call_id,
            context.result_sha256,
            source,
        )
        .await?;
    }
    super::insert_tool_result_source_uses(
        tx,
        context.turn,
        context.tool_call_id,
        context.tool_id,
        context.result_sha256,
        Some(context.receipt_id),
        context.corpus_parent_source_use_ids,
    )
    .await?;
    let summary = tool_result_source_use_summary(tx, context).await?;
    sqlx::Executor::execute(
        &mut **tx,
        sqlx::query_scalar!(
            "SELECT ops.finalize_agent_tool_call_source_uses($1,$2,CAST($3 AS char(64)))",
            context.tool_call_id,
            summary.count,
            summary.set_sha256,
        ),
    )
    .await
    .map_err(database)?;
    Ok(())
}

async fn tool_result_source_use_summary(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    context: &ToolCallSourceUseContext<'_>,
) -> Result<ToolResultSourceUseSummary, Failure> {
    let summary = sqlx::query!(
        "SELECT count(*)::int AS count, encode(extensions.digest(convert_to(array_to_string(array_agg(source_use_sha256::text ORDER BY source_use_sha256),','),'UTF8'),'sha256'),'hex') AS digest FROM ops.agent_source_uses WHERE agent_run_id=$1 AND tool_call_id=$2 AND use_kind='TOOL_RESULT'",
        context.turn.run_id,
        context.tool_call_id,
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(database)?;
    let source_use_count: i32 = required(summary.count).map_err(database)?;
    if context
        .corpus_parent_source_use_ids
        .is_some_and(|ids| usize::try_from(source_use_count).ok() != Some(ids.len()))
    {
        return Err(Failure::Terminal(
            "AGENT_TOOL_SOURCE_USE_INVALID",
            context.tool_id.to_owned(),
        ));
    }
    let set_sha256 = if source_use_count == 0 {
        sha256(b"[]")
    } else {
        required(summary.digest).map_err(database)?
    };
    Ok(ToolResultSourceUseSummary {
        count: source_use_count,
        set_sha256,
    })
}

async fn delete_orphan(state: &State, source: &PendingSourceFetch) {
    if let Some(store) = state.object_store.as_ref()
        && let Err(error) = store.delete(&source.object_key).await
    {
        tracing::error!(object_key=%source.object_key, error=%error, "research object orphan reconciliation failed");
    }
}
