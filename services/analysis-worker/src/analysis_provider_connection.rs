async fn provider_connection_test(state: &State, job: &ClaimedJob) -> Result<Value, Failure> {
    let test_id = payload_uuid(&job.payload, "providerConnectionTestId")?;
    let row = sqlx::query!(
        "UPDATE ops.provider_connection_tests t SET status='RUNNING',            started_at=COALESCE(started_at,clock_timestamp())          FROM ops.provider_configs p WHERE t.id=$1 AND t.provider_id=p.id            AND t.status IN ('QUEUED','RUNNING')          RETURNING t.provider_id,t.test_model,p.provider_type,p.enabled,p.routing_policy",
        test_id,
    )
    .fetch_optional(&state.pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("PROVIDER_TEST_NOT_QUEUED", test_id.to_string()))?;
    let provider_id = row.provider_id;
    let model = row.test_model;
    let provider_type = row.provider_type;
    let enabled = row.enabled;
    let routing = row.routing_policy;
    let (status, redacted) = connection_test_result(
        state,
        &provider_type,
        &model,
        enabled,
        &routing,
        provider_id,
    )
    .await?;
    let mut tx = state.pool.begin().await.map_err(database)?;
    update_connection_test(&mut tx, test_id, provider_id, status, &redacted).await?;
    tx.commit().await.map_err(database)?;
    Ok(json!({
        "providerConnectionTestId":test_id,
        "providerType":provider_type,
        "status":status
    }))
}

async fn connection_test_result(
    state: &State,
    provider_type: &str,
    model: &str,
    enabled: bool,
    routing: &Value,
    provider_id: Uuid,
) -> Result<(&'static str, Value), Failure> {
    if !enabled || !state.config.ai_enabled {
        return Ok((
            "FAILED",
            json!({"code":"PROVIDER_DISABLED","redacted":true}),
        ));
    }
    if matches!(state.config.environment.as_str(), "development" | "test") {
        return Ok(("FAILED", json!({"code":"AI_NOT_ACTIVATED","redacted":true})));
    }
    let target = routing
        .get("targetUrl")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::Terminal("PROVIDER_TARGET_MISSING", provider_id.to_string()))?;
    let gateway = state
        .config
        .egress_ai_url
        .as_ref()
        .ok_or_else(|| Failure::Terminal("AI_EGRESS_MISSING", provider_id.to_string()))?;
    let request = json!({"operation":"connection_test","model":model});
    let request_digest = sha256(&canonical_bytes(&request)?);
    let response = state
        .client
        .post(gateway.clone())
        .header("x-gurine-egress-caller", "analysis-worker")
        .header("x-gurine-ai-provider", provider_type)
        .header("x-gurine-egress-target", target)
        .header(
            "x-gurine-idempotency-key",
            sha256(format!("connection-test\0{provider_id}\0{model}").as_bytes()),
        )
        .header("x-gurine-source-fetch-request-sha256", request_digest)
        .json(&request)
        .send()
        .await
        .map_err(|error| Failure::Retryable("PROVIDER_UNAVAILABLE", error.to_string()))?;
    Ok((
        if response.status().is_success() {
            "SUCCEEDED"
        } else {
            "FAILED"
        },
        json!({"httpStatus":response.status().as_u16(),"redacted":true}),
    ))
}

async fn update_connection_test(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    test_id: Uuid,
    provider_id: Uuid,
    status: &str,
    redacted: &Value,
) -> Result<(), Failure> {
    sqlx::query!(
        "UPDATE ops.provider_connection_tests SET status=$2,redacted_result=$3,completed_at=clock_timestamp()          WHERE id=$1 AND status='RUNNING'",
        test_id,
        status,
        redacted,
    )
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    sqlx::query!(
        "UPDATE ops.provider_configs SET last_connection_test_at=clock_timestamp(),            last_connection_test_status=$2 WHERE id=$1",
        provider_id,
        status,
    )
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    Ok(())
}
