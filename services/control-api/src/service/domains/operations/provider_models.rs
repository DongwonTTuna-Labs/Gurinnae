use super::*;

struct RelayModelCandidate {
    model_id: String,
    created_at: Option<OffsetDateTime>,
    active: bool,
}

pub(super) async fn list_relay_models(pool: &PgPool) -> Result<Value, ServiceError> {
    let items: Value = sqlx::query_scalar!(
        "SELECT COALESCE(jsonb_agg(jsonb_build_object(\
           'modelId',m.model_id,'family',m.family,'track',m.track,'createdAt',m.created_at,\
           'firstSeenAt',m.first_seen_at,'lastSeenAt',m.last_seen_at,'active',m.active,\
           'new',NOT EXISTS(SELECT 1 FROM ops.provider_model_upgrade_receipts r \
             WHERE r.target_model_id=m.model_id AND r.outcome='APPLIED')) \
         ORDER BY m.created_at DESC NULLS LAST,m.model_id ASC),'[]'::jsonb) \
         FROM ops.relay_model_catalog m",
    )
    .fetch_one(pool)
    .await
    .map_err(db)?
    .ok_or_else(unexpected_null)?;
    let current_providers = current_relay_providers(pool).await?;
    let sync_status: Value = sqlx::query_scalar!(
        "SELECT jsonb_build_object('status',status,'lastCompletedAt',completed_at,\
           'lastErrorCode',error_code) FROM ops.relay_model_catalog_sync_runs \
         ORDER BY scheduled_bucket DESC,id DESC LIMIT 1",
    )
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .flatten()
    .unwrap_or_else(|| json!({"status":"NOT_RUN","lastCompletedAt":null,"lastErrorCode":null}));
    Ok(json!({
        "items": items,
        "currentProviders": current_providers,
        "syncStatus": sync_status,
        "asOf": format_time(OffsetDateTime::now_utc())?,
    }))
}

async fn current_relay_providers(pool: &PgPool) -> Result<Value, ServiceError> {
    let mut providers: Value = sqlx::query_scalar!(
        "SELECT COALESCE(jsonb_agg(jsonb_build_object(\
           'providerId',p.id,'name',p.name,'currentModel',p.routing_policy->>'model',\
           'enabled',p.enabled,'version',p.version,\
           'autoUpgrade',COALESCE((p.routing_policy->>'autoUpgrade')::boolean,false),\
           'track',p.routing_policy->>'track',\
           'dataPolicyState',p.routing_policy#>>'{dataPolicy,state}',\
           'pricingVersion',p.routing_policy#>>'{pricing,pricingVersion}',\
           'unpriced',COALESCE((p.routing_policy#>>'{pricing,inputMicrosKrwPerUnit}')::numeric,0)=0 \
             AND COALESCE((p.routing_policy#>>'{pricing,outputMicrosKrwPerUnit}')::numeric,0)=0) \
         ORDER BY p.name,p.id),'[]'::jsonb) FROM ops.provider_configs p \
         WHERE p.provider_type='relay'",
    )
    .fetch_one(pool)
    .await
    .map_err(db)?
    .ok_or_else(unexpected_null)?;
    let candidates =
        sqlx::query!("SELECT model_id,created_at,active FROM ops.relay_model_catalog",)
            .fetch_all(pool)
            .await
            .map_err(db)?
            .into_iter()
            .map(|candidate| RelayModelCandidate {
                model_id: candidate.model_id,
                created_at: candidate.created_at,
                active: candidate.active,
            })
            .collect::<Vec<_>>();
    let active_tracks = providers
        .as_array()
        .ok_or(ServiceError::Persistence)?
        .iter()
        .filter(|provider| {
            provider.get("enabled").and_then(Value::as_bool) == Some(true)
                && provider.get("autoUpgrade").and_then(Value::as_bool) == Some(true)
        })
        .filter_map(|provider| provider.get("track").and_then(Value::as_str))
        .map(str::to_owned)
        .collect::<Vec<_>>();
    let items = providers.as_array_mut().ok_or(ServiceError::Persistence)?;
    for provider in items {
        let enabled = provider
            .get("enabled")
            .and_then(Value::as_bool)
            .ok_or(ServiceError::Persistence)?;
        let auto_upgrade = provider
            .get("autoUpgrade")
            .and_then(Value::as_bool)
            .ok_or(ServiceError::Persistence)?;
        let track = provider.get("track").and_then(Value::as_str);
        let conflict =
            latest_track_has_conflict(enabled && auto_upgrade, track, &active_tracks, &candidates);
        provider
            .as_object_mut()
            .ok_or(ServiceError::Persistence)?
            .insert("autoUpgradeConflict".to_owned(), json!(conflict));
    }
    Ok(providers)
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
// and a latest-created tie is projected as a conflict.
fn latest_track_has_conflict(
    active_auto_upgrade: bool,
    track: Option<&str>,
    active_tracks: &[String],
    candidates: &[RelayModelCandidate],
) -> bool {
    let Some(track) = track.filter(|_| active_auto_upgrade) else {
        return false;
    };
    let latest = candidates
        .iter()
        .filter(|candidate| {
            candidate.active
                && longest_matching_track(&candidate.model_id, active_tracks) == Some(track)
        })
        .filter_map(|candidate| candidate.created_at)
        .max();
    latest.is_some_and(|latest| {
        candidates
            .iter()
            .filter(|candidate| {
                candidate.active
                    && longest_matching_track(&candidate.model_id, active_tracks) == Some(track)
                    && candidate.created_at == Some(latest)
            })
            .take(2)
            .count()
            == 2
    })
}

#[cfg(test)]
#[path = "provider_models_tests.rs"]
mod tests;
