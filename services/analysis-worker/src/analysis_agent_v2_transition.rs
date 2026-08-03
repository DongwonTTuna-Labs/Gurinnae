struct V2CompletionArguments<'a> {
    next_status: &'a str,
    provider: Option<&'a str>,
    model: Option<&'a str>,
    output_payload: Option<&'a Value>,
    output_sha256: Option<&'a str>,
    failure_code: Option<&'a str>,
    failure_proof: Option<&'a Value>,
    failure_proof_sha256: Option<&'a str>,
    actual_cost: Option<Decimal>,
}
impl<'a> V2CompletionArguments<'a> {
    fn validated_output(
        status: &'a str,
        provider: &'a str,
        model: &'a str,
        output: &'a Value,
        output_sha256: &'a str,
        actual_cost: i64,
    ) -> Result<Self, Failure> {
        if !matches!(status, "SUCCEEDED" | "BUDGET_BLOCKED" | "POLICY_BLOCKED")
            || !is_sha256_text(output_sha256)
            || actual_cost < 0
        {
            return Err(Failure::Terminal(
                "AGENT_RUN_V2_TERMINAL_PROOF_INVALID",
                status.to_owned(),
            ));
        }
        if provider.trim().is_empty() || model.trim().is_empty() {
            return Err(Failure::Terminal(
                "AGENT_RUN_V2_TERMINAL_PROOF_INVALID",
                "provider/model pair".to_owned(),
            ));
        }
        Ok(Self {
            next_status: status,
            provider: Some(provider),
            model: Some(model),
            output_payload: Some(output),
            output_sha256: Some(output_sha256),
            failure_code: None,
            failure_proof: None,
            failure_proof_sha256: None,
            actual_cost: Some(Decimal::from(actual_cost)),
        })
    }

    fn definitive_failure(
        failure_code: &'a str,
        proof: &'a Value,
        proof_sha256: &'a str,
    ) -> Result<Self, Failure> {
        if !is_v2_failure_code(failure_code) || !is_sha256_text(proof_sha256) {
            return Err(Failure::Terminal(
                "AGENT_RUN_V2_TERMINAL_PROOF_INVALID",
                failure_code.to_owned(),
            ));
        }
        Ok(Self {
            next_status: "FAILED",
            provider: None,
            model: None,
            output_payload: None,
            output_sha256: None,
            failure_code: Some(failure_code),
            failure_proof: Some(proof),
            failure_proof_sha256: Some(proof_sha256),
            actual_cost: Some(Decimal::from(0)),
        })
    }
}

fn is_v2_failure_code(code: &str) -> bool {
    matches!(
        code,
        "OUTPUT_SCHEMA_INVALID"
            | "PROVIDER_UNAVAILABLE"
            | "INTERNAL_EXECUTION_FAILED"
            | "CITATION_INVALID"
            | "RIGHTS_DENIED"
            | "CLASSIFICATION_DENIED"
            | "ITERATION_LIMIT_REACHED"
            | "CANCELLED_BY_USER"
            | "RECONCILIATION_FAILED"
    )
}

struct V2OwnerResultRow {
    version: Option<i64>,
    receipt_id: Option<Uuid>,
    receipt_sha256: Option<String>,
    replayed: Option<bool>,
}
struct V2OwnerResult {
    version: i64,
    receipt_id: Uuid,
    receipt_sha256: String,
    replayed: bool,
}

