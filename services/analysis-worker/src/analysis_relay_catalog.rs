#[derive(Clone, Debug, Eq, PartialEq)]
struct RelayCatalogModel {
    model_id: String,
    family: Option<String>,
    track: Option<String>,
    created_at: Option<OffsetDateTime>,
    raw: Value,
}

#[path = "analysis_relay_catalog_plan.rs"]
mod analysis_relay_catalog_plan;

use analysis_relay_catalog_plan::{
    RelayCatalogLifecycleMutation, RelayCatalogStoredRow, relay_catalog_lifecycle_plan,
};

#[derive(Clone, Debug, Eq, PartialEq)]
enum RelayNewestCandidate {
    None,
    Unique(String),
    CreatedAtTie,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RelayAutoUpgradeGate {
    Enqueue,
    Suppressed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct RelayAutoUpgradePriorAttempt<'a> {
    attempt_kind: RelayUpgradeAttemptKind,
    status: &'a str,
    cooldown_until: Option<OffsetDateTime>,
}

struct ClaimedRelayCatalogSync {
    sync_run_id: Uuid,
    scheduled_bucket: OffsetDateTime,
}

async fn relay_model_catalog_sync(
    state: &State,
    job: &ClaimedJob,
) -> Result<Value, Failure> {
    let sync_run_id = payload_uuid(&job.payload, "catalogSyncRunId")?;
    let sync = claim_relay_catalog_sync(&state.pool, sync_run_id).await?;
    let routing = load_relay_routing(&state.pool).await?;
    let target = relay_models_target(&routing)?;
    let gateway = state
        .config
        .egress_ai_url
        .as_ref()
        .ok_or_else(|| Failure::Terminal("AI_EGRESS_MISSING", sync_run_id.to_string()))?;
    let request_sha256 = sha256(b"");
    let response = state
        .client
        .get(gateway.clone())
        .header("x-gurine-egress-caller", "analysis-worker")
        .header("x-gurine-ai-provider", RELAY_PROVIDER)
        .header("x-gurine-egress-target", target)
        .header(
            "x-gurine-idempotency-key",
            sha256(format!("relay-model-catalog-sync\0{sync_run_id}").as_bytes()),
        )
        .header("x-gurine-source-fetch-request-sha256", &request_sha256)
        .send()
        .await
        .map_err(|error| Failure::Retryable("RELAY_CATALOG_UNAVAILABLE", error.to_string()))?;
    let observation = observe_relay_gateway_response(response, &request_sha256).await?;
    let models = parse_relay_model_list(&observation.body)?;
    persist_relay_catalog_sync(
        state,
        sync.sync_run_id,
        &models,
        &observation.gateway_receipt_sha256,
        &observation.payload_sha256,
    )
    .await?;
    Ok(json!({
        "catalogSyncRunId": sync_run_id,
        "modelCount": models.len(),
        "scheduledBucket": sync.scheduled_bucket,
        "status": "SUCCEEDED",
    }))
}

async fn claim_relay_catalog_sync(
    pool: &PgPool,
    sync_run_id: Uuid,
) -> Result<ClaimedRelayCatalogSync, Failure> {
    let claimed = sqlx::query!(
        "UPDATE ops.relay_model_catalog_sync_runs \
         SET status='RUNNING',started_at=COALESCE(started_at,clock_timestamp()) \
         WHERE id=$1 AND status IN ('QUEUED','RUNNING') RETURNING id,scheduled_bucket",
        sync_run_id,
    )
    .fetch_optional(pool)
    .await
    .map_err(database)?;
    let claimed = claimed.ok_or_else(|| {
        Failure::Terminal(
            "RELAY_CATALOG_SYNC_NOT_QUEUED",
            sync_run_id.to_string(),
        )
    })?;
    Ok(ClaimedRelayCatalogSync {
        sync_run_id: claimed.id,
        scheduled_bucket: claimed.scheduled_bucket,
    })
}

async fn load_relay_routing(pool: &PgPool) -> Result<Value, Failure> {
    sqlx::query_scalar!(
        "SELECT routing_policy FROM ops.provider_configs WHERE provider_type='relay'",
    )
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("RELAY_PROVIDER_MISSING", "relay".into()))
}

