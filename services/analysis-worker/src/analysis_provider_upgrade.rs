struct ClaimedRelayUpgrade {
    attempt_id: Uuid,
    provider_id: Uuid,
    target_model_id: String,
    target_track: String,
    attempt_kind: String,
    expected_provider_version: i64,
    requested_data_policy: Option<Value>,
    connection_test_id: Uuid,
    routing_policy: Value,
}

struct RelayConnectionProof {
    gateway_receipt_sha256: String,
    payload_sha256: String,
    provider_request_id_hash: String,
    usage: RelayUsage,
}

async fn provider_model_upgrade(
    state: &State,
    job: &ClaimedJob,
) -> Result<Value, Failure> {
    let attempt_id = payload_uuid(&job.payload, "providerModelUpgradeAttemptId")?;
    let upgrade = claim_relay_upgrade(&state.pool, attempt_id).await?;
    let data_policy = resolve_relay_upgrade_policy(&upgrade)?;
    let pricing = LocalPricing::from_routing_policy(&upgrade.routing_policy)?;
    let proof = relay_connection_test(state, &upgrade).await?;
    let actual_micros = relay_actual_cost_micros(&proof.usage, &pricing)?;
    persist_relay_upgrade_success(
        state,
        job,
        &upgrade,
        &data_policy,
        &pricing,
        &proof,
        actual_micros,
    )
    .await?;
    Ok(json!({
        "providerModelUpgradeAttemptId": attempt_id,
        "providerId": upgrade.provider_id,
        "status": "SUCCEEDED",
        "targetModelId": upgrade.target_model_id,
    }))
}

async fn claim_relay_upgrade(
    pool: &PgPool,
    attempt_id: Uuid,
) -> Result<ClaimedRelayUpgrade, Failure> {
    let mut tx = pool.begin().await.map_err(database)?;
    let row = sqlx::query!(
        "UPDATE ops.provider_model_upgrade_attempts a \
         SET status='RUNNING',started_at=COALESCE(started_at,clock_timestamp()) \
         FROM ops.provider_configs p,ops.relay_model_catalog m \
         WHERE a.id=$1 AND a.provider_id=p.id AND a.target_model_id=m.model_id \
           AND a.status IN ('QUEUED','RUNNING') AND p.provider_type='relay' \
           AND p.version=a.expected_provider_version AND m.active \
         RETURNING a.provider_id,a.target_model_id,a.attempt_kind,a.owner_user_id, \
           a.expected_provider_version,a.requested_data_policy,a.connection_test_id, \
           p.routing_policy,m.track",
        attempt_id,
    )
    .fetch_optional(&mut *tx)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("PROVIDER_MODEL_UPGRADE_FENCE_FAILED", attempt_id.to_string()))?;
    let connection_test_id = row.connection_test_id.ok_or_else(|| {
        Failure::Terminal("PROVIDER_CONNECTION_TEST_MISSING", attempt_id.to_string())
    })?;
    sqlx::query!(
        "UPDATE ops.provider_connection_tests SET status='RUNNING', \
           started_at=COALESCE(started_at,clock_timestamp()) \
         WHERE id=$1 AND status IN ('QUEUED','RUNNING')",
        connection_test_id,
    )
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    tx.commit().await.map_err(database)?;
    Ok(ClaimedRelayUpgrade {
        attempt_id,
        provider_id: row.provider_id,
        target_model_id: row.target_model_id,
        target_track: row
            .track
            .ok_or_else(|| Failure::Terminal("RELAY_MODEL_TRACK_UNAVAILABLE", attempt_id.to_string()))?,
        attempt_kind: row.attempt_kind,
        expected_provider_version: row.expected_provider_version,
        requested_data_policy: row.requested_data_policy,
        connection_test_id,
        routing_policy: row.routing_policy,
    })
}

fn resolve_relay_upgrade_policy(
    upgrade: &ClaimedRelayUpgrade,
) -> Result<RelayDataPolicy, Failure> {
    match upgrade
        .routing_policy
        .pointer("/dataPolicy/state")
        .and_then(Value::as_str)
    {
        Some("CONFIGURED") if upgrade.requested_data_policy.is_none() => {
            RelayDataPolicy::from_routing_policy(&upgrade.routing_policy)
        }
        Some("UNCONFIGURED") if upgrade.attempt_kind == "MANUAL" => {
            relay_data_policy_from_request(upgrade.requested_data_policy.as_ref())
        }
        Some("CONFIGURED") => Err(relay_policy_error("unexpected requested policy")),
        Some("UNCONFIGURED") => Err(Failure::Terminal(
            "PROVIDER_DATA_POLICY_UNCONFIGURED",
            upgrade.attempt_id.to_string(),
        )),
        _ => Err(relay_policy_error("state")),
    }
}