fn v2_owner_result(
    run_id: Uuid,
    expected_version: i64,
    row: V2OwnerResultRow,
) -> Result<V2OwnerResult, Failure> {
    let next_version = expected_version
        .checked_add(1)
        .ok_or_else(|| invalid_v2_fence(run_id, "result version overflow"))?;
    let Some(version) = row.version.filter(|version| *version == next_version) else {
        return Err(invalid_v2_fence(run_id, "result version"));
    };
    let Some(receipt_id) = row.receipt_id else {
        return Err(invalid_v2_fence(run_id, "result receipt id"));
    };
    let Some(receipt_sha256) = row
        .receipt_sha256
        .map(|digest| digest.trim().to_owned())
        .filter(|digest| is_sha256_text(digest))
    else {
        return Err(invalid_v2_fence(run_id, "result receipt digest"));
    };
    let Some(replayed) = row.replayed else {
        return Err(invalid_v2_fence(run_id, "result replay flag"));
    };
    Ok(V2OwnerResult {
        version,
        receipt_id,
        receipt_sha256,
        replayed,
    })
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum V2FailureDisposition {
    ReconciliationRequired,
    DefinitiveFailure,
}

fn v2_failure_disposition(code: &str, retrying: bool) -> V2FailureDisposition {
    if code == "PROVIDER_OUTCOME_UNKNOWN" || retrying {
        V2FailureDisposition::ReconciliationRequired
    } else {
        // Only a definitive failure may settle this exact claimed run.
        V2FailureDisposition::DefinitiveFailure
    }
}

struct V2FailureProof {
    payload: Value,
    sha256: String,
}

fn v2_ambiguity_proof(run_id: Uuid, detail: &str) -> Result<V2FailureProof, Failure> {
    v2_failure_proof(json!({
        "schemaVersion":"agent-run-ambiguity-proof.v1",
        "runId":run_id,
        "reasonCode":"PROVIDER_OUTCOME_UNKNOWN",
        "detailSha256":sha256(detail.as_bytes()),
        "redacted":true,
    }))
}

fn v2_definitive_failure_proof(
    run_id: Uuid,
    failure_code: &str,
    detail: &str,
) -> Result<V2FailureProof, Failure> {
    if !is_v2_failure_code(failure_code) {
        return Err(Failure::Terminal(
            "AGENT_RUN_V2_TERMINAL_PROOF_INVALID",
            failure_code.to_owned(),
        ));
    }
    v2_failure_proof(json!({
        "schemaVersion":"agent-run-definitive-failure-proof.v1",
        "runId":run_id,
        "failureCode":failure_code,
        "detailSha256":sha256(detail.as_bytes()),
        "redacted":true,
    }))
}

fn v2_failure_proof(payload: Value) -> Result<V2FailureProof, Failure> {
    Ok(V2FailureProof {
        sha256: sha256(&canonical_bytes(&payload)?),
        payload,
    })
}

fn v2_terminal_failure_code(code: &str) -> &'static str {
    match code {
        "PROVIDER_UNAVAILABLE" => "PROVIDER_UNAVAILABLE",
        "AGENT_OUTPUT_SCHEMA_INVALID" | "AGENT_OUTPUT_INVALID" => "OUTPUT_SCHEMA_INVALID",
        "AGENT_CITATION_INVALID" => "CITATION_INVALID",
        "AGENT_SOURCE_USE_RIGHTS_DENIED" => "RIGHTS_DENIED",
        "AGENT_PROVIDER_CLASSIFICATION_DENIED"
        | "AGENT_SOURCE_CLASSIFICATION_BLOCKED"
        | "AGENT_SOURCE_CLASSIFICATION_MISSING" => "CLASSIFICATION_DENIED",
        _ => "INTERNAL_EXECUTION_FAILED",
    }
}

