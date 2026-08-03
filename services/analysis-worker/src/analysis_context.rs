async fn load_agent_context(state: &State, job: &ClaimedJob) -> Result<AgentContext, Failure> {
    let claim = claim_agent_run(state, job).await?;
    validate_claimed_snapshot(&state.pool, &claim).await?;
    // Budget exhaustion is fenced before any evidence/source-use lookup. A
    // zero envelope must settle as BUDGET_BLOCKED even when no source graph
    // can be materialized, and must never trigger provider/tool work.
    if claim.maximum_cost_krw <= 0 {
        return Ok(budget_blocked_agent_context(job.id, claim));
    }
    let evidence = load_claimed_evidence(state, &claim).await?;
    validate_legacy_source_bindings(state, &claim, &evidence)?;
    let current_snapshot = resolve_claimed_snapshot(&claim, &evidence)?;
    let (allowed_ids, locator_map, input, transcript) = agent_inputs(
        &evidence,
        &claim.evidence_ids,
        current_snapshot.clone(),
        claim.maximum_cost_krw,
        &claim.agent_type,
    )?;
    Ok(AgentContext {
        job_id: job.id,
        run_id: claim.run_id,
        run_version: claim.run_version,
        case_id: claim.case_id,
        agent_type: claim.agent_type,
        objective: claim.objective,
        evidence,
        expected_snapshot: claim.expected_snapshot,
        current_snapshot,
        maximum_cost_krw: claim.maximum_cost_krw,
        allowed_ids,
        locator_map,
        input,
        transcript,
        transition: claim.transition,
    })
}

#[derive(Debug)]
struct ClaimedAgentRun {
    run_id: Uuid,
    run_version: i64,
    case_id: Uuid,
    agent_type: String,
    objective: String,
    evidence_ids: Vec<Uuid>,
    expected_snapshot: String,
    maximum_cost_krw: i64,
    snapshot_contract: ClaimedSnapshotContract,
    transition: AgentRunTransition,
}

#[derive(Debug)]
struct V1ClaimedAgentRunRow {
    case_id: Uuid,
    agent_type: String,
    objective: String,
    evidence_scope_ids: Value,
    input_snapshot_hash: String,
    max_cost: Decimal,
    version: i64,
    run_contract_version: i16,
    dataset_snapshot_id: Option<Uuid>,
}

async fn claim_agent_run(state: &State, job: &ClaimedJob) -> Result<ClaimedAgentRun, Failure> {
    let run_id = payload_uuid(&job.payload, "agentRunId")?;
    match agent_run_contract_route(&state.pool, run_id).await? {
        AgentRunContractRoute::V1 => claim_agent_run_v1(state, run_id).await,
        AgentRunContractRoute::V2 => claim_agent_run_v2(state, job, run_id).await,
    }
}

async fn claim_agent_run_v1(state: &State, run_id: Uuid) -> Result<ClaimedAgentRun, Failure> {
    let row = sqlx::query_as!(
        V1ClaimedAgentRunRow,
        r#"SELECT
             case_id AS "case_id!", agent_type AS "agent_type!", objective AS "objective!",
             evidence_scope_ids AS "evidence_scope_ids!",
             input_snapshot_hash AS "input_snapshot_hash!", max_cost AS "max_cost!",
             version AS "version!", run_contract_version AS "run_contract_version!",
             dataset_snapshot_id
           FROM ops.claim_agent_run_worker_v1($1)"#,
        run_id,
    )
    .fetch_optional(&state.pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("AGENT_RUN_NOT_QUEUED", run_id.to_string()))?;
    let evidence_ids = json_uuids(row.evidence_scope_ids)?;
    let expected_snapshot = row.input_snapshot_hash.trim().to_owned();
    let maximum_cost = row.max_cost;
    let snapshot_contract = claimed_snapshot_contract(
        row.run_contract_version,
        row.dataset_snapshot_id,
        &evidence_ids,
        &expected_snapshot,
    )?;
    let maximum_cost_krw = maximum_cost
        .trunc()
        .to_string()
        .parse::<i64>()
        .map_err(|_| Failure::Terminal("AGENT_BUDGET_INVALID", run_id.to_string()))?;
    Ok(ClaimedAgentRun {
        run_id,
        run_version: row.version,
        case_id: row.case_id,
        agent_type: row.agent_type,
        objective: row.objective,
        evidence_ids,
        expected_snapshot,
        maximum_cost_krw,
        snapshot_contract,
        transition: AgentRunTransition::V1,
    })
}

