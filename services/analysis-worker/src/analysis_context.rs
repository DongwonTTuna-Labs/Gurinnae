async fn load_agent_context(state: &State, job: &ClaimedJob) -> Result<AgentContext, Failure> {
    let run_id = payload_uuid(&job.payload, "agentRunId")?;
    let row = sqlx::query(
        "SELECT * FROM ops.claim_agent_run_worker_v1($1)",
    )
    .bind(run_id)
    .fetch_optional(&state.pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("AGENT_RUN_NOT_QUEUED", run_id.to_string()))?;
    let case_id: Uuid = row.try_get("case_id").map_err(database)?;
    let agent_type: String = row.try_get("agent_type").map_err(database)?;
    let objective: String = row.try_get("objective").map_err(database)?;
    let evidence_ids = json_uuids(row.try_get("evidence_scope_ids").map_err(database)?)?;
    let expected_snapshot: String = row.try_get::<String, _>("input_snapshot_hash").map_err(database)?.trim().to_owned();
    let maximum_cost = row.try_get::<Decimal, _>("max_cost").map_err(database)?;
    let run_version: i64 = row.try_get("version").map_err(database)?;
    let maximum_cost_krw = maximum_cost.trunc().to_string().parse::<i64>().map_err(|_| Failure::Terminal("AGENT_BUDGET_INVALID", run_id.to_string()))?;
    // Budget exhaustion is fenced before any evidence/source-use lookup. A
    // zero envelope must settle as BUDGET_BLOCKED even when no source graph
    // can be materialized, and must never trigger provider/tool work.
    if maximum_cost_krw <= 0 {
        return Ok(AgentContext {
            job_id: job.id,
            run_id,
            run_version,
            case_id,
            agent_type,
            objective,
            evidence: json!([]),
            expected_snapshot: expected_snapshot.clone(),
            current_snapshot: expected_snapshot,
            maximum_cost_krw,
            allowed_ids: Vec::new(),
            locator_map: serde_json::Map::new(),
            input: json!({"budget_krw": maximum_cost_krw}),
            transcript: json!({"calls": []}),
        });
    }
    // The production provider path requires an immutable source-use graph.
    // Deterministic test/development doubles deliberately exercise policy
    // fences against the verified editorial snapshot without opening an
    // egress boundary, so they do not need synthetic provenance rows.
    if state.config.environment == "production" {
        ensure_agent_source_use_roots(&state.pool, run_id, &evidence_ids).await?;
    }
    let evidence = evidence_snapshot(&state.pool, case_id, run_id, &evidence_ids).await?;
    // Fail closed before calculating the semantic snapshot.  The hash must
    // cover the exact source-use rows (selected bytes and rights), otherwise a
    // provider request could be replayed against a different evidence set.
    if state.config.environment == "production" {
        let _ = ordered_source_use_bindings(&evidence)?;
    }
    // The AGENT_CASE snapshot hash covers the immutable evidence selection.
    // Source-use rows are provenance joins created by the dispatcher and are
    // bound independently in the semantic provider request; including their
    // receipt-dependent fields here would make the control-side snapshot hash
    // change after dispatch and falsely report a stale snapshot.
    let snapshot_evidence = evidence_without_source_uses(&evidence)?;
    let current_snapshot = sha256(&canonical_bytes(&json!({"caseId":case_id,"evidence":snapshot_evidence,"objective":objective}))?);
    let (allowed_ids, locator_map, input, transcript) = agent_inputs(
        &evidence,
        &evidence_ids,
        current_snapshot.clone(),
        maximum_cost_krw,
        &agent_type,
    )?;
    Ok(AgentContext {
        run_id,
        job_id: job.id,
        run_version,
        case_id,
        agent_type,
        objective,
        evidence,
        expected_snapshot,
        current_snapshot,
        maximum_cost_krw,
        allowed_ids,
        locator_map,
        input,
        transcript,
    })
}
