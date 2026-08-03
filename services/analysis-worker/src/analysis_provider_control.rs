const PROVIDER_CONTROL_CLAIM_SCHEMA: &str = "provider-control-execution-claim.v1";
const PROVIDER_CONTROL_RESULT_SCHEMA: &str = "provider-control-execution-result.v1";
const PROVIDER_CONTROL_ACTION_KIND: &str = "PROVIDER_CONTROL";
const PROVIDER_CONTROL_TARGET_COMMAND: &str = "private.ExecuteProviderControl";
const PROVIDER_CONTROL_CONSUMER: &str = "provider-control-execution-worker";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ProviderControlOperationId {
    DisableProviderRouting,
    TestProviderConnection,
    UpgradeProviderModel,
    SetModelAutoUpgrade,
}

impl ProviderControlOperationId {
    fn parse(value: &str) -> Result<Self, Failure> {
        match value {
            "disableProviderRouting" => Ok(Self::DisableProviderRouting),
            "testProviderConnection" => Ok(Self::TestProviderConnection),
            "upgradeProviderModel" => Ok(Self::UpgradeProviderModel),
            "setModelAutoUpgrade" => Ok(Self::SetModelAutoUpgrade),
            _ => Err(provider_control_invalid("operationId")),
        }
    }

    const fn as_str(self) -> &'static str {
        match self {
            Self::DisableProviderRouting => "disableProviderRouting",
            Self::TestProviderConnection => "testProviderConnection",
            Self::UpgradeProviderModel => "upgradeProviderModel",
            Self::SetModelAutoUpgrade => "setModelAutoUpgrade",
        }
    }
}

#[derive(Debug, Eq, PartialEq)]
enum ProviderControlBranch {
    Disable,
    Test {
        model: String,
    },
    Upgrade {
        model: String,
    },
    AutoUpgrade {
        enabled: bool,
        track: Option<String>,
    },
}

impl ProviderControlBranch {
    fn relay_model(&self) -> Option<&str> {
        match self {
            Self::Test { model } | Self::Upgrade { model } => Some(model),
            Self::Disable | Self::AutoUpgrade { .. } => None,
        }
    }
}

#[derive(Debug)]
struct ProviderControlClaim {
    execution_id: Uuid,
    generation: i64,
    attempt_id: Uuid,
    fencing_token: i64,
    operation_id: ProviderControlOperationId,
    provider_id: Uuid,
    expected_provider_version: i64,
    provider_routing_snapshot: Value,
    provider_idempotency_key_sha256: String,
    branch: ProviderControlBranch,
}

#[derive(Debug)]
struct ProviderControlEventBinding {
    event_id: Uuid,
    execution_id: Uuid,
    generation: i64,
    execution_digest: String,
    target_request_sha256: String,
}

async fn analysis_event(state: &State, job: &ClaimedJob) -> Result<Value, Failure> {
    match job.payload.get("eventType").and_then(Value::as_str) {
        Some("workflow.rule_activation_applied.v1") => activation_event(&state.pool, job).await,
        Some("dataset.snapshot_created.v1") => {
            analysis_detection_sweep::ready_detection_snapshot_event(&state.pool, job).await
        }
        Some("action.execution_authorized.v1")
            if job
                .payload
                .pointer("/payload/actionKind")
                .and_then(Value::as_str)
                == Some(PROVIDER_CONTROL_ACTION_KIND) =>
        {
            provider_control_event(state, job).await
        }
        Some(event_type) => Err(Failure::Terminal(
            "UNSUPPORTED_ANALYSIS_EVENT",
            event_type.to_owned(),
        )),
        None => Err(Failure::Terminal(
            "INVALID_ANALYSIS_EVENT",
            "eventType".to_owned(),
        )),
    }
}

async fn provider_control_event(state: &State, job: &ClaimedJob) -> Result<Value, Failure> {
    let event = provider_control_event_binding(job)?;
    let claim = claim_provider_control_execution(state, &event).await?;
    tracing::info!(
        execution_id = %claim.execution_id,
        attempt_id = %claim.attempt_id,
        provider_id = %claim.provider_id,
        provider_version = claim.expected_provider_version,
        operation_id = claim.operation_id.as_str(),
        "provider control execution claimed",
    );
    let result = match execute_provider_control(state, &claim).await {
        Ok(result) => result,
        Err(failure) => {
            fail_provider_control_execution(state, job, &claim, &failure).await?;
            return Err(provider_control_delivery_terminal(failure));
        }
    };
    match complete_provider_control_execution(state, job, event.event_id, &claim, &result).await {
        Ok(receipt) => Ok(receipt),
        Err(failure) => {
            fail_provider_control_execution(state, job, &claim, &failure).await?;
            Err(provider_control_delivery_terminal(failure))
        }
    }
}