fn relay_data_policy_from_request(value: Option<&Value>) -> Result<RelayDataPolicy, Failure> {
    let object = value
        .and_then(Value::as_object)
        .ok_or_else(|| relay_policy_error("requestedDataPolicy"))?;
    if object.len() != 3
        || !object.contains_key("processingRegion")
        || !object.contains_key("retentionMode")
        || !object.contains_key("policyVersion")
    {
        return Err(relay_policy_error("requestedDataPolicy shape"));
    }
    let processing_region = relay_policy_text(object, "processingRegion")?;
    let retention_mode = relay_policy_text(object, "retentionMode")?;
    let policy_version = relay_policy_text(object, "policyVersion")?;
    if !valid_region(&processing_region)
        || !matches!(
            retention_mode.as_str(),
            "ZERO_RETENTION" | "BOUNDED_PROVIDER_RETENTION" | "LOCAL_ONLY"
        )
    {
        return Err(relay_policy_error("requestedDataPolicy value"));
    }
    let canonical = json!({
        "policyVersion": policy_version,
        "processingRegion": processing_region,
        "retentionMode": retention_mode,
    });
    Ok(RelayDataPolicy {
        processing_region,
        retention_mode,
        policy_version,
        policy_sha256: sha256(&canonical_bytes(&canonical)?),
    })
}

async fn relay_connection_test(
    state: &State,
    upgrade: &ClaimedRelayUpgrade,
) -> Result<RelayConnectionProof, Failure> {
    let target = upgrade
        .routing_policy
        .get("targetUrl")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::Terminal("PROVIDER_TARGET_MISSING", upgrade.provider_id.to_string()))?;
    if !relay_target_has_path(target, RELAY_CHAT_PATH) {
        return Err(Failure::Terminal("PROVIDER_TARGET_INVALID", target.to_owned()));
    }
    let gateway = state
        .config
        .egress_ai_url
        .as_ref()
        .ok_or_else(|| Failure::Terminal("AI_EGRESS_MISSING", upgrade.provider_id.to_string()))?;
    let request = relay_connection_test_request(&upgrade.target_model_id);
    let request_sha256 = sha256(&canonical_bytes(&request)?);
    let response = state
        .client
        .post(gateway.clone())
        .header("x-gurine-egress-caller", "analysis-worker")
        .header("x-gurine-ai-provider", RELAY_PROVIDER)
        .header("x-gurine-egress-target", target)
        .header(
            "x-gurine-idempotency-key",
            sha256(format!("relay-model-upgrade-test\0{}", upgrade.attempt_id).as_bytes()),
        )
        .header("x-gurine-source-fetch-request-sha256", &request_sha256)
        .json(&request)
        .send()
        .await
        .map_err(|error| Failure::Retryable("PROVIDER_UNAVAILABLE", error.to_string()))?;
    let observation = observe_relay_gateway_response(response, &request_sha256).await?;
    let completion = parse_relay_completion(
        &observation.body,
        &upgrade.target_model_id,
        "investigator",
    )?;
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

fn relay_connection_test_request(model: &str) -> Value {
    json!({
        "max_completion_tokens": 16,
        "messages": [
            {"role":"system","content":"Return exactly one JSON object with status set to ok."},
            {"role":"user","content":"{}"}
        ],
        "model": model,
        "response_format": {"type":"json_object"}
    })
}

