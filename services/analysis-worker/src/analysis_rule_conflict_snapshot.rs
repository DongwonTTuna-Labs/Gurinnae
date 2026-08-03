use gurine_application::detection::{DatasetSnapshotUseCase, LoadConflictDatasetSnapshot};
use gurine_detection::snapshot::{
    ConflictRuleId, ConflictRuleVersion, DatasetSnapshotHeader, Sha256Digest,
};
use gurine_persistence_postgres::dataset_snapshots::PostgresDatasetSnapshotRepository;
use serde_json::Value;
use sqlx::{Postgres, Transaction};
use uuid::Uuid;

use super::{Failure, database};

#[derive(Debug)]
pub(super) struct FrozenConflictInput {
    pub payload: Value,
    pub input_sha256: String,
}

pub(super) async fn load(
    tx: &mut Transaction<'_, Postgres>,
    dataset_snapshot_id: Uuid,
    producer_generation: i64,
    snapshot_sha256: &str,
    rule_id: ConflictRuleId,
    rule_version_id: Uuid,
    expected_rule_version_digest: &str,
) -> Result<FrozenConflictInput, Failure> {
    let header = DatasetSnapshotHeader::ready(
        dataset_snapshot_id,
        producer_generation,
        parse_digest(snapshot_sha256, "snapshotSha256")?,
    )
    .map_err(|_| conflict_input_invalid("snapshot header"))?;
    let authority = ConflictRuleVersion::new(
        rule_id,
        rule_version_id,
        parse_digest(expected_rule_version_digest.trim(), "ruleVersionDigest")?,
    )
    .map_err(|_| conflict_input_invalid("rule version"))?;
    let request = LoadConflictDatasetSnapshot::new(header, authority);
    let snapshot = {
        let mut repository = PostgresDatasetSnapshotRepository::new(tx);
        DatasetSnapshotUseCase::new(&mut repository)
            .load(&request)
            .await
            .map_err(repository_failure)?
    };
    let input = snapshot.conflict_input();
    let payload = serde_json::from_slice(input.canonical())
        .map_err(|_| conflict_input_invalid("inputCanonical"))?;
    Ok(FrozenConflictInput {
        payload,
        input_sha256: input.input_sha256().as_str().to_owned(),
    })
}

fn parse_digest(value: &str, detail: &'static str) -> Result<Sha256Digest, Failure> {
    Sha256Digest::parse(value).map_err(|_| conflict_input_invalid(detail))
}

fn repository_failure(error: sqlx::Error) -> Failure {
    match error {
        sqlx::Error::Decode(_) => conflict_input_invalid("owner result"),
        other => database(other),
    }
}

fn conflict_input_invalid(detail: &str) -> Failure {
    Failure::Terminal(
        "RULE_CONFLICT_SNAPSHOT_AUTHORITY_INVALID",
        detail.to_owned(),
    )
}