fn provider_control_event_binding(
    job: &ClaimedJob,
) -> Result<ProviderControlEventBinding, Failure> {
    if job.job_type != "EVENT_DELIVERY"
        || job.payload.get("consumerId").and_then(Value::as_str) != Some(PROVIDER_CONTROL_CONSUMER)
        || job.payload.get("eventType").and_then(Value::as_str)
            != Some("action.execution_authorized.v1")
    {
        return Err(provider_control_invalid("event binding"));
    }
    let event_id = payload_uuid(&job.payload, "eventId")?;
    let execution_id = pointer_uuid(&job.payload, "/payload/executionId")?;
    if job
        .payload
        .get("aggregateId")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        != Some(execution_id)
        || job
            .payload
            .pointer("/payload/actionKind")
            .and_then(Value::as_str)
            != Some(PROVIDER_CONTROL_ACTION_KIND)
        || job
            .payload
            .pointer("/payload/targetCommand")
            .and_then(Value::as_str)
            != Some(PROVIDER_CONTROL_TARGET_COMMAND)
    {
        return Err(provider_control_invalid("authorization event"));
    }
    let generation = required_positive_i64_at(&job.payload, "/payload/generation")?;
    let execution_digest = required_sha256_at(&job.payload, "/payload/executionDigest")?;
    let target_request_sha256 = required_sha256_at(&job.payload, "/payload/targetRequestSha256")?;
    Ok(ProviderControlEventBinding {
        event_id,
        execution_id,
        generation,
        execution_digest,
        target_request_sha256,
    })
}

async fn claim_provider_control_execution(
    state: &State,
    event: &ProviderControlEventBinding,
) -> Result<ProviderControlClaim, Failure> {
    let claim = sqlx::query_scalar!(
        "SELECT ops.claim_provider_control_execution_v1( \
           $1,$2,$3,CAST($4 AS char(64)),CAST($5 AS char(64)),$6)",
        event.event_id,
        event.execution_id,
        event.generation,
        event.execution_digest,
        event.target_request_sha256,
        state.config.worker_id,
    )
    .fetch_one(&state.pool)
    .await
    .map_err(database)?
    .ok_or_else(|| provider_control_invalid("empty claim"))?;
    parse_provider_control_claim(&claim)
}

async fn execute_provider_control(
    state: &State,
    claim: &ProviderControlClaim,
) -> Result<Value, Failure> {
    let Some(model) = claim.branch.relay_model() else {
        return Ok(json!({
            "schemaVersion": PROVIDER_CONTROL_RESULT_SCHEMA,
            "outcome": "NO_EGRESS",
            "operationId": claim.operation_id.as_str(),
        }));
    };
    let proof = provider_control_relay_connection_test(state, claim, model).await?;
    provider_control_success_result(claim.operation_id, proof)
}

async fn provider_control_relay_connection_test(
    state: &State,
    claim: &ProviderControlClaim,
    model: &str,
) -> Result<RelayConnectionProof, Failure> {
    let target = provider_control_relay_target(claim)?;
    validate_relay_target(target, RELAY_CHAT_PATH)?;
    let gateway = state
        .config
        .egress_ai_url
        .as_ref()
        .ok_or_else(|| Failure::Terminal("AI_EGRESS_MISSING", claim.provider_id.to_string()))?;
    let request = relay_connection_test_request(model);
    let request_sha256 = sha256(&canonical_bytes(&request)?);
    let response = state
        .client
        .post(gateway.clone())
        .header("x-gurine-egress-caller", "analysis-worker")
        .header("x-gurine-ai-provider", RELAY_PROVIDER)
        .header("x-gurine-egress-target", target)
        .header(
            "x-gurine-idempotency-key",
            &claim.provider_idempotency_key_sha256,
        )
        .header("x-gurine-source-fetch-request-sha256", &request_sha256)
        .json(&request)
        .send()
        .await
        .map_err(|error| Failure::Retryable("PROVIDER_UNAVAILABLE", error.to_string()))?;
    let observation = observe_relay_gateway_response(response, &request_sha256).await?;
    let completion = parse_relay_completion(&observation.body, model, "investigator")?;
    if !matches!(completion.envelope, RelayEnvelope::Final(_)) {
        return Err(relay_response_error("connection test envelope"));
    }
    Ok(RelayConnectionProof {
        gateway_receipt_sha256: observation.gateway_receipt_sha256,
        payload_sha256: observation.payload_sha256,
        provider_request_id_hash: completion.request_id_hash,
        usage: completion.usage,
    })
}

fn provider_control_relay_target(claim: &ProviderControlClaim) -> Result<&str, Failure> {
    claim
        .provider_routing_snapshot
        .pointer("/routingPolicy/targetUrl")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::Terminal("PROVIDER_TARGET_MISSING", claim.provider_id.to_string()))
}

