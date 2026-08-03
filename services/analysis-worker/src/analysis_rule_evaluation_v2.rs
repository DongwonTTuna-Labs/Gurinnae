use serde_json::Value;
use sqlx::{Postgres, Transaction};
use uuid::Uuid;

use super::{Failure, canonical_bytes, database, sha256};
use crate::runner::analysis_rule_materializer::{SnapshotMember, materialize_rule_input};

#[path = "analysis_rule_frozen_facts.rs"]
mod frozen_facts;

pub(super) struct SnapshotRuleInput {
    pub value: Value,
    pub input_sha256: String,
    pub snapshot_sha256: String,
    pub rule_configuration_sha256: String,
    pub rule_code_sha256: String,
}

pub(super) async fn load_snapshot_rule_input(
    tx: &mut Transaction<'_, Postgres>,
    dataset_snapshot_id: Uuid,
    rule_version_id: Uuid,
    rule_id: &str,
    configuration: &Value,
    rule_code_sha256: &str,
) -> Result<SnapshotRuleInput, Failure> {
    let snapshot = sqlx::query!(
        "SELECT snapshot_kind,state,snapshot_sha256,selection_spec,member_count, \
                strong_identifier_fact_count, \
                btrim(strong_identifier_fact_set_sha256::text) \
                  AS \"strong_identifier_fact_set_sha256?: String\" \
         FROM core.dataset_snapshots WHERE id=$1",
        dataset_snapshot_id,
    )
    .fetch_optional(&mut **tx)
    .await
    .map_err(database)?
    .ok_or_else(|| snapshot_invalid("snapshot not found"))?;
    let snapshot_sha256 = snapshot
        .snapshot_sha256
        .as_deref()
        .map(str::trim)
        .filter(|value| is_lower_sha256(value))
        .ok_or_else(|| snapshot_invalid("snapshotSha256"))?
        .to_owned();
    if snapshot.snapshot_kind != "DETECTION_DATASET" || snapshot.state != "READY" {
        return Err(snapshot_invalid("snapshot state or kind"));
    }
    let rule_configuration_sha256 = sha256(&canonical_bytes(configuration)?);
    validate_selection(
        &snapshot.selection_spec,
        rule_version_id,
        rule_id,
        &rule_configuration_sha256,
        rule_code_sha256,
    )?;
    let rows = sqlx::query!(
        "SELECT member_ordinal,member_digest,object_type,object_id,object_version, \
                canonical_payload \
         FROM core.dataset_snapshot_members WHERE dataset_snapshot_id=$1 \
         ORDER BY member_ordinal,member_digest",
        dataset_snapshot_id,
    )
    .fetch_all(&mut **tx)
    .await
    .map_err(database)?;
    if i64::try_from(rows.len()).ok() != Some(snapshot.member_count) {
        return Err(snapshot_invalid("member count"));
    }
    let members = rows
        .into_iter()
        .map(|row| SnapshotMember {
            ordinal: row.member_ordinal,
            member_digest: row.member_digest.trim().to_owned(),
            object_type: row.object_type,
            object_id: row.object_id,
            object_version: row.object_version,
            canonical_payload: row.canonical_payload,
        })
        .collect::<Vec<_>>();
    let identifier_facts = frozen_facts::load_for_rule(
        tx,
        dataset_snapshot_id,
        rule_id,
        snapshot.strong_identifier_fact_count,
        snapshot.strong_identifier_fact_set_sha256.as_deref(),
    )
    .await?;
    let materialized = materialize_rule_input(rule_id, configuration, &members, &identifier_facts)?;
    Ok(SnapshotRuleInput {
        value: materialized.value,
        input_sha256: materialized.input_sha256,
        snapshot_sha256,
        rule_configuration_sha256,
        rule_code_sha256: rule_code_sha256.trim().to_owned(),
    })
}

fn validate_selection(
    selection: &Value,
    rule_version_id: Uuid,
    rule_id: &str,
    rule_configuration_sha256: &str,
    rule_code_sha256: &str,
) -> Result<(), Failure> {
    let object = selection
        .as_object()
        .ok_or_else(|| snapshot_invalid("selectionSpec"))?;
    let selected_version = object
        .get("ruleVersionId")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok());
    if object.get("snapshotKind").and_then(Value::as_str) != Some("DETECTION_DATASET")
        || object.get("ruleId").and_then(Value::as_str) != Some(rule_id)
        || selected_version != Some(rule_version_id)
        || object
            .get("ruleConfigurationSha256")
            .and_then(Value::as_str)
            != Some(rule_configuration_sha256)
        || object.get("ruleCodeSha256").and_then(Value::as_str) != Some(rule_code_sha256.trim())
        || object.get("cohortSpec").and_then(Value::as_array).is_none()
    {
        return Err(snapshot_invalid("selection authority"));
    }
    Ok(())
}

fn is_lower_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}

fn snapshot_invalid(detail: &str) -> Failure {
    Failure::Terminal("RULE_SNAPSHOT_AUTHORITY_INVALID", detail.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selection_binding_requires_exact_rule_digests() {
        let rule_version_id = Uuid::from_u128(1);
        let selection = serde_json::json!({
            "snapshotKind":"DETECTION_DATASET",
            "ruleId":"PRICE_OUTLIER",
            "ruleVersionId":rule_version_id,
            "ruleConfigurationSha256":"a".repeat(64),
            "ruleCodeSha256":"b".repeat(64),
            "cohortSpec":[],
        });
        assert!(
            validate_selection(
                &selection,
                rule_version_id,
                "PRICE_OUTLIER",
                &"a".repeat(64),
                &"b".repeat(64),
            )
            .is_ok()
        );
        assert!(
            validate_selection(
                &selection,
                rule_version_id,
                "PRICE_OUTLIER",
                &"c".repeat(64),
                &"b".repeat(64),
            )
            .is_err()
        );
    }

    #[test]
    fn snapshot_sha256_requires_lowercase_hex() {
        assert!(is_lower_sha256(&"a".repeat(64)));
        assert!(!is_lower_sha256(&"A".repeat(64)));
        assert!(!is_lower_sha256("not-a-digest"));
    }
}