fn relay_models_target(routing: &Value) -> Result<String, Failure> {
    let chat_target = routing
        .get("targetUrl")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::Terminal("PROVIDER_TARGET_MISSING", "relay".into()))?;
    if !relay_target_has_path(chat_target, RELAY_CHAT_PATH) {
        return Err(Failure::Terminal(
            "PROVIDER_TARGET_INVALID",
            chat_target.to_owned(),
        ));
    }
    let mut target = chat_target
        .parse::<reqwest::Url>()
        .map_err(|error| Failure::Terminal("PROVIDER_TARGET_INVALID", error.to_string()))?;
    target.set_path(RELAY_MODELS_PATH);
    Ok(target.to_string())
}

fn parse_relay_model_list(body: &Value) -> Result<Vec<RelayCatalogModel>, Failure> {
    let object = body
        .as_object()
        .ok_or_else(|| relay_catalog_error("object"))?;
    if object.get("object").and_then(Value::as_str) != Some("list") {
        return Err(relay_catalog_error("object discriminator"));
    }
    let rows = object
        .get("data")
        .and_then(Value::as_array)
        .ok_or_else(|| relay_catalog_error("data"))?;
    let mut ids = std::collections::BTreeSet::new();
    let mut models = Vec::with_capacity(rows.len());
    for raw in rows {
        let row = raw
            .as_object()
            .ok_or_else(|| relay_catalog_error("model object"))?;
        let model_id = bounded_relay_text(row, "id", 255)?;
        if !relay_model_id_is_valid(&model_id)
            || row.get("object").and_then(Value::as_str) != Some("model")
            || !ids.insert(model_id.clone())
        {
            return Err(relay_catalog_error(format!("model:{model_id}")));
        }
        if row.get("owned_by").is_some_and(|value| !value.is_string()) {
            return Err(relay_catalog_error(format!("owned_by:{model_id}")));
        }
        let created_at = relay_model_created_at(row.get("created"))?;
        let (family, track) = relay_family_and_track(&model_id);
        models.push(RelayCatalogModel {
            model_id,
            family,
            track,
            created_at,
            raw: raw.clone(),
        });
    }
    models.sort_by(|left, right| left.model_id.cmp(&right.model_id));
    Ok(models)
}

fn relay_model_created_at(value: Option<&Value>) -> Result<Option<OffsetDateTime>, Failure> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_i64()
            .and_then(|timestamp| OffsetDateTime::from_unix_timestamp(timestamp).ok())
            .map(Some)
            .ok_or_else(|| relay_catalog_error("created")),
    }
}

fn relay_model_id_is_valid(model_id: &str) -> bool {
    let mut bytes = model_id.bytes();
    bytes.next().is_some_and(|first| first.is_ascii_alphanumeric())
        && bytes.all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b':' | b'/' | b'-')
        })
}

fn relay_family_and_track(model_id: &str) -> (Option<String>, Option<String>) {
    let Some((family, suffix)) = model_id.split_once('-') else {
        return (None, None);
    };
    if family.is_empty() || suffix.is_empty() {
        return (None, None);
    }
    (Some(family.to_owned()), Some(format!("{family}-")))
}

fn relay_catalog_error(detail: impl Into<String>) -> Failure {
    Failure::Terminal("RELAY_MODEL_CATALOG_INVALID", detail.into())
}

// Each model belongs only to its case-sensitive longest configured track prefix.
fn longest_matching_track<'a>(model_id: &str, tracks: &'a [String]) -> Option<&'a str> {
    tracks
        .iter()
        .map(String::as_str)
        .filter(|track| model_id.starts_with(track))
        .max_by_key(|track| track.len())
}

// Latest is maximum `created` within that owned track; undated models are excluded,
// and a latest-created tie is never selected automatically.
fn newest_relay_model(
    models: &[RelayCatalogModel],
    track: &str,
    active_tracks: &[String],
    current_model: Option<&str>,
) -> RelayNewestCandidate {
    let mut candidates = models
        .iter()
        .filter(|model| longest_matching_track(&model.model_id, active_tracks) == Some(track))
        .filter_map(|model| model.created_at.map(|created| (created, &model.model_id)))
        .collect::<Vec<_>>();
    candidates.sort_by(|left, right| right.0.cmp(&left.0).then_with(|| left.1.cmp(right.1)));
    let Some((latest_created, latest_model)) = candidates.first() else {
        return RelayNewestCandidate::None;
    };
    if candidates
        .iter()
        .skip(1)
        .any(|(created, _)| created == latest_created)
    {
        return RelayNewestCandidate::CreatedAtTie;
    }
    if current_model == Some(latest_model.as_str()) {
        RelayNewestCandidate::None
    } else {
        RelayNewestCandidate::Unique((*latest_model).clone())
    }
}

