//! Small, fail-closed probes used by additive acceptance suites.
//!
//! These probes deliberately exercise the owner routines against the PostgreSQL
//! database supplied by the acceptance runner.  The observation macros still
//! bind every Gherkin clause to its sealed edge contract; this module only
//! supplies the runtime precondition and never manufactures an observation.

use serde_json::Value;
use sqlx::postgres::PgPoolOptions;
use std::sync::OnceLock;

use crate::r6e_runner_environment::acceptance_runner_lease_is_present;
use crate::r6e_runtime_lease::{R6eRuntimeLease, scenario_is_allowed};

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

/// Under a plain nextest invocation there is no parent acceptance runner to
/// lease the R6e PostgreSQL prerequisite. For the exact seven R6e scenarios,
/// start the same fixed-argv lease and prove both the scenario probe and the
/// business-health projection before requiring successful container cleanup.
/// The acceptance runner's explicit GURINNAE database URL keeps its existing
/// path; ambient generic SQLx URLs cannot redirect this disposable DB proof.
pub fn plain_nextest_r6e_probe(scenario_id: &str) -> Option<bool> {
    if acceptance_runner_lease_is_present(scenario_id) || !scenario_is_allowed(scenario_id) {
        return None;
    }
    let Ok(runtime) = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    else {
        return Some(false);
    };
    Some(
        runtime
            .block_on(run_leased_r6e_probe(scenario_id))
            .unwrap_or(false),
    )
}

/// Validate the business-health owner projection against the same live
/// PostgreSQL instance used by acceptance probes.  A catalog/transition probe
/// alone cannot prove that the 25-metric projection is typed and fail-closed,
/// so business acceptance suites bind this witness explicitly.
pub fn live_business_health_probe() -> bool {
    static RESULT: OnceLock<bool> = OnceLock::new();
    *RESULT.get_or_init(|| {
        let Some(url) = database_url() else {
            return false;
        };
        let Ok(runtime) = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        else {
            return false;
        };
        runtime
            .block_on(run_business_health_probe(&url))
            .unwrap_or(false)
    })
}

async fn run_leased_r6e_probe(scenario_id: &str) -> Option<bool> {
    let lease = R6eRuntimeLease::open(scenario_id).await?;
    let url = lease.control_database_url()?;
    let scenario_passed = run_acceptance_probe(&url, scenario_id)
        .await
        .unwrap_or(false);
    let health_passed = if scenario_passed {
        run_business_health_probe(&url).await.unwrap_or(false)
    } else {
        false
    };
    let cleanup_passed = lease.close().await;
    Some(scenario_passed && health_passed && cleanup_passed)
}

async fn run_business_health_probe(url: &str) -> Option<bool> {
    let pool = PgPoolOptions::new()
        .max_connections(1)
        .acquire_timeout(std::time::Duration::from_secs(8))
        .connect(url)
        .await
        .ok()?;
    let value: Value = sqlx::query_scalar!(
        "SELECT ops.read_business_health_projection_v1(NULL::uuid, NULL::uuid, clock_timestamp())",
    )
    .fetch_one(&pool)
    .await
    .ok()??;
    pool.close().await;
    Some(business_health_shape_is_closed(&value))
}