/// Hook for runner terminal/retry branches. `false` preserves the legacy v1
/// path; v2 is settled under its exact current job and receipt fences.
async fn handle_agent_run_v2_failure(
    pool: &PgPool,
    job: &ClaimedJob,
    code: &str,
    detail: &str,
    retrying: bool,
) -> Result<bool, JobError> {
    let Some(run_id) = job
        .payload
        .get("agentRunId")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
    else {
        return Ok(false);
    };
    let version = sqlx::query_scalar!(
        "SELECT run_contract_version FROM ops.agent_runs WHERE id=$1",
        run_id,
    )
    .fetch_optional(pool)
    .await
    .map_err(JobError::Database)?;
    if version != Some(2) {
        return Ok(false);
    }
    let fence = load_agent_run_v2_failure_fence(pool, job, run_id).await?;
    match v2_failure_disposition(code, retrying) {
        V2FailureDisposition::ReconciliationRequired => {
            mark_agent_run_v2_reconciliation_required(
                pool,
                run_id,
                &fence,
                v2_ambiguity_proof(run_id, detail).map_err(failure_hook_contract_error)?,
            )
            .await?;
        }
        V2FailureDisposition::DefinitiveFailure => {
            let failure_code = v2_terminal_failure_code(code);
            complete_agent_run_v2_definitive_failure(
                pool,
                run_id,
                &fence,
                failure_code,
                v2_definitive_failure_proof(run_id, failure_code, detail)
                    .map_err(failure_hook_contract_error)?,
            )
            .await?;
        }
    }
    Ok(true)
}

fn failure_hook_contract_error(_failure: Failure) -> JobError {
    JobError::InvalidConfiguration
}

async fn load_agent_run_v2_failure_fence(
    pool: &PgPool,
    job: &ClaimedJob,
    run_id: Uuid,
) -> Result<V2AgentRunFence, JobError> {
    let row = sqlx::query!(
        "SELECT run.version,receipt.receipt_id,receipt.receipt_sha256 \
           FROM ops.agent_runs AS run \
           JOIN LATERAL (SELECT receipt_id,receipt_sha256 \
             FROM ops.agent_run_control_receipts WHERE agent_run_id=run.id \
             ORDER BY aggregate_version DESC LIMIT 1) AS receipt ON true \
          WHERE run.id=$1 AND run.run_contract_version=2 AND run.status='RUNNING'",
        run_id,
    )
    .fetch_optional(pool)
    .await
    .map_err(JobError::Database)?
    .ok_or(JobError::StaleFence)?;
    let transition = v2_agent_run_fence(
        run_id,
        V2JobFence {
            job_id: job.id,
            lease_token: job.fence.lease_token,
            fencing_token: job.fence.fencing_token,
        },
        V2ClaimFenceRow {
            version: Some(row.version),
            receipt_id: Some(row.receipt_id),
            receipt_sha256: Some(row.receipt_sha256),
        },
    )
    .map_err(failure_hook_contract_error)?;
    match transition {
        AgentRunTransition::V2(fence) => Ok(fence),
        AgentRunTransition::V1 => Err(JobError::StaleFence),
    }
}

async fn mark_agent_run_v2_reconciliation_required(
    pool: &PgPool,
    run_id: Uuid,
    fence: &V2AgentRunFence,
    proof: V2FailureProof,
) -> Result<(), JobError> {
    let row = sqlx::query!(
        "SELECT version,reconciliation_receipt_id,reconciliation_receipt_sha256,replayed \
           FROM ops.mark_agent_run_reconciliation_required_worker_v2(\
             $1,$2,$3,$4,$5,$6,$7,$8,$9)",
        run_id,
        fence.expected_version,
        fence.prior_receipt_id,
        &fence.prior_receipt_sha256,
        fence.job_id,
        fence.lease_token,
        fence.job_fencing_token,
        proof.payload,
        proof.sha256,
    )
    .fetch_optional(pool)
    .await
    .map_err(JobError::Database)?
    .ok_or(JobError::StaleFence)?;
    validate_failure_owner_result(
        run_id,
        fence.expected_version,
        V2OwnerResultRow {
            version: row.version,
            receipt_id: row.reconciliation_receipt_id,
            receipt_sha256: row.reconciliation_receipt_sha256,
            replayed: row.replayed,
        },
    )
}