async fn persist_relay_upgrade_success(
    state: &State,
    job: &ClaimedJob,
    upgrade: &ClaimedRelayUpgrade,
    data_policy: &RelayDataPolicy,
    pricing: &LocalPricing,
    proof: &RelayConnectionProof,
    actual_micros: i64,
) -> Result<(), Failure> {
    let mut tx = state.pool.begin().await.map_err(database)?;
    let (before_model, after_version) = apply_relay_provider_upgrade(
        &mut tx,
        upgrade,
        data_policy,
    )
    .await?;
    persist_relay_connection_test_success(&mut tx, upgrade, proof).await?;
    persist_relay_upgrade_attempt_success(&mut tx, upgrade, proof).await?;
    let cost_event_id = persist_relay_upgrade_cost(
        &mut tx,
        job,
        upgrade,
        pricing,
        &proof.usage,
        actual_micros,
    )
    .await?;
    let audit_event_id = persist_relay_upgrade_success_audit(
        &mut tx,
        upgrade,
        data_policy,
        proof,
    )
    .await?;
    insert_relay_upgrade_success_receipt(
        &mut tx,
        upgrade,
        before_model.as_deref(),
        after_version,
        data_policy,
        proof,
        audit_event_id,
        cost_event_id,
    )
    .await?;
    tx.commit().await.map_err(database)
}

async fn apply_relay_provider_upgrade(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    upgrade: &ClaimedRelayUpgrade,
    data_policy: &RelayDataPolicy,
) -> Result<(Option<String>, i64), Failure> {
    let current = sqlx::query!(
        "SELECT routing_policy,version FROM ops.provider_configs \
         WHERE id=$1 AND provider_type='relay' FOR UPDATE",
        upgrade.provider_id,
    )
    .fetch_optional(&mut **tx)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("RELAY_PROVIDER_MISSING", upgrade.provider_id.to_string()))?;
    if current.version != upgrade.expected_provider_version {
        return Err(Failure::Terminal(
            "PROVIDER_MODEL_UPGRADE_FENCE_FAILED",
            upgrade.attempt_id.to_string(),
        ));
    }
    let before_model = current
        .routing_policy
        .get("model")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let mut routing = current.routing_policy;
    apply_relay_upgrade_routing(&mut routing, upgrade, data_policy)?;
    let after_version = upgrade
        .expected_provider_version
        .checked_add(1)
        .ok_or_else(|| Failure::Terminal("PROVIDER_VERSION_INVALID", upgrade.provider_id.to_string()))?;
    let updated = sqlx::query!(
        "UPDATE ops.provider_configs SET enabled=true,routing_policy=$2, \
           data_retention_policy=$3,last_connection_test_at=clock_timestamp(), \
           last_connection_test_status='SUCCEEDED',version=version+1 \
         WHERE id=$1 AND version=$4 RETURNING version",
        upgrade.provider_id,
        routing,
        data_policy.retention_mode,
        upgrade.expected_provider_version,
    )
    .fetch_optional(&mut **tx)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("PROVIDER_MODEL_UPGRADE_FENCE_FAILED", upgrade.attempt_id.to_string()))?;
    if updated.version != after_version {
        return Err(Failure::Terminal("PROVIDER_VERSION_INVALID", upgrade.provider_id.to_string()));
    }
    Ok((before_model, after_version))
}

async fn persist_relay_upgrade_attempt_success(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    upgrade: &ClaimedRelayUpgrade,
    proof: &RelayConnectionProof,
) -> Result<(), Failure> {
    sqlx::query!(
        "UPDATE ops.provider_model_upgrade_attempts SET status='SUCCEEDED', \
           gateway_receipt_sha256=CAST($2 AS char(64)), \
           usage_evidence_sha256=CAST($3 AS char(64)),completed_at=clock_timestamp() \
         WHERE id=$1 AND status='RUNNING'",
        upgrade.attempt_id,
        proof.gateway_receipt_sha256,
        proof.usage.evidence_sha256,
    )
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    Ok(())
}

