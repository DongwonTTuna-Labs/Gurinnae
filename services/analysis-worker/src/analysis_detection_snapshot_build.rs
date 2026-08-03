use gurine_jobs::postgres::ClaimedJob;
use serde_json::{Value, json};
use sqlx::PgPool;
use uuid::Uuid;

use super::{Failure, database, required};

const JOB_SCHEMA_VERSION: &str = "detection-snapshot-build-job.v1";

struct SnapshotBuildClaim<'a> {
    job_id: Uuid,
    lease_token: Uuid,
    fencing_token: i64,
    payload: &'a Value,
}

#[derive(Clone)]
struct BuildOwnerRow {
    snapshot_id: Option<Uuid>,
    snapshot_sha256: Option<String>,
    member_count: Option<i64>,
    strong_identifier_fact_count: Option<i64>,
    strong_identifier_fact_set_sha256: Option<String>,
    replayed: Option<bool>,
}

#[derive(Debug, Eq, PartialEq)]
struct BuildOwnerResult {
    snapshot_id: Uuid,
    snapshot_sha256: String,
    member_count: i64,
    strong_identifier_fact_count: i64,
    strong_identifier_fact_set_sha256: String,
    replayed: bool,
}

pub(super) async fn build_detection_dataset_snapshot(
    pool: &PgPool,
    job: &ClaimedJob,
) -> Result<Value, Failure> {
    let claim = snapshot_build_claim(job);
    validate_claim(&claim)?;
    let mut tx = pool.begin().await.map_err(database)?;
    sqlx::query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        .execute(&mut *tx)
        .await
        .map_err(database)?;
    let built = sqlx::query!(
        "SELECT snapshot_id, \
                btrim(snapshot_sha256::text) AS \"snapshot_sha256?: String\", \
                member_count, strong_identifier_fact_count, \
                btrim(strong_identifier_fact_set_sha256::text) \
                  AS \"strong_identifier_fact_set_sha256?: String\", \
                replayed \
           FROM core.build_detection_dataset_snapshot_v1($1,$2,$3)",
        claim.job_id,
        claim.lease_token,
        claim.fencing_token,
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(database)?;
    let result = build_owner_result(BuildOwnerRow {
        snapshot_id: built.snapshot_id,
        snapshot_sha256: built.snapshot_sha256,
        member_count: built.member_count,
        strong_identifier_fact_count: built.strong_identifier_fact_count,
        strong_identifier_fact_set_sha256: built.strong_identifier_fact_set_sha256,
        replayed: built.replayed,
    })?;
    tx.commit().await.map_err(database)?;
    Ok(json!({
        "snapshotId": result.snapshot_id,
        "snapshotSha256": result.snapshot_sha256,
        "memberCount": result.member_count,
        "strongIdentifierFactCount": result.strong_identifier_fact_count,
        "strongIdentifierFactSetSha256": result.strong_identifier_fact_set_sha256,
        "replayed": result.replayed,
    }))
}

fn snapshot_build_claim(job: &ClaimedJob) -> SnapshotBuildClaim<'_> {
    SnapshotBuildClaim {
        job_id: job.id,
        lease_token: job.fence.lease_token,
        fencing_token: job.fence.fencing_token,
        payload: &job.payload,
    }
}

fn validate_claim(claim: &SnapshotBuildClaim<'_>) -> Result<(), Failure> {
    if claim.fencing_token < 1 {
        return Err(authority_invalid("job fence"));
    }
    validate_request(claim.payload)
}

fn validate_request(payload: &Value) -> Result<(), Failure> {
    let object = payload
        .as_object()
        .ok_or_else(|| authority_invalid("job payload"))?;
    let keys = [
        "schemaVersion",
        "ruleVersionId",
        "ruleId",
        "contractIdentitySetSha256",
        "contractCount",
    ];
    if object.len() != keys.len() || keys.iter().any(|key| !object.contains_key(*key)) {
        return Err(authority_invalid("job payload keys"));
    }
    if object.get("schemaVersion").and_then(Value::as_str) != Some(JOB_SCHEMA_VERSION) {
        return Err(authority_invalid("schemaVersion"));
    }
    object
        .get("ruleVersionId")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| authority_invalid("ruleVersionId"))?;
    object
        .get("ruleId")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty() && value.trim() == *value)
        .ok_or_else(|| authority_invalid("ruleId"))?;
    object
        .get("contractIdentitySetSha256")
        .and_then(Value::as_str)
        .filter(|value| is_lower_sha256(value))
        .ok_or_else(|| authority_invalid("contractIdentitySetSha256"))?;
    object
        .get("contractCount")
        .and_then(Value::as_i64)
        .filter(|value| *value >= 0)
        .ok_or_else(|| authority_invalid("contractCount"))?;
    Ok(())
}