async fn complete_agent_run_v2_definitive_failure(
    pool: &PgPool,
    run_id: Uuid,
    fence: &V2AgentRunFence,
    failure_code: &str,
    proof: V2FailureProof,
) -> Result<(), JobError> {
    let arguments =
        V2CompletionArguments::definitive_failure(failure_code, &proof.payload, &proof.sha256)
            .map_err(failure_hook_contract_error)?;
    let row = sqlx::query!(
        "SELECT version,terminal_receipt_id,terminal_receipt_sha256,replayed \
           FROM ops.complete_agent_run_worker_v2(\
             $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16)",
        run_id,
        fence.expected_version,
        fence.prior_receipt_id,
        &fence.prior_receipt_sha256,
        fence.job_id,
        fence.lease_token,
        fence.job_fencing_token,
        arguments.next_status,
        arguments.provider,
        arguments.model,
        arguments.output_payload,
        arguments.output_sha256,
        arguments.failure_code,
        arguments.failure_proof,
        arguments.failure_proof_sha256,
        arguments.actual_cost,
    )
    .fetch_optional(pool)
    .await
    .map_err(JobError::Database)?
    .ok_or(JobError::StaleFence)?;
    validate_failure_owner_result(
        run_id,
        fence.expected_version,
        V2OwnerResultRow {
            version: row.version,
            receipt_id: row.terminal_receipt_id,
            receipt_sha256: row.terminal_receipt_sha256,
            replayed: row.replayed,
        },
    )
}

fn validate_failure_owner_result(
    run_id: Uuid,
    expected_version: i64,
    row: V2OwnerResultRow,
) -> Result<(), JobError> {
    v2_owner_result(run_id, expected_version, row)
        .map(|_| ())
        .map_err(failure_hook_contract_error)
}

#[cfg(test)]
mod analysis_agent_v2_transition_tests {
    use super::*;

    const SHA: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    fn id(value: u128) -> Uuid {
        Uuid::from_u128(value)
    }

    fn job_fence() -> V2JobFence {
        V2JobFence {
            job_id: id(2),
            lease_token: id(3),
            fencing_token: 7,
        }
    }

    #[test]
    fn v1_routing_remains_closed_to_v2() {
        assert_eq!(
            agent_run_contract_route_for(1, id(1)).ok(),
            Some(AgentRunContractRoute::V1),
        );
        assert_eq!(
            agent_run_contract_route_for(2, id(1)).ok(),
            Some(AgentRunContractRoute::V2),
        );
        assert!(agent_run_contract_route_for(3, id(1)).is_err());
    }

    #[test]
    fn v2_claim_maps_job_and_receipt_fences_exactly() {
        let transition = v2_agent_run_fence(
            id(1),
            job_fence(),
            V2ClaimFenceRow {
                version: Some(2),
                receipt_id: Some(id(4)),
                receipt_sha256: Some(SHA.to_owned()),
            },
        );
        assert!(matches!(
            transition,
            Ok(AgentRunTransition::V2(V2AgentRunFence {
                expected_version: 2,
                prior_receipt_id,
                prior_receipt_sha256,
                job_id,
                lease_token,
                job_fencing_token: 7,
            })) if prior_receipt_id == id(4)
                && prior_receipt_sha256 == SHA
                && job_id == id(2)
                && lease_token == id(3)
        ));
    }

    #[test]
    fn v2_claim_missing_version_or_digest_fails_closed() {
        for row in [
            V2ClaimFenceRow {
                version: None,
                receipt_id: Some(id(4)),
                receipt_sha256: Some(SHA.to_owned()),
            },
            V2ClaimFenceRow {
                version: Some(2),
                receipt_id: Some(id(4)),
                receipt_sha256: None,
            },
        ] {
            assert!(matches!(
                v2_agent_run_fence(id(1), job_fence(), row),
                Err(Failure::Terminal("AGENT_RUN_V2_RECEIPT_INVALID", _))
            ));
        }
    }