async fn persist_relay_upgrade_success_audit(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    upgrade: &ClaimedRelayUpgrade,
    data_policy: &RelayDataPolicy,
    proof: &RelayConnectionProof,
) -> Result<Uuid, Failure> {
    let audit_event_id: Uuid = sqlx::query_scalar!(
        "SELECT ops.record_relay_model_upgrade_success_audit_v1( \
           $1,CAST($2 AS char(64)),CAST($3 AS char(64)),CAST($4 AS char(64)))",
        upgrade.attempt_id,
        data_policy.policy_sha256,
        proof.gateway_receipt_sha256,
        proof.usage.evidence_sha256,
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(database)?
    .ok_or_else(|| database(sqlx::Error::Decode(Box::new(sqlx::error::UnexpectedNullError))))?;
    Ok(audit_event_id)
}

fn apply_relay_upgrade_routing(
    routing: &mut Value,
    upgrade: &ClaimedRelayUpgrade,
    data_policy: &RelayDataPolicy,
) -> Result<(), Failure> {
    let object = routing
        .as_object_mut()
        .ok_or_else(|| Failure::Terminal("PROVIDER_ROUTING_INVALID", upgrade.provider_id.to_string()))?;
    object.insert("model".to_owned(), json!(upgrade.target_model_id));
    object.insert("track".to_owned(), json!(upgrade.target_track));
    object.insert(
        "dataPolicy".to_owned(),
        json!({
            "state":"CONFIGURED",
            "processingRegion":data_policy.processing_region,
            "retentionMode":data_policy.retention_mode,
            "trainingUse":"PROHIBITED",
            "policyVersion":data_policy.policy_version,
            "policySha256":data_policy.policy_sha256,
        }),
    );
    Ok(())
}

async fn persist_relay_connection_test_success(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    upgrade: &ClaimedRelayUpgrade,
    proof: &RelayConnectionProof,
) -> Result<(), Failure> {
    let result = json!({
        "gatewayReceiptSha256":proof.gateway_receipt_sha256,
        "httpStatus":200,
        "payloadSha256":proof.payload_sha256,
        "providerRequestIdHash":proof.provider_request_id_hash,
        "redacted":true,
        "usageEvidenceSha256":proof.usage.evidence_sha256,
    });
    sqlx::query!(
        "UPDATE ops.provider_connection_tests SET status='SUCCEEDED',redacted_result=$2, \
           completed_at=clock_timestamp() WHERE id=$1 AND status='RUNNING'",
        upgrade.connection_test_id,
        result,
    )
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    Ok(())
}

async fn persist_relay_upgrade_cost(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    job: &ClaimedJob,
    upgrade: &ClaimedRelayUpgrade,
    pricing: &LocalPricing,
    usage: &RelayUsage,
    actual_micros: i64,
) -> Result<Uuid, Failure> {
    let cost_event_id = Uuid::new_v4();
    let amount = Decimal::new(actual_micros, 6);
    sqlx::query!(
        "INSERT INTO ops.cost_events( \
           id,provider_id,case_id,job_id,occurred_at,model,input_units,output_units,amount,currency,metadata) \
         VALUES($1,$2,NULL,$3,clock_timestamp(),$4,$5,$6,$7,'KRW',$8)",
        cost_event_id,
        upgrade.provider_id,
        job.id,
        upgrade.target_model_id,
        usage.input_units,
        usage.output_units,
        amount,
        json!({
            "attemptId":upgrade.attempt_id,
            "pricingSha256":pricing.digest,
            "pricingVersion":pricing.version,
            "redacted":true,
            "usageEvidenceSha256":usage.evidence_sha256,
        }),
    )
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    Ok(cost_event_id)
}

#[expect(
    clippy::too_many_arguments,
    reason = "immutable receipt repeats the complete applied upgrade evidence tuple"
)]
async fn insert_relay_upgrade_success_receipt(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    upgrade: &ClaimedRelayUpgrade,
    before_model: Option<&str>,
    after_version: i64,
    data_policy: &RelayDataPolicy,
    proof: &RelayConnectionProof,
    audit_event_id: Uuid,
    cost_event_id: Uuid,
) -> Result<(), Failure> {
    let receipt = RelayUpgradeReceipt::build(RelayUpgradeReceiptInput {
        receipt_id: Uuid::new_v4(),
        attempt_id: upgrade.attempt_id,
        provider_id: upgrade.provider_id,
        target_model_id: upgrade.target_model_id.clone(),
        attempt_kind: RelayUpgradeAttemptKind::parse(&upgrade.attempt_kind)?,
        outcome: RelayUpgradeReceiptOutcome::Applied,
        before_provider_version: upgrade.expected_provider_version,
        after_provider_version: after_version,
        before_model_id: before_model.map(str::to_owned),
        after_model_id: Some(upgrade.target_model_id.clone()),
        policy_sha256: Some(data_policy.policy_sha256.clone()),
        gateway_receipt_sha256: Some(proof.gateway_receipt_sha256.clone()),
        usage_evidence_sha256: Some(proof.usage.evidence_sha256.clone()),
        audit_event_id: Some(audit_event_id),
        incident_event_id: None,
        cost_event_id: Some(cost_event_id),
        recorded_at: OffsetDateTime::now_utc(),
    })?;
    sqlx::query!(
        "INSERT INTO ops.provider_model_upgrade_receipts( \
           id,attempt_id,provider_id,target_model_id,attempt_kind,outcome,before_provider_version, \
           after_provider_version,before_model_id,after_model_id,policy_sha256,gateway_receipt_sha256, \
           usage_evidence_sha256,audit_event_id,cost_event_id,receipt_canonical,canonical_receipt, \
           receipt_sha256,recorded_at) \
         VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$4,CAST($10 AS char(64)),CAST($11 AS char(64)), \
           CAST($12 AS char(64)),$13,$14,$15,$16,CAST($17 AS char(64)),$18)",
        receipt.receipt_id,
        upgrade.attempt_id,
        upgrade.provider_id,
        upgrade.target_model_id,
        receipt.attempt_kind.as_str(),
        receipt.outcome.as_str(),
        upgrade.expected_provider_version,
        after_version,
        before_model,
        data_policy.policy_sha256,
        proof.gateway_receipt_sha256,
        proof.usage.evidence_sha256,
        audit_event_id,
        cost_event_id,
        receipt.receipt_canonical,
        receipt.canonical_receipt,
        receipt.receipt_sha256,
        receipt.recorded_at,
    )
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    Ok(())
}

