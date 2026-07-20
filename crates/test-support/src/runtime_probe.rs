//! Small, fail-closed probes used by additive acceptance suites.
//!
//! These probes deliberately exercise the owner routines against the PostgreSQL
//! database supplied by the acceptance runner.  The observation macros still
//! bind every Gherkin clause to its sealed edge contract; this module only
//! supplies the runtime precondition and never manufactures an observation.

use serde_json::Value;
use sqlx::postgres::PgPoolOptions;
use std::sync::OnceLock;

fn database_url() -> Option<String> {
    ["GURINNAE_DATABASE_URL", "TEST_DATABASE_URL", "DATABASE_URL"]
        .into_iter()
        .find_map(|name| {
            std::env::var(name)
                .ok()
                .filter(|value| !value.trim().is_empty())
        })
}

/// Run the migration-owned, scenario-specific acceptance probe.  This is the
/// only runtime readiness source for generated acceptance suites: it checks
/// the actual owner routine plus domain/receipt/audit/outbox/event bindings.
pub fn live_acceptance_probe(scenario_id: &str) -> bool {
    let (Some(url), true) = (database_url(), scenario_id.starts_with("AC-")) else {
        return false;
    };
    let Ok(runtime) = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    else {
        return false;
    };
    runtime
        .block_on(run_acceptance_probe(&url, scenario_id))
        .unwrap_or(false)
}

/// Validate the business-health owner projection against the same live
/// PostgreSQL instance used by acceptance probes.  A catalog/transition probe
/// alone cannot prove that the 25-metric projection is typed and fail-closed,
/// so business acceptance suites bind this witness explicitly.
pub fn live_business_health_probe() -> bool {
    static RESULT: OnceLock<bool> = OnceLock::new();
    *RESULT.get_or_init(|| {
        let Some(url) = database_url() else { return false };
        let Ok(runtime) = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        else {
            return false;
        };
        runtime.block_on(async move {
            let pool = PgPoolOptions::new()
                .max_connections(1)
                .acquire_timeout(std::time::Duration::from_secs(8))
                .connect(&url)
                .await
                .ok()?;
            let value = sqlx::query_scalar::<_, Value>(
                "SELECT ops.read_business_health_projection_v1(NULL::uuid, NULL::uuid, clock_timestamp())",
            )
            .fetch_one(&pool)
            .await
            .ok()?;
            pool.close().await;
            Some(business_health_shape_is_closed(&value))
        })
        .unwrap_or(false)
    })
}

fn business_health_shape_is_closed(value: &Value) -> bool {
    let Some(object) = value.as_object() else {
        return false;
    };
    if !object
        .get("specificationVersion")
        .and_then(Value::as_str)
        .is_some_and(|version| version.starts_with("13.1.0-business-model-"))
    {
        return false;
    }
    let Some(metrics) = object.get("metrics").and_then(Value::as_array) else {
        return false;
    };
    if metrics.len() != 25 || object.get("funnel").and_then(Value::as_array).is_none() {
        return false;
    }
    let mut unknown = 0_u64;
    for metric in metrics {
        let Some(metric) = metric.as_object() else {
            return false;
        };
        let Some(status) = metric.get("status").and_then(Value::as_str) else {
            return false;
        };
        let reason = metric
            .get("reasonCode")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let reasons = metric
            .get("unknownReasons")
            .and_then(Value::as_array)
            .map_or(0, Vec::len);
        match status {
            "KNOWN" if reason == "NONE" && reasons == 0 => {}
            "UNKNOWN" if !reason.is_empty() && reason != "NONE" && reasons > 0 => unknown += 1,
            "NOT_APPLICABLE"
                if matches!(
                    reason,
                    "DENOMINATOR_ZERO"
                        | "COHORT_NOT_MATURE"
                        | "SAMPLE_TOO_SMALL"
                        | "CAPABILITY_NOT_OFFERED"
                ) && reasons == 0 => {}
            _ => return false,
        }
    }
    object.get("unknownSourceCount").and_then(Value::as_u64) == Some(unknown)
}

async fn run_acceptance_probe(url: &str, scenario_id: &str) -> Option<bool> {
    let pool = PgPoolOptions::new()
        .max_connections(1)
        .acquire_timeout(std::time::Duration::from_secs(8))
        .connect(url)
        .await
        .ok()?;
    let mut value = None;
    for attempt in 0..20 {
        match probe_attempt(&pool, scenario_id).await {
            Ok(candidate) => {
                value = Some(candidate);
                break;
            }
            Err(error) if attempt < 19 && transient(&error) => {
                tokio::time::sleep(std::time::Duration::from_millis(5 * (attempt + 1) as u64))
                    .await;
            }
            Err(_) => return None,
        }
    }
    pool.close().await;
    let object = value?.as_object()?.clone();
    let required = [
        "action",
        "domain",
        "receipt",
        "audit",
        "outbox",
        "event",
        "destination",
    ];
    Some(
        required
            .iter()
            .all(|key| object.get(*key).and_then(Value::as_bool) == Some(true))
            && object.get("passed").and_then(Value::as_bool) == Some(true),
    )
}

async fn probe_attempt(pool: &sqlx::PgPool, scenario_id: &str) -> Result<Value, sqlx::Error> {
    let mut transaction = pool.begin().await?;
    sqlx::query("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")
        .execute(&mut *transaction)
        .await?;
    let value = sqlx::query_scalar::<_, Value>("SELECT ops.acceptance_runtime_probe_v1($1)")
        .bind(scenario_id)
        .fetch_one(&mut *transaction)
        .await?;
    transaction.commit().await?;
    Ok(value)
}

fn transient(error: &sqlx::Error) -> bool {
    let text = error.to_string().to_ascii_lowercase();
    text.contains("could not serialize") || text.contains("deadlock detected")
}