async fn validate_claimed_snapshot(pool: &PgPool, claim: &ClaimedAgentRun) -> Result<(), Failure> {
    if let ClaimedSnapshotContract::V2 {
        dataset_snapshot_id,
    } = claim.snapshot_contract
    {
        validate_v2_agent_snapshot(
            pool,
            claim.run_id,
            claim.case_id,
            dataset_snapshot_id,
            &claim.expected_snapshot,
        )
        .await?;
    }
    Ok(())
}

fn budget_blocked_agent_context(job_id: Uuid, claim: ClaimedAgentRun) -> AgentContext {
    AgentContext {
        job_id,
        run_id: claim.run_id,
        run_version: claim.run_version,
        case_id: claim.case_id,
        agent_type: claim.agent_type,
        objective: claim.objective,
        evidence: json!([]),
        current_snapshot: claim.expected_snapshot.clone(),
        expected_snapshot: claim.expected_snapshot,
        maximum_cost_krw: claim.maximum_cost_krw,
        allowed_ids: Vec::new(),
        locator_map: serde_json::Map::new(),
        input: json!({"budget_krw": claim.maximum_cost_krw}),
        transcript: json!({"calls": []}),
        transition: claim.transition,
    }
}

async fn load_claimed_evidence(state: &State, claim: &ClaimedAgentRun) -> Result<Value, Failure> {
    // The production provider path requires an immutable source-use graph.
    // Deterministic test/development doubles deliberately exercise policy
    // fences against the verified editorial snapshot without opening an
    // egress boundary, so they do not need synthetic provenance rows.
    match claim.snapshot_contract {
        ClaimedSnapshotContract::V1 => {
            if state.config.environment == "production" {
                ensure_legacy_agent_source_use_roots(
                    &state.pool,
                    claim.run_id,
                    &claim.evidence_ids,
                )
                .await?;
            }
            evidence_snapshot(
                &state.pool,
                claim.case_id,
                claim.run_id,
                &claim.evidence_ids,
            )
            .await
        }
        ClaimedSnapshotContract::V2 {
            dataset_snapshot_id,
        } => {
            validate_v2_agent_source_use_root_preconditions(
                &state.pool,
                claim.run_id,
                claim.case_id,
                dataset_snapshot_id,
                &claim.expected_snapshot,
            )
            .await?;
            // AgentRunV2 deliberately has an empty editorial evidence scope.
            // Normalized members are exposed only through the exact snapshot
            // corpus and its immutable source-use roots; synthesizing legacy
            // evidence rows here would reintroduce an unbound scope authority.
            Ok(json!([]))
        }
    }
}

fn validate_legacy_source_bindings(
    state: &State,
    claim: &ClaimedAgentRun,
    evidence: &Value,
) -> Result<(), Failure> {
    // Fail closed before calculating the semantic snapshot.  The hash must
    // cover the exact source-use rows (selected bytes and rights), otherwise a
    // provider request could be replayed against a different evidence set.
    if state.config.environment == "production"
        && claim.snapshot_contract == ClaimedSnapshotContract::V1
    {
        let _ = ordered_source_use_bindings(evidence)?;
    }
    Ok(())
}