async fn persist_relay_catalog_sync(
    state: &State,
    sync_run_id: Uuid,
    models: &[RelayCatalogModel],
    gateway_receipt_sha256: &str,
    payload_sha256: &str,
) -> Result<(), Failure> {
    let mut tx = state.pool.begin().await.map_err(database)?;
    let existing = load_relay_catalog_lifecycle(&mut tx).await?;
    let lifecycle = relay_catalog_lifecycle_plan(&existing, models, OffsetDateTime::now_utc());
    apply_relay_catalog_lifecycle(&mut tx, &lifecycle).await?;
    schedule_relay_auto_upgrades(&mut tx, sync_run_id, models).await?;
    let model_count = i64::try_from(models.len())
        .map_err(|error| Failure::Terminal("RELAY_MODEL_CATALOG_INVALID", error.to_string()))?;
    sqlx::query!(
        "UPDATE ops.relay_model_catalog_sync_runs SET status='SUCCEEDED',model_count=$2, \
           gateway_receipt_sha256=CAST($3 AS char(64)),payload_sha256=CAST($4 AS char(64)), \
           completed_at=clock_timestamp() WHERE id=$1 AND status='RUNNING'",
        sync_run_id,
        model_count,
        gateway_receipt_sha256,
        payload_sha256,
    )
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    tx.commit().await.map_err(database)
}

async fn load_relay_catalog_lifecycle(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
) -> Result<Vec<RelayCatalogStoredRow>, Failure> {
    sqlx::query!(
        "SELECT model_id,first_seen_at,last_seen_at,raw FROM ops.relay_model_catalog \
         ORDER BY model_id FOR UPDATE",
    )
    .fetch_all(&mut **tx)
    .await
    .map_err(database)
    .map(|rows| {
        rows.into_iter()
            .map(|row| RelayCatalogStoredRow {
                model_id: row.model_id,
                first_seen_at: row.first_seen_at,
                last_seen_at: row.last_seen_at,
                raw: row.raw,
            })
            .collect()
    })
}

async fn apply_relay_catalog_lifecycle(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    lifecycle: &[RelayCatalogLifecycleMutation],
) -> Result<(), Failure> {
    for mutation in lifecycle {
        match mutation {
            RelayCatalogLifecycleMutation::Seen {
                model,
                first_seen_at,
                last_seen_at,
            } => {
                sqlx::query!(
                    "INSERT INTO ops.relay_model_catalog( \
                       model_id,family,track,created_at,first_seen_at,last_seen_at,active,raw) \
                     VALUES($1,$2,$3,$4,$5,$6,true,$7) \
                     ON CONFLICT(model_id) DO UPDATE SET family=EXCLUDED.family, \
                       track=EXCLUDED.track,created_at=EXCLUDED.created_at, \
                       first_seen_at=EXCLUDED.first_seen_at,last_seen_at=EXCLUDED.last_seen_at, \
                       active=true,raw=EXCLUDED.raw",
                    model.model_id,
                    model.family,
                    model.track,
                    model.created_at,
                    first_seen_at,
                    last_seen_at,
                    model.raw,
                )
                .execute(&mut **tx)
                .await
                .map_err(database)?;
            }
            RelayCatalogLifecycleMutation::Missing(row) => {
                sqlx::query!(
                    "UPDATE ops.relay_model_catalog SET active=false,first_seen_at=$2, \
                       last_seen_at=$3,raw=$4 WHERE model_id=$1",
                    row.model_id,
                    row.first_seen_at,
                    row.last_seen_at,
                    row.raw,
                )
                .execute(&mut **tx)
                .await
                .map_err(database)?;
            }
        }
    }
    Ok(())
}