fn provider_control_success_result(
    operation_id: ProviderControlOperationId,
    proof: RelayConnectionProof,
) -> Result<Value, Failure> {
    validate_provider_control_proof(&proof)?;
    // `evidence_sha256` binds the relay's original OpenAI `usage` object.
    // The normalized units below are for typed receipt consumption and are
    // deliberately not reserialized to manufacture a second usage digest.
    Ok(json!({
        "schemaVersion": PROVIDER_CONTROL_RESULT_SCHEMA,
        "outcome": "PROVIDER_SUCCESS",
        "operationId": operation_id.as_str(),
        "gatewayReceiptSha256": proof.gateway_receipt_sha256,
        "providerRequestIdHash": proof.provider_request_id_hash,
        "providerPayloadSha256": proof.payload_sha256,
        "usageCanonicalSha256": proof.usage.evidence_sha256,
        "usage": {
            "inputUnits": proof.usage.input_units,
            "outputUnits": proof.usage.output_units,
            "cachedInputUnits": proof.usage.cached_input_units,
            "billableUnits": proof.usage.billable_units,
        },
    }))
}

fn validate_provider_control_proof(proof: &RelayConnectionProof) -> Result<(), Failure> {
    for (field, value) in [
        (
            "gatewayReceiptSha256",
            proof.gateway_receipt_sha256.as_str(),
        ),
        ("providerPayloadSha256", proof.payload_sha256.as_str()),
        (
            "providerRequestIdHash",
            proof.provider_request_id_hash.as_str(),
        ),
        ("usageCanonicalSha256", proof.usage.evidence_sha256.as_str()),
    ] {
        if !is_lower_sha256(value) {
            return Err(provider_control_invalid(field));
        }
    }
    if proof.usage.input_units < 0
        || proof.usage.output_units < 0
        || proof
            .usage
            .cached_input_units
            .is_some_and(|value| value < 0)
        || proof
            .usage
            .input_units
            .checked_add(proof.usage.output_units)
            != Some(proof.usage.billable_units)
    {
        return Err(provider_control_invalid("usage"));
    }
    Ok(())
}

async fn complete_provider_control_execution(
    state: &State,
    job: &ClaimedJob,
    event_id: Uuid,
    claim: &ProviderControlClaim,
    result: &Value,
) -> Result<Value, Failure> {
    let mut tx = state.pool.begin().await.map_err(database)?;
    let receipt = sqlx::query_scalar!(
        "SELECT ops.complete_provider_control_execution_v1($1,$2,$3,$4,$5)",
        claim.execution_id,
        claim.generation,
        claim.fencing_token,
        result,
        job.id,
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(database)?
    .ok_or_else(|| provider_control_invalid("empty completion receipt"))?;
    let changed = sqlx::query!(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' \
         WHERE consumer=$2 AND event_id=$1 AND processed_at IS NULL",
        event_id,
        PROVIDER_CONTROL_CONSUMER,
    )
    .execute(&mut *tx)
    .await
    .map_err(database)?
    .rows_affected();
    if changed != 1 {
        return Err(Failure::Terminal(
            "INBOX_FENCE_FAILED",
            event_id.to_string(),
        ));
    }
    tx.commit().await.map_err(database)?;
    Ok(receipt)
}

async fn fail_provider_control_execution(
    state: &State,
    job: &ClaimedJob,
    claim: &ProviderControlClaim,
    failure: &Failure,
) -> Result<(), Failure> {
    let (code, retryable) =
        provider_control_failure_disposition(failure, job.attempt, job.max_attempts);
    let detail_sha256 = sha256(failure_detail(failure).as_bytes());
    sqlx::query_scalar!(
        "SELECT ops.fail_provider_control_execution_v1( \
           $1,$2,$3,$4,CAST($5 AS char(64)),$6,$7)",
        claim.execution_id,
        claim.generation,
        claim.fencing_token,
        code,
        detail_sha256,
        retryable,
        job.id,
    )
    .fetch_one(&state.pool)
    .await
    .map_err(database)?
    .ok_or_else(|| provider_control_invalid("empty failure receipt"))?;
    Ok(())
}

fn provider_control_failure_disposition(
    failure: &Failure,
    attempt: i32,
    max_attempts: i32,
) -> (&'static str, bool) {
    match failure {
        Failure::Terminal(code, _) => (*code, false),
        Failure::Retryable(code, _) => (*code, attempt < max_attempts),
    }
}

fn provider_control_delivery_terminal(failure: Failure) -> Failure {
    match failure {
        Failure::Terminal(code, detail) | Failure::Retryable(code, detail) => {
            Failure::Terminal(code, detail)
        }
    }
}

include!("analysis_provider_control_claim.rs");

#[cfg(test)]
#[path = "analysis_provider_control_tests.rs"]
mod analysis_provider_control_tests;