#[cfg(test)]
mod relay_upgrade_tests {
    use super::*;

    fn requested_data_policy() -> Value {
        json!({
            "processingRegion":"KR",
            "retentionMode":"ZERO_RETENTION",
            "policyVersion":"relay-policy-v1"
        })
    }

    fn unconfigured_upgrade(attempt_kind: &str) -> ClaimedRelayUpgrade {
        ClaimedRelayUpgrade {
            attempt_id: Uuid::from_u128(1),
            provider_id: Uuid::from_u128(2),
            target_model_id: "relay-v2".to_owned(),
            target_track: "relay-".to_owned(),
            attempt_kind: attempt_kind.to_owned(),
            expected_provider_version: 7,
            requested_data_policy: Some(requested_data_policy()),
            connection_test_id: Uuid::from_u128(3),
            routing_policy: json!({"dataPolicy":{"state":"UNCONFIGURED"}}),
        }
    }

    #[test]
    fn first_activation_policy_is_canonical_and_complete() {
        let policy = relay_data_policy_from_request(Some(&requested_data_policy()))
        .expect("valid first activation policy");
        assert_eq!(policy.processing_region, "KR");
        assert_eq!(
            policy.policy_sha256,
            sha256(&canonical_bytes(&json!({
                "policyVersion":"relay-policy-v1",
                "processingRegion":"KR",
                "retentionMode":"ZERO_RETENTION"
            })).expect("canonical policy"))
        );
    }

    #[test]
    fn first_activation_policy_rejects_extra_or_invalid_fields() {
        assert!(relay_data_policy_from_request(Some(&json!({
            "processingRegion":"KR",
            "retentionMode":"ZERO_RETENTION",
            "policyVersion":"relay-policy-v1",
            "invented":true
        }))).is_err());
        assert!(relay_data_policy_from_request(Some(&json!({
            "processingRegion":"unknown",
            "retentionMode":"ZERO_RETENTION",
            "policyVersion":"relay-policy-v1"
        }))).is_err());
    }

    #[test]
    fn manual_upgrade_can_supply_the_first_q7_policy() {
        let policy = resolve_relay_upgrade_policy(&unconfigured_upgrade("MANUAL"))
            .expect("MANUAL first activation policy");

        assert_eq!(policy.processing_region, "KR");
        assert_eq!(policy.retention_mode, "ZERO_RETENTION");
        assert_eq!(policy.policy_version, "relay-policy-v1");
    }

    #[test]
    fn auto_upgrade_rejects_unconfigured_q7_even_with_a_complete_request() {
        assert!(matches!(
            resolve_relay_upgrade_policy(&unconfigured_upgrade("AUTO")),
            Err(Failure::Terminal(
                "PROVIDER_DATA_POLICY_UNCONFIGURED",
                _
            ))
        ));
    }

    #[test]
    fn connection_test_request_uses_standard_openai_shape() {
        let request = relay_connection_test_request("gpt-new");
        assert_eq!(request["model"], "gpt-new");
        assert!(request.get("operation").is_none());
        assert_eq!(request["messages"][0]["role"], "system");
    }
}