fn business_health_shape_is_closed(value: &Value) -> bool {
    let Some(object) = value.as_object() else {
        return false;
    };
    if object.get("specificationVersion").and_then(Value::as_str)
        != Some("13.1.0-business-model-r6e")
    {
        return false;
    }
    let Some(metrics) = object.get("metrics").and_then(Value::as_array) else {
        return false;
    };
    if metrics.len() != 25
        || object
            .get("funnel")
            .and_then(Value::as_array)
            .is_none_or(|stages| stages.len() != 8)
    {
        return false;
    }
    let mut metric_ids = std::collections::BTreeSet::new();
    let mut unknown = 0_u64;
    for metric in metrics {
        let Some(metric) = metric.as_object() else {
            return false;
        };
        let Some(metric_id) = metric.get("metricId").and_then(Value::as_str) else {
            return false;
        };
        if !metric_ids.insert(metric_id) {
            return false;
        }
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
    let readiness = object
        .get("readinessState")
        .and_then(Value::as_str)
        .unwrap_or_default();
    object.get("unknownSourceCount").and_then(Value::as_u64) == Some(unknown)
        && matches!(readiness, "UNKNOWN" | "BLOCKED" | "READY")
        && (readiness != "READY" || unknown == 0)
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
    let value = value?;
    Some(acceptance_probe_shape_is_closed(&value, scenario_id))
}

fn acceptance_probe_shape_is_closed(value: &Value, scenario_id: &str) -> bool {
    let Some(object) = value.as_object() else {
        return false;
    };
    let expected_keys = [
        "scenarioId",
        "action",
        "domain",
        "receipt",
        "audit",
        "outbox",
        "event",
        "destination",
        "passed",
    ];
    if object.len() != expected_keys.len()
        || !expected_keys.iter().all(|key| object.contains_key(*key))
        || object.get("scenarioId").and_then(Value::as_str) != Some(scenario_id)
    {
        return false;
    }
    expected_keys[1..]
        .iter()
        .all(|key| object.get(*key).and_then(Value::as_bool) == Some(true))
}

async fn probe_attempt(pool: &sqlx::PgPool, scenario_id: &str) -> Result<Value, sqlx::Error> {
    let mut transaction = pool.begin().await?;
    sqlx::query!("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")
        .execute(&mut *transaction)
        .await?;
    let value = sqlx::query_scalar!("SELECT ops.acceptance_runtime_probe_v1($1)", scenario_id,)
        .fetch_one(&mut *transaction)
        .await?
        .ok_or_else(|| sqlx::Error::ColumnDecode {
            index: "0".to_owned(),
            source: Box::new(sqlx::error::UnexpectedNullError),
        })?;
    transaction.commit().await?;
    Ok(value)
}

fn transient(error: &sqlx::Error) -> bool {
    let text = error.to_string().to_ascii_lowercase();
    text.contains("could not serialize") || text.contains("deadlock detected")
}

#[cfg(test)]
mod tests {
    use super::{acceptance_probe_shape_is_closed, business_health_shape_is_closed};
    use serde_json::json;

    fn health_projection(duplicate_metric: bool, funnel_stages: usize) -> serde_json::Value {
        let metrics = (0..25)
            .map(|index| {
                json!({
                    "metricId": if duplicate_metric && index == 24 {
                        "metric-0".to_owned()
                    } else {
                        format!("metric-{index}")
                    },
                    "status": "KNOWN",
                    "reasonCode": "NONE",
                    "unknownReasons": []
                })
            })
            .collect::<Vec<_>>();
        json!({
            "specificationVersion": "13.1.0-business-model-r6e",
            "metrics": metrics,
            "unknownSourceCount": 0,
            "readinessState": "READY",
            "funnel": (0..funnel_stages).collect::<Vec<_>>()
        })
    }

    #[test]
    fn acceptance_probe_requires_closed_shape_and_scenario_echo() {
        let valid = json!({
            "scenarioId": "AC-BUSINESS_MODEL-042",
            "action": true,
            "domain": true,
            "receipt": true,
            "audit": true,
            "outbox": true,
            "event": true,
            "destination": true,
            "passed": true
        });
        let wrong_scenario = json!({
            "scenarioId": "AC-BUSINESS_MODEL-043",
            "action": true,
            "domain": true,
            "receipt": true,
            "audit": true,
            "outbox": true,
            "event": true,
            "destination": true,
            "passed": true
        });

        assert!(acceptance_probe_shape_is_closed(
            &valid,
            "AC-BUSINESS_MODEL-042"
        ));
        assert!(!acceptance_probe_shape_is_closed(
            &wrong_scenario,
            "AC-BUSINESS_MODEL-042"
        ));
    }

    #[test]
    fn acceptance_probe_rejects_missing_or_extra_keys() {
        let missing = json!({
            "scenarioId": "AC-BUSINESS_MODEL-042",
            "action": true,
            "domain": true,
            "receipt": true,
            "audit": true,
            "outbox": true,
            "event": true,
            "destination": true
        });
        let extra = json!({
            "scenarioId": "AC-BUSINESS_MODEL-042",
            "action": true,
            "domain": true,
            "receipt": true,
            "audit": true,
            "outbox": true,
            "event": true,
            "destination": true,
            "passed": true,
            "unexpected": true
        });

        assert!(!acceptance_probe_shape_is_closed(
            &missing,
            "AC-BUSINESS_MODEL-042"
        ));
        assert!(!acceptance_probe_shape_is_closed(
            &extra,
            "AC-BUSINESS_MODEL-042"
        ));
    }

    #[test]
    fn business_health_requires_unique_metrics_and_exact_funnel() {
        assert!(business_health_shape_is_closed(&health_projection(
            false, 8
        )));
        assert!(!business_health_shape_is_closed(&health_projection(
            true, 8
        )));
        assert!(!business_health_shape_is_closed(&health_projection(
            false, 7
        )));
    }
}
