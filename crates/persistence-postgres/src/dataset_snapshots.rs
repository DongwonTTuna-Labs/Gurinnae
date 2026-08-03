#![forbid(unsafe_code)]

use gurine_application::detection::{
    BuildConflictDatasetSnapshot, BuildGeneralDatasetSnapshot, DatasetSnapshotFuture,
    DatasetSnapshotRepository, DatasetSnapshotRequestError, GeneralDatasetSnapshotBuildReceipt,
    LoadConflictDatasetSnapshot,
};
use gurine_detection::snapshot::{
    ConflictInputOwnerRow, DatasetSnapshot, DatasetSnapshotBuildReceipt, DatasetSnapshotError,
    FrozenConflictInput, FrozenRelationshipOwnerRow,
};
use sqlx::PgConnection;

/// PostgreSQL adapter for the immutable detection snapshot owners.
///
/// The adapter has no table-level child write path. The security-definer build
/// routines own snapshot creation/finalization, while conflict reads re-enter
/// the security-definer integrity checks before Rust restores the aggregate.
pub struct PostgresDatasetSnapshotRepository<'connection> {
    connection: &'connection mut PgConnection,
}

impl<'connection> PostgresDatasetSnapshotRepository<'connection> {
    pub const fn new(connection: &'connection mut PgConnection) -> Self {
        Self { connection }
    }

    async fn build_owner(
        &mut self,
        request: &BuildConflictDatasetSnapshot,
    ) -> Result<DatasetSnapshotBuildReceipt, sqlx::Error> {
        let row = sqlx::query!(
            "SELECT snapshot_id AS \"snapshot_id!\", \
                    btrim(snapshot_sha256::text) AS \"snapshot_sha256!: String\", \
                    member_count AS \"member_count!\", \
                    conflict_input_count AS \"conflict_input_count!\", \
                    btrim(conflict_input_set_sha256::text) \
                      AS \"conflict_input_set_sha256!: String\", \
                    replayed AS \"replayed!\" \
               FROM core.build_conflict_detection_dataset_snapshot_v2($1,$2,$3)",
            request.job_id(),
            request.lease_token(),
            request.fencing_token(),
        )
        .fetch_one(&mut *self.connection)
        .await?;
        DatasetSnapshotBuildReceipt::from_owner_result(
            row.snapshot_id,
            row.snapshot_sha256,
            row.member_count,
            row.conflict_input_count,
            row.conflict_input_set_sha256,
            row.replayed,
        )
        .map_err(domain_decode)
    }

    async fn build_general_owner(
        &mut self,
        request: &BuildGeneralDatasetSnapshot,
    ) -> Result<GeneralDatasetSnapshotBuildReceipt, sqlx::Error> {
        let row = sqlx::query!(
            "SELECT snapshot_id AS \"snapshot_id!\", \
                    btrim(snapshot_sha256::text) AS \"snapshot_sha256!: String\", \
                    member_count AS \"member_count!\", \
                    strong_identifier_fact_count AS \"strong_identifier_fact_count!\", \
                    btrim(strong_identifier_fact_set_sha256::text) \
                      AS \"strong_identifier_fact_set_sha256!: String\", \
                    replayed AS \"replayed!\" \
               FROM core.build_detection_dataset_snapshot_v1($1,$2,$3)",
            request.job_id(),
            request.lease_token(),
            request.fencing_token(),
        )
        .fetch_one(&mut *self.connection)
        .await?;
        GeneralDatasetSnapshotBuildReceipt::from_owner_result(
            row.snapshot_id,
            row.snapshot_sha256,
            row.member_count,
            row.strong_identifier_fact_count,
            row.strong_identifier_fact_set_sha256,
            row.replayed,
        )
        .map_err(general_domain_decode)
    }

    async fn load_owner(
        &mut self,
        request: &LoadConflictDatasetSnapshot,
    ) -> Result<DatasetSnapshot, sqlx::Error> {
        let header = request.header();
        let rule = request.rule_version();
        let rule_id = rule.rule_id().as_str();
        let snapshot_sha256 = header.snapshot_sha256().as_str();
        let input = sqlx::query!(
            "SELECT rule_id AS \"rule_id!\", \
                    rule_version_id AS \"rule_version_id!\", \
                    coverage_status AS \"coverage_status!\", \
                    input_payload AS \"input_payload!\", \
                    input_canonical AS \"input_canonical!\", \
                    btrim(input_sha256::text) AS \"input_sha256!: String\" \
               FROM core.read_conflict_detection_input_v2($1,$2,$3::char(64),$4,$5)",
            header.snapshot_id(),
            header.producer_generation(),
            snapshot_sha256,
            rule_id,
            rule.version_id(),
        )
        .fetch_one(&mut *self.connection)
        .await?;
        let frozen_input = FrozenConflictInput::restore(
            rule.clone(),
            ConflictInputOwnerRow {
                rule_id: input.rule_id,
                rule_version_id: input.rule_version_id,
                coverage_status: input.coverage_status,
                payload_json: serde_json::to_vec(&input.input_payload)
                    .map_err(|error| sqlx::Error::Decode(Box::new(error)))?,
                canonical: input.input_canonical,
                input_sha256: input.input_sha256,
            },
        )
        .map_err(domain_decode)?;
        let rows = sqlx::query!(
            "SELECT assertion_ordinal AS \"assertion_ordinal!\", \
                    assertion_payload AS \"assertion_payload!\" \
               FROM core.read_frozen_relationship_assertions_for_rule_v2( \
                    $1,$2,$3::char(64),$4,$5 \
               ) \
              ORDER BY assertion_ordinal",
            header.snapshot_id(),
            header.producer_generation(),
            snapshot_sha256,
            rule_id,
            rule.version_id(),
        )
        .fetch_all(&mut *self.connection)
        .await?;
        let relationships = rows
            .into_iter()
            .map(|row| {
                let assertion_payload_json = serde_json::to_vec(&row.assertion_payload)
                    .map_err(|error| sqlx::Error::Decode(Box::new(error)))?;
                Ok::<_, sqlx::Error>(FrozenRelationshipOwnerRow {
                    assertion_ordinal: row.assertion_ordinal,
                    assertion_payload_json,
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        DatasetSnapshot::restore(header.clone(), frozen_input, relationships).map_err(domain_decode)
    }
}

impl DatasetSnapshotRepository for PostgresDatasetSnapshotRepository<'_> {
    type Error = sqlx::Error;

    fn build<'a>(
        &'a mut self,
        request: &'a BuildConflictDatasetSnapshot,
    ) -> DatasetSnapshotFuture<'a, DatasetSnapshotBuildReceipt, Self::Error> {
        Box::pin(async move { self.build_owner(request).await })
    }

    fn build_general<'a>(
        &'a mut self,
        request: &'a BuildGeneralDatasetSnapshot,
    ) -> DatasetSnapshotFuture<'a, GeneralDatasetSnapshotBuildReceipt, Self::Error> {
        Box::pin(async move { self.build_general_owner(request).await })
    }

    fn load<'a>(
        &'a mut self,
        request: &'a LoadConflictDatasetSnapshot,
    ) -> DatasetSnapshotFuture<'a, DatasetSnapshot, Self::Error> {
        Box::pin(async move { self.load_owner(request).await })
    }
}

fn domain_decode(error: DatasetSnapshotError) -> sqlx::Error {
    sqlx::Error::Decode(Box::new(error))
}

fn general_domain_decode(error: DatasetSnapshotRequestError) -> sqlx::Error {
    sqlx::Error::Decode(Box::new(error))
}