fn build_owner_result(row: BuildOwnerRow) -> Result<BuildOwnerResult, Failure> {
    let result = BuildOwnerResult {
        snapshot_id: required(row.snapshot_id).map_err(database)?,
        snapshot_sha256: required(row.snapshot_sha256).map_err(database)?,
        member_count: required(row.member_count).map_err(database)?,
        strong_identifier_fact_count: required(row.strong_identifier_fact_count)
            .map_err(database)?,
        strong_identifier_fact_set_sha256: required(row.strong_identifier_fact_set_sha256)
            .map_err(database)?,
        replayed: required(row.replayed).map_err(database)?,
    };
    validate_build_result(
        &result.snapshot_sha256,
        result.member_count,
        result.strong_identifier_fact_count,
        &result.strong_identifier_fact_set_sha256,
    )?;
    Ok(result)
}

fn validate_build_result(
    snapshot_sha256: &str,
    member_count: i64,
    fact_count: i64,
    fact_set_sha256: &str,
) -> Result<(), Failure> {
    if member_count < 0
        || fact_count < 0
        || !is_lower_sha256(snapshot_sha256)
        || !is_lower_sha256(fact_set_sha256)
    {
        return Err(authority_invalid("owner result"));
    }
    Ok(())
}

fn is_lower_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}

fn authority_invalid(detail: &str) -> Failure {
    Failure::Terminal("DETECTION_SNAPSHOT_AUTHORITY_INVALID", detail.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use gurine_jobs::fencing::Fence;

    const SHA: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    fn valid_payload() -> Value {
        json!({
            "schemaVersion": JOB_SCHEMA_VERSION,
            "ruleVersionId": Uuid::from_u128(1),
            "ruleId": "PRICE_OUTLIER",
            "contractIdentitySetSha256": SHA,
            "contractCount": 0,
        })
    }

    fn claimed_job(payload: Value) -> ClaimedJob {
        ClaimedJob {
            id: Uuid::from_u128(2),
            job_type: "DETECTION_SNAPSHOT_BUILD".to_owned(),
            queue: "analysis-worker".to_owned(),
            payload,
            attempt: 1,
            max_attempts: 3,
            fence: Fence {
                lease_token: Uuid::from_u128(3),
                fencing_token: 4,
            },
            lease_expires_at: time::OffsetDateTime::UNIX_EPOCH,
        }
    }

    fn valid_owner_row() -> BuildOwnerRow {
        BuildOwnerRow {
            snapshot_id: Some(Uuid::from_u128(5)),
            snapshot_sha256: Some(SHA.to_owned()),
            member_count: Some(6),
            strong_identifier_fact_count: Some(7),
            strong_identifier_fact_set_sha256: Some(SHA.to_owned()),
            replayed: Some(false),
        }
    }

    fn assert_owner_row_invalid(mutate: impl FnOnce(&mut BuildOwnerRow)) {
        let mut row = valid_owner_row();
        mutate(&mut row);
        assert!(build_owner_result(row).is_err());
    }

    #[test]
    fn request_is_validated_without_reconstructing_owner_payload() {
        let valid = valid_payload();
        let job = claimed_job(valid.clone());
        let claim = snapshot_build_claim(&job);
        assert!(std::ptr::eq(claim.payload, &job.payload));
        assert_eq!(claim.payload, &valid);
        assert_eq!(claim.job_id, job.id);
        assert_eq!(claim.lease_token, job.fence.lease_token);
        assert_eq!(claim.fencing_token, job.fence.fencing_token);
        assert!(validate_claim(&claim).is_ok());
        let mut extra = valid;
        extra["untrusted"] = json!(true);
        assert!(validate_request(&extra).is_err());

        let mut invalid_fence_job = claimed_job(valid_payload());
        invalid_fence_job.fence.fencing_token = 0;
        assert!(validate_claim(&snapshot_build_claim(&invalid_fence_job)).is_err());
    }

    #[test]
    fn owner_result_requires_all_fields_and_canonical_values() {
        assert!(matches!(
            build_owner_result(valid_owner_row()),
            Ok(BuildOwnerResult {
                member_count: 6,
                strong_identifier_fact_count: 7,
                replayed: false,
                ..
            })
        ));
        assert_owner_row_invalid(|row| row.snapshot_id = None);
        assert_owner_row_invalid(|row| row.snapshot_sha256 = None);
        assert_owner_row_invalid(|row| row.member_count = None);
        assert_owner_row_invalid(|row| row.strong_identifier_fact_count = None);
        assert_owner_row_invalid(|row| row.strong_identifier_fact_set_sha256 = None);
        assert_owner_row_invalid(|row| row.replayed = None);
        assert_owner_row_invalid(|row| row.member_count = Some(-1));
        assert_owner_row_invalid(|row| row.strong_identifier_fact_count = Some(-1));
        assert_owner_row_invalid(|row| row.snapshot_sha256 = Some("A".repeat(64)));
        assert_owner_row_invalid(|row| {
            row.strong_identifier_fact_set_sha256 = Some("short".to_owned());
        });
    }
}