fn resolve_claimed_snapshot(claim: &ClaimedAgentRun, evidence: &Value) -> Result<String, Failure> {
    // The AGENT_CASE snapshot hash covers the immutable evidence selection.
    // Source-use rows are provenance joins created by the dispatcher and are
    // bound independently in the semantic provider request; including their
    // receipt-dependent fields here would make the control-side snapshot hash
    // change after dispatch and falsely report a stale snapshot.
    Ok(match claim.snapshot_contract {
        ClaimedSnapshotContract::V1 => {
            let snapshot_evidence = evidence_without_source_uses(evidence)?;
            // AGENT_CASE snapshot identity is the immutable selected evidence
            // graph for legacy runs. The objective is independently bound in
            // the provider request and is intentionally excluded.
            agent_case_snapshot_sha256(&claim.case_id.to_string(), &snapshot_evidence).map_err(
                |error| {
                    Failure::Terminal("AGENT_SNAPSHOT_CANONICALIZATION_FAILED", error.to_string())
                },
            )?
        }
        // V2 stores the finalized DatasetSnapshot digest itself. Recomputing a
        // legacy editorial hash, or rediscovering another READY row with the
        // same hash, would sever the claimed `(id, hash)` binding.
        ClaimedSnapshotContract::V2 { .. } => claim.expected_snapshot.clone(),
    })
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ClaimedSnapshotContract {
    V1,
    V2 { dataset_snapshot_id: Uuid },
}

fn claimed_snapshot_contract(
    run_contract_version: i16,
    dataset_snapshot_id: Option<Uuid>,
    evidence_ids: &[Uuid],
    input_snapshot_sha256: &str,
) -> Result<ClaimedSnapshotContract, Failure> {
    if !is_sha256_text(input_snapshot_sha256) {
        return Err(Failure::Terminal(
            "AGENT_EVIDENCE_SCOPE_INVALID",
            "input snapshot digest".to_owned(),
        ));
    }
    match run_contract_version {
        1 => Ok(ClaimedSnapshotContract::V1),
        2 if evidence_ids.is_empty() => dataset_snapshot_id
            .map(|dataset_snapshot_id| ClaimedSnapshotContract::V2 {
                dataset_snapshot_id,
            })
            .ok_or_else(|| {
                Failure::Terminal(
                    "AGENT_EVIDENCE_SCOPE_INVALID",
                    "v2 dataset snapshot id".to_owned(),
                )
            }),
        2 => Err(Failure::Terminal(
            "AGENT_EVIDENCE_SCOPE_INVALID",
            "v2 evidence scope must be empty".to_owned(),
        )),
        _ => Err(Failure::Terminal(
            "AGENT_EVIDENCE_SCOPE_INVALID",
            "run contract version".to_owned(),
        )),
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum AgentRunContractRoute {
    V1,
    V2,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum AgentRunTransition {
    V1,
    V2(V2AgentRunFence),
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct V2AgentRunFence {
    expected_version: i64,
    prior_receipt_id: Uuid,
    prior_receipt_sha256: String,
    job_id: Uuid,
    lease_token: Uuid,
    job_fencing_token: i64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct V2JobFence {
    job_id: Uuid,
    lease_token: Uuid,
    fencing_token: i64,
}

#[derive(Debug)]
struct V2ClaimFenceRow {
    version: Option<i64>,
    receipt_id: Option<Uuid>,
    receipt_sha256: Option<String>,
}

async fn agent_run_contract_route(
    pool: &PgPool,
    run_id: Uuid,
) -> Result<AgentRunContractRoute, Failure> {
    let version = sqlx::query_scalar!(
        "SELECT run_contract_version FROM ops.agent_runs WHERE id=$1",
        run_id,
    )
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("AGENT_RUN_NOT_QUEUED", run_id.to_string()))?;
    agent_run_contract_route_for(version, run_id)
}

fn agent_run_contract_route_for(
    version: i16,
    run_id: Uuid,
) -> Result<AgentRunContractRoute, Failure> {
    match version {
        1 => Ok(AgentRunContractRoute::V1),
        2 => Ok(AgentRunContractRoute::V2),
        _ => Err(Failure::Terminal(
            "AGENT_RUN_CONTRACT_UNSUPPORTED",
            run_id.to_string(),
        )),
    }
}

async fn claim_agent_run_v2(
    state: &State,
    job: &ClaimedJob,
    run_id: Uuid,
) -> Result<ClaimedAgentRun, Failure> {
    let row = sqlx::query!(
        "SELECT case_id,agent_type,objective,evidence_scope_ids,input_snapshot_hash,\
                max_cost,version,run_contract_version,dataset_snapshot_id,\
                claim_receipt_id,claim_receipt_sha256 \
           FROM ops.claim_agent_run_worker_v2($1,$2,$3,$4)",
        run_id,
        job.id,
        job.fence.lease_token,
        job.fence.fencing_token,
    )
    .fetch_optional(&state.pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("AGENT_RUN_NOT_QUEUED", run_id.to_string()))?;
    let run_contract_version = required(row.run_contract_version).map_err(database)?;
    if run_contract_version != 2 {
        return Err(Failure::Terminal(
            "AGENT_RUN_CONTRACT_UNSUPPORTED",
            run_id.to_string(),
        ));
    }
    let evidence_ids = json_uuids(required(row.evidence_scope_ids).map_err(database)?)?;
    let expected_snapshot = required(row.input_snapshot_hash)
        .map_err(database)?
        .trim()
        .to_owned();
    let transition = v2_agent_run_fence(
        run_id,
        V2JobFence {
            job_id: job.id,
            lease_token: job.fence.lease_token,
            fencing_token: job.fence.fencing_token,
        },
        V2ClaimFenceRow {
            version: row.version,
            receipt_id: row.claim_receipt_id,
            receipt_sha256: row.claim_receipt_sha256,
        },
    )?;
    let AgentRunTransition::V2(fence) = &transition else {
        return Err(Failure::Terminal(
            "AGENT_RUN_V2_RECEIPT_INVALID",
            run_id.to_string(),
        ));
    };
    let maximum_cost = required(row.max_cost).map_err(database)?;
    let maximum_cost_krw = maximum_cost
        .trunc()
        .to_string()
        .parse::<i64>()
        .map_err(|_| Failure::Terminal("AGENT_BUDGET_INVALID", run_id.to_string()))?;
    Ok(ClaimedAgentRun {
        run_id,
        run_version: fence.expected_version,
        case_id: required(row.case_id).map_err(database)?,
        agent_type: required(row.agent_type).map_err(database)?,
        objective: required(row.objective).map_err(database)?,
        snapshot_contract: claimed_snapshot_contract(
            run_contract_version,
            row.dataset_snapshot_id,
            &evidence_ids,
            &expected_snapshot,
        )?,
        evidence_ids,
        expected_snapshot,
        maximum_cost_krw,
        transition,
    })
}

fn v2_agent_run_fence(
    run_id: Uuid,
    job: V2JobFence,
    row: V2ClaimFenceRow,
) -> Result<AgentRunTransition, Failure> {
    let Some(expected_version) = row.version.filter(|version| *version > 0) else {
        return Err(invalid_v2_fence(run_id, "version"));
    };
    if job.fencing_token <= 0 {
        return Err(invalid_v2_fence(run_id, "job fencing token"));
    }
    let Some(prior_receipt_id) = row.receipt_id else {
        return Err(invalid_v2_fence(run_id, "receipt id"));
    };
    let Some(prior_receipt_sha256) = row
        .receipt_sha256
        .map(|digest| digest.trim().to_owned())
        .filter(|digest| is_sha256_text(digest))
    else {
        return Err(invalid_v2_fence(run_id, "receipt digest"));
    };
    Ok(AgentRunTransition::V2(V2AgentRunFence {
        expected_version,
        prior_receipt_id,
        prior_receipt_sha256,
        job_id: job.job_id,
        lease_token: job.lease_token,
        job_fencing_token: job.fencing_token,
    }))
}

fn invalid_v2_fence(run_id: Uuid, field: &'static str) -> Failure {
    Failure::Terminal("AGENT_RUN_V2_RECEIPT_INVALID", format!("{run_id}:{field}"))
}

async fn validate_v2_agent_snapshot(
    pool: &PgPool,
    run_id: Uuid,
    case_id: Uuid,
    dataset_snapshot_id: Uuid,
    input_snapshot_sha256: &str,
) -> Result<(), Failure> {
    let valid = required(
        sqlx::query_scalar!(
            r#"
        SELECT EXISTS(
          SELECT 1
            FROM ops.agent_runs run
            JOIN core.dataset_snapshots snapshot
              ON snapshot.id = run.dataset_snapshot_id
             AND snapshot.snapshot_sha256 = run.input_snapshot_hash
           WHERE run.id = $1
             AND run.case_id = $2
             AND run.run_contract_version = 2
             AND run.evidence_scope_ids = '[]'::jsonb
             AND run.dataset_snapshot_id = $3
             AND run.input_snapshot_hash = CAST($4 AS char(64))
             AND snapshot.snapshot_kind = 'AGENT_CASE'
             AND snapshot.state = 'READY'
             AND snapshot.selection_spec->>'caseId' = $2::text
        )
        "#,
            run_id,
            case_id,
            dataset_snapshot_id,
            input_snapshot_sha256,
        )
        .fetch_one(pool)
        .await
        .map_err(database)?,
    )
    .map_err(database)?;
    if !valid {
        return Err(Failure::Terminal(
            "AGENT_EVIDENCE_SCOPE_INVALID",
            "v2 snapshot binding".to_owned(),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod claimed_snapshot_contract_tests {
    use super::*;

    const SHA: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    #[test]
    fn v1_keeps_the_legacy_evidence_scope() {
        let evidence_id = Uuid::from_u128(1);
        assert_eq!(
            claimed_snapshot_contract(1, None, &[evidence_id], SHA).ok(),
            Some(ClaimedSnapshotContract::V1),
        );
    }

    #[test]
    fn v2_requires_empty_scope_and_exact_snapshot_id() {
        let snapshot_id = Uuid::from_u128(2);
        assert_eq!(
            claimed_snapshot_contract(2, Some(snapshot_id), &[], SHA).ok(),
            Some(ClaimedSnapshotContract::V2 {
                dataset_snapshot_id: snapshot_id,
            }),
        );
        assert!(claimed_snapshot_contract(2, None, &[], SHA).is_err());
        assert!(
            claimed_snapshot_contract(2, Some(snapshot_id), &[Uuid::from_u128(3)], SHA).is_err()
        );
    }
}