async fn schedule_relay_auto_upgrades(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    sync_run_id: Uuid,
    models: &[RelayCatalogModel],
) -> Result<(), Failure> {
    let providers = sqlx::query!(
        "SELECT id,routing_policy,version FROM ops.provider_configs \
         WHERE provider_type='relay' AND enabled AND (routing_policy->>'autoUpgrade')::boolean \
         FOR UPDATE",
    )
    .fetch_all(&mut **tx)
    .await
    .map_err(database)?;
    let active_tracks = providers
        .iter()
        .filter_map(|provider| provider.routing_policy.get("track").and_then(Value::as_str))
        .map(str::to_owned)
        .collect::<Vec<_>>();
    for provider in providers {
        let Some(track) = provider.routing_policy.get("track").and_then(Value::as_str) else {
            return Err(Failure::Terminal("PROVIDER_TRACK_MISSING", provider.id.to_string()));
        };
        let current_model = provider.routing_policy.get("model").and_then(Value::as_str);
        let RelayNewestCandidate::Unique(target_model) =
            newest_relay_model(models, track, &active_tracks, current_model)
        else {
            continue;
        };
        let owner = provider
            .routing_policy
            .get("autoUpgradeOwnerUserId")
            .and_then(Value::as_str)
            .and_then(|value| Uuid::parse_str(value).ok())
            .ok_or_else(|| Failure::Terminal("AUTO_UPGRADE_OWNER_MISSING", provider.id.to_string()))?;
        enqueue_relay_auto_upgrade(
            tx,
            sync_run_id,
            provider.id,
            provider.version,
            current_model,
            &target_model,
            owner,
            &provider.routing_policy,
        )
        .await?;
    }
    Ok(())
}

#[expect(
    clippy::too_many_arguments,
    reason = "auto attempt creation binds provider, target, owner, and catalog sync fence"
)]
async fn enqueue_relay_auto_upgrade(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    sync_run_id: Uuid,
    provider_id: Uuid,
    provider_version: i64,
    current_model: Option<&str>,
    target_model: &str,
    owner_user_id: Uuid,
    routing_policy: &Value,
) -> Result<(), Failure> {
    let last_attempt = sqlx::query!(
        "SELECT status,cooldown_until FROM ops.provider_model_upgrade_attempts \
         WHERE provider_id=$1 AND target_model_id=$2 AND attempt_kind='AUTO' \
           AND status <> 'SUPPRESSED' \
         ORDER BY created_at DESC,id DESC LIMIT 1",
        provider_id,
        target_model,
    )
    .fetch_optional(&mut **tx)
    .await
    .map_err(database)?;
    let prior_attempt = last_attempt
        .as_ref()
        .map(|attempt| RelayAutoUpgradePriorAttempt {
            attempt_kind: RelayUpgradeAttemptKind::Auto,
            status: attempt.status.as_str(),
            cooldown_until: attempt.cooldown_until,
        });
    let gate = relay_auto_upgrade_gate(prior_attempt, OffsetDateTime::now_utc());
    if gate == RelayAutoUpgradeGate::Suppressed {
        return persist_suppressed_auto_upgrade(
            tx,
            sync_run_id,
            provider_id,
            provider_version,
            current_model,
            target_model,
            owner_user_id,
            routing_policy,
        )
        .await;
    }
    let attempt_id = Uuid::new_v4();
    let connection_test_id = Uuid::new_v4();
    sqlx::query!(
        "INSERT INTO ops.provider_connection_tests( \
           id,provider_id,test_model,status,requested_by,reason) \
         VALUES($1,$2,$3,'QUEUED',$4,'relay auto-upgrade gate')",
        connection_test_id,
        provider_id,
        target_model,
        owner_user_id,
    )
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    sqlx::query!(
        "INSERT INTO ops.provider_model_upgrade_attempts( \
           id,provider_id,target_model_id,attempt_kind,requested_by,owner_user_id, \
           expected_provider_version,requested_data_policy,catalog_sync_run_id,status,connection_test_id) \
         VALUES($1,$2,$3,'AUTO',NULL,$4,$5,NULL,$6,'QUEUED',$7)",
        attempt_id,
        provider_id,
        target_model,
        owner_user_id,
        provider_version,
        sync_run_id,
        connection_test_id,
    )
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    sqlx::query!(
        "INSERT INTO ops.jobs(job_type,queue,payload,dedupe_key,max_attempts) \
         VALUES('PROVIDER_MODEL_UPGRADE','analysis-worker',$1,$2,8)",
        json!({"providerModelUpgradeAttemptId":attempt_id}),
        format!("provider-model-upgrade:{attempt_id}"),
    )
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    Ok(())
}

