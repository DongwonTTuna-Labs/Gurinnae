#[expect(
    clippy::too_many_arguments,
    reason = "signal persistence receives rule, snapshot, and evidence provenance"
)]
async fn persist_signal(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    run_id: Uuid,
    rule_version_id: Uuid,
    dataset_snapshot_id: Uuid,
    rule_id: &str,
    configuration: &Value,
    result: &Value,
    result_digest: &str,
    snapshot_binding: Option<&SnapshotRunBinding>,
) -> Result<i64, Failure> {
    if result.get("outcome").and_then(Value::as_str) != Some("SIGNAL") {
        return Ok(0);
    }
    let identity = signal_identity(
        tx,
        dataset_snapshot_id,
        result,
        configuration,
        snapshot_binding.is_some(),
    )
    .await?;
    let inserted: Option<Uuid> = sqlx::query_scalar!(
        "INSERT INTO core.anomaly_signals( \
           id,rule_run_id,rule_version_id,signal_type,target_type,target_id,severity, \
           explanation,calculation,blockers,comparison_digest) \
         VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) \
         ON CONFLICT(rule_version_id,target_type,target_id,comparison_digest) DO NOTHING \
         RETURNING id",
        Uuid::new_v4(),
        run_id,
        rule_version_id,
        rule_id,
        identity.target_type.as_str(),
        identity.target_id,
        identity.severity.as_str(),
        json!({
            "outcome":"SIGNAL",
            "includedIds":result["included_ids"],
            "datasetSnapshotId":snapshot_binding.map(|_| dataset_snapshot_id),
            "datasetSnapshotSha256":snapshot_binding.map(|binding| &binding.snapshot_sha256),
        }),
        result.get("metrics").cloned().unwrap_or_else(|| json!({})),
        result.get("blockers").cloned().unwrap_or_else(|| json!([])),
        result_digest,
    )
    .fetch_optional(&mut **tx)
    .await
    .map_err(database)?;
    if let Some(signal_id) = inserted {
        sqlx::query!(
            "SELECT ops.enqueue_outbox('signal',$1,1,'detection.signal_created.v1',$2,clock_timestamp())",
            signal_id.to_string(),
            json!({
                "signal_id":signal_id,"rule_version_id":rule_version_id,
                "target_id":identity.target_id
            }),
        )
        .fetch_one(&mut **tx)
        .await
        .map_err(database)?;
        return Ok(1);
    }
    Ok(0)
}

struct SignalIdentity {
    target_type: String,
    target_id: Uuid,
    severity: String,
}

async fn signal_identity(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    dataset_snapshot_id: Uuid,
    result: &Value,
    configuration: &Value,
    snapshot_bound: bool,
) -> Result<SignalIdentity, Failure> {
    let request = signal_request(dataset_snapshot_id, result, configuration, snapshot_bound)?;
    if !snapshot_bound {
        return Ok(SignalIdentity {
            target_type: "DATASET_SNAPSHOT".to_owned(),
            target_id: request.target_id,
            severity: request.severity,
        });
    }
    let target_types = sqlx::query_scalar!(
        "SELECT object_type FROM core.dataset_snapshot_members \
         WHERE dataset_snapshot_id=$1 AND object_id=$2 \
         ORDER BY object_type,object_version",
        dataset_snapshot_id,
        request.target_id,
    )
    .fetch_all(&mut **tx)
    .await
    .map_err(database)?;
    let [target_type] = target_types.as_slice() else {
        return Err(Failure::Terminal(
            "RULE_SIGNAL_TARGET_AMBIGUOUS",
            request.target_id.to_string(),
        ));
    };
    Ok(SignalIdentity {
        target_type: target_type.clone(),
        target_id: request.target_id,
        severity: request.severity,
    })
}

struct SignalRequest {
    target_id: Uuid,
    severity: String,
}

fn signal_request(
    dataset_snapshot_id: Uuid,
    result: &Value,
    configuration: &Value,
    snapshot_bound: bool,
) -> Result<SignalRequest, Failure> {
    let severity = configuration
        .get("severity")
        .and_then(Value::as_str)
        .filter(|value| matches!(*value, "INFO" | "LOW" | "MEDIUM" | "HIGH" | "CRITICAL"));
    if !snapshot_bound {
        return Ok(SignalRequest {
            target_id: first_included_uuid(result).unwrap_or(dataset_snapshot_id),
            severity: severity.unwrap_or("HIGH").to_owned(),
        });
    }
    let severity = severity.ok_or_else(|| {
        Failure::Terminal(
            "RULE_SIGNAL_SEVERITY_INVALID",
            dataset_snapshot_id.to_string(),
        )
    })?;
    let included = result
        .get("included_ids")
        .and_then(Value::as_array)
        .filter(|values| values.len() == 1)
        .ok_or_else(|| {
            Failure::Terminal(
                "RULE_SIGNAL_TARGET_AMBIGUOUS",
                dataset_snapshot_id.to_string(),
            )
        })?;
    let target_id = included[0]
        .as_str()
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| {
            Failure::Terminal(
                "RULE_SIGNAL_TARGET_INVALID",
                dataset_snapshot_id.to_string(),
            )
        })?;
    Ok(SignalRequest {
        target_id,
        severity: severity.to_owned(),
    })
}

fn first_included_uuid(result: &Value) -> Option<Uuid> {
    result
        .pointer("/included_ids/0")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
}

#[cfg(test)]
mod analysis_signal_persistence_tests {
    use super::*;

    #[test]
    fn v2_signal_requires_closed_severity_and_one_actual_target() {
        let snapshot_id = Uuid::from_u128(1);
        let target_id = Uuid::from_u128(2);
        assert!(
            signal_request(
                snapshot_id,
                &json!({"included_ids":[target_id]}),
                &json!({}),
                true,
            )
            .is_err()
        );
        assert!(
            signal_request(
                snapshot_id,
                &json!({"included_ids":[target_id,Uuid::from_u128(3)]}),
                &json!({"severity":"HIGH"}),
                true,
            )
            .is_err()
        );
        let request = signal_request(
            snapshot_id,
            &json!({"included_ids":[target_id]}),
            &json!({"severity":"MEDIUM"}),
            true,
        );
        assert!(
            matches!(request, Ok(value) if value.target_id == target_id && value.severity == "MEDIUM")
        );
    }

    #[test]
    fn v1_signal_retains_legacy_fallbacks() {
        let snapshot_id = Uuid::from_u128(4);
        let request = signal_request(snapshot_id, &json!({}), &json!({}), false);
        assert!(
            matches!(request, Ok(value) if value.target_id == snapshot_id && value.severity == "HIGH")
        );
    }
}