    #[test]
    fn terminal_output_and_failure_proofs_keep_exact_null_shapes() {
        let output = json!({"status":"POLICY_BLOCKED"});
        let success = V2CompletionArguments::validated_output(
            "POLICY_BLOCKED",
            "none",
            "none",
            &output,
            SHA,
            5,
        )
        .ok();
        assert!(matches!(
            success,
            Some(V2CompletionArguments {
                provider: Some("none"),
                model: Some("none"),
                output_payload: Some(_),
                output_sha256: Some(SHA),
                failure_code: None,
                failure_proof: None,
                failure_proof_sha256: None,
                actual_cost: Some(_),
                ..
            })
        ));
        let proof = json!({"code":"INTERNAL_EXECUTION_FAILED","redacted":true});
        let failure =
            V2CompletionArguments::definitive_failure("INTERNAL_EXECUTION_FAILED", &proof, SHA)
                .ok();
        assert!(matches!(
            failure,
            Some(V2CompletionArguments {
                next_status: "FAILED",
                provider: None,
                model: None,
                output_payload: None,
                output_sha256: None,
                failure_code: Some("INTERNAL_EXECUTION_FAILED"),
                failure_proof: Some(_),
                failure_proof_sha256: Some(SHA),
                actual_cost: Some(_),
            })
        ));
    }

    #[test]
    fn terminal_result_requires_next_version_and_receipt_digest() {
        let valid = v2_owner_result(
            id(1),
            2,
            V2OwnerResultRow {
                version: Some(3),
                receipt_id: Some(id(5)),
                receipt_sha256: Some(SHA.to_owned()),
                replayed: Some(false),
            },
        );
        assert!(matches!(valid, Ok(V2OwnerResult { version: 3, .. })));
        assert!(
            v2_owner_result(
                id(1),
                2,
                V2OwnerResultRow {
                    version: Some(3),
                    receipt_id: Some(id(5)),
                    receipt_sha256: None,
                    replayed: Some(false),
                },
            )
            .is_err()
        );
    }

    #[test]
    fn unknown_or_retryable_failure_requires_reconciliation() {
        use V2FailureDisposition::{DefinitiveFailure, ReconciliationRequired};
        for (code, retrying, expected) in [
            ("PROVIDER_OUTCOME_UNKNOWN", false, ReconciliationRequired),
            ("PROVIDER_UNAVAILABLE", true, ReconciliationRequired),
            ("PROVIDER_UNAVAILABLE", false, DefinitiveFailure),
        ] {
            assert_eq!(v2_failure_disposition(code, retrying), expected);
        }
    }

    #[test]
    fn failure_proofs_bind_run_code_and_redacted_detail_digest() {
        let ambiguity_detail = "provider response unavailable";
        let ambiguity_detail_sha256 = sha256(ambiguity_detail.as_bytes());
        let ambiguity = v2_ambiguity_proof(id(1), ambiguity_detail).ok();
        assert!(matches!(
            ambiguity,
            Some(V2FailureProof { payload, sha256 })
                if payload.get("schemaVersion").and_then(Value::as_str)
                    == Some("agent-run-ambiguity-proof.v1")
                    && payload.get("runId") == Some(&json!(id(1)))
                    && payload.get("reasonCode").and_then(Value::as_str)
                        == Some("PROVIDER_OUTCOME_UNKNOWN")
                    && payload.get("detailSha256").and_then(Value::as_str)
                        == Some(ambiguity_detail_sha256.as_str())
                    && is_sha256_text(&sha256)
        ));
        let failure_detail = "timeout";
        let failure_detail_sha256 = sha256(failure_detail.as_bytes());
        let failure =
            v2_definitive_failure_proof(id(1), "PROVIDER_UNAVAILABLE", failure_detail).ok();
        assert!(matches!(
            failure,
            Some(V2FailureProof { payload, sha256 })
                if payload.get("failureCode").and_then(Value::as_str)
                    == Some("PROVIDER_UNAVAILABLE")
                    && payload.get("detailSha256").and_then(Value::as_str)
                        == Some(failure_detail_sha256.as_str())
                    && payload.get("redacted").and_then(Value::as_bool) == Some(true)
                    && is_sha256_text(&sha256)
        ));
    }
}