fn relay_auto_upgrade_gate(
    prior_attempt: Option<RelayAutoUpgradePriorAttempt<'_>>,
    now: OffsetDateTime,
) -> RelayAutoUpgradeGate {
    let Some(attempt) = prior_attempt
        .filter(|attempt| attempt.attempt_kind == RelayUpgradeAttemptKind::Auto)
    else {
        return RelayAutoUpgradeGate::Enqueue;
    };
    if matches!(attempt.status, "QUEUED" | "RUNNING")
        || attempt.cooldown_until.is_some_and(|until| until > now)
    {
        RelayAutoUpgradeGate::Suppressed
    } else {
        RelayAutoUpgradeGate::Enqueue
    }
}

#[expect(
    clippy::too_many_arguments,
    reason = "suppression receipt binds the same auto-upgrade candidate identity"
)]
async fn persist_suppressed_auto_upgrade(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    sync_run_id: Uuid,
    provider_id: Uuid,
    provider_version: i64,
    current_model: Option<&str>,
    target_model: &str,
    owner_user_id: Uuid,
    routing_policy: &Value,
) -> Result<(), Failure> {
    let attempt_id = Uuid::new_v4();
    let recorded_at = OffsetDateTime::now_utc();
    let policy_sha256 = routing_policy
        .pointer("/dataPolicy/policySha256")
        .and_then(Value::as_str);
    let receipt = RelayUpgradeReceipt::build(RelayUpgradeReceiptInput {
        receipt_id: Uuid::new_v4(),
        attempt_id,
        provider_id,
        target_model_id: target_model.to_owned(),
        attempt_kind: RelayUpgradeAttemptKind::Auto,
        outcome: RelayUpgradeReceiptOutcome::Suppressed,
        before_provider_version: provider_version,
        after_provider_version: provider_version,
        before_model_id: current_model.map(str::to_owned),
        after_model_id: current_model.map(str::to_owned),
        policy_sha256: policy_sha256.map(str::to_owned),
        gateway_receipt_sha256: None,
        usage_evidence_sha256: None,
        audit_event_id: None,
        incident_event_id: None,
        cost_event_id: None,
        recorded_at,
    })?;
    sqlx::query!(
        "INSERT INTO ops.provider_model_upgrade_attempts( \
           id,provider_id,target_model_id,attempt_kind,requested_by,owner_user_id, \
           expected_provider_version,requested_data_policy,catalog_sync_run_id,status, \
           last_error_code,cooldown_until,completed_at) \
         VALUES($1,$2,$3,'AUTO',NULL,$4,$5,NULL,$6,'SUPPRESSED', \
           'AUTO_UPGRADE_COOLDOWN',CAST($7 AS timestamptz) + interval '6 hours', \
           CAST($7 AS timestamptz))",
        attempt_id,
        provider_id,
        target_model,
        owner_user_id,
        provider_version,
        sync_run_id,
        recorded_at,
    )
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    sqlx::query!(
        "INSERT INTO ops.provider_model_upgrade_receipts( \
           id,attempt_id,provider_id,target_model_id,attempt_kind,outcome,before_provider_version, \
           after_provider_version,before_model_id,after_model_id,policy_sha256, \
           receipt_canonical,canonical_receipt,receipt_sha256,recorded_at) \
         VALUES($1,$2,$3,$4,$5,$6,$7,$7,$8,$8,CAST($9 AS char(64)), \
           $10,$11,CAST($12 AS char(64)),$13)",
        receipt.receipt_id,
        attempt_id,
        provider_id,
        target_model,
        receipt.attempt_kind.as_str(),
        receipt.outcome.as_str(),
        provider_version,
        current_model,
        policy_sha256,
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
#[path = "analysis_relay_catalog_tests.rs"]
mod relay_catalog_tests;
