use gurine_application::detection::{
    BuildConflictDatasetSnapshot, BuildGeneralDatasetSnapshot, DatasetSnapshotUseCase,
};
use gurine_detection::snapshot::ConflictRuleId;
use gurine_jobs::postgres::ClaimedJob;
use gurine_persistence_postgres::dataset_snapshots::PostgresDatasetSnapshotRepository;
use serde_json::{Value, json};
use sqlx::PgPool;
use uuid::Uuid;

use super::{Failure, database};

const JOB_SCHEMA_VERSION: &str = "detection-snapshot-build-job.v1";

struct SnapshotBuildClaim<'a> {
    job_id: Uuid,
    lease_token: Uuid,
    fencing_token: i64,
    payload: &'a Value,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SnapshotBuildRoute {
    GeneralV1,
    ConflictV2,
}

pub(super) async fn build_detection_dataset_snapshot(
    pool: &PgPool,
    job: &ClaimedJob,
) -> Result<Value, Failure> {
    let claim = snapshot_build_claim(job);
    let route = validate_claim(&claim)?;
    let mut tx = pool.begin().await.map_err(database)?;
    sqlx::query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        .execute(&mut *tx)
        .await
        .map_err(database)?;
    let result = match route {
        SnapshotBuildRoute::GeneralV1 => build_general_snapshot(&mut tx, &claim).await?,
        SnapshotBuildRoute::ConflictV2 => build_conflict_snapshot(&mut tx, &claim).await?,
    };
    tx.commit().await.map_err(database)?;
    Ok(result)
}

async fn build_general_snapshot(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    claim: &SnapshotBuildClaim<'_>,
) -> Result<Value, Failure> {
    let request =
        BuildGeneralDatasetSnapshot::new(claim.job_id, claim.lease_token, claim.fencing_token)
            .map_err(|_| authority_invalid("job fence"))?;
    let result = {
        let mut repository = PostgresDatasetSnapshotRepository::new(tx);
        DatasetSnapshotUseCase::new(&mut repository)
            .build_general(&request)
            .await
            .map_err(repository_failure)?
    };
    Ok(json!({
        "snapshotId": result.snapshot_id(),
        "snapshotSha256": result.snapshot_sha256().as_str(),
        "memberCount": result.member_count(),
        "strongIdentifierFactCount": result.strong_identifier_fact_count(),
        "strongIdentifierFactSetSha256": result.strong_identifier_fact_set_sha256().as_str(),
        "replayed": result.replayed(),
    }))
}

async fn build_conflict_snapshot(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    claim: &SnapshotBuildClaim<'_>,
) -> Result<Value, Failure> {
    let request =
        BuildConflictDatasetSnapshot::new(claim.job_id, claim.lease_token, claim.fencing_token)
            .map_err(|_| authority_invalid("job fence"))?;
    let result = {
        let mut repository = PostgresDatasetSnapshotRepository::new(tx);
        DatasetSnapshotUseCase::new(&mut repository)
            .build(&request)
            .await
            .map_err(repository_failure)?
    };
    Ok(json!({
        "snapshotId": result.snapshot_id(),
        "snapshotSha256": result.snapshot_sha256().as_str(),
        "memberCount": 0,
        "conflictInputCount": 1,
        "conflictInputSetSha256": result.conflict_input_set_sha256().as_str(),
        "replayed": result.replayed(),
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

fn validate_claim(claim: &SnapshotBuildClaim<'_>) -> Result<SnapshotBuildRoute, Failure> {
    if claim.fencing_token < 1 {
        return Err(authority_invalid("job fence"));
    }
    validate_request(claim.payload)
}

fn validate_request(payload: &Value) -> Result<SnapshotBuildRoute, Failure> {
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
    let rule_id = object
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
    Ok(if ConflictRuleId::parse(rule_id).is_ok() {
        SnapshotBuildRoute::ConflictV2
    } else {
        // The v1 owner routine is the authority for every non-conflict rule:
        // it requires an ACTIVE rule version and an exact rule id/version pair.
        SnapshotBuildRoute::GeneralV1
    })
}

fn repository_failure(error: sqlx::Error) -> Failure {
    match error {
        sqlx::Error::Decode(_) => authority_invalid("owner result"),
        other => database(other),
    }
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
            "ruleId": "OFFICER_OVERLAP_AWARD",
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
        assert!(matches!(
            validate_claim(&claim),
            Ok(SnapshotBuildRoute::ConflictV2)
        ));
        let mut extra = valid;
        extra["untrusted"] = json!(true);
        assert!(validate_request(&extra).is_err());

        let mut invalid_fence_job = claimed_job(valid_payload());
        invalid_fence_job.fence.fencing_token = 0;
        assert!(validate_claim(&snapshot_build_claim(&invalid_fence_job)).is_err());
    }

    #[test]
    fn legacy_general_rule_keeps_the_v1_owner_route() {
        let mut payload = valid_payload();
        payload["ruleId"] = json!("CONTRACT_AMENDMENT_ESCALATION");
        assert!(matches!(
            validate_request(&payload),
            Ok(SnapshotBuildRoute::GeneralV1)
        ));

        // Unknown but syntactically valid ids also reach the v1 owner, which
        // rejects any id/version pair that is not exact and ACTIVE.
        payload["ruleId"] = json!("UNKNOWN_RULE");
        assert!(matches!(
            validate_request(&payload),
            Ok(SnapshotBuildRoute::GeneralV1)
        ));

        payload["ruleId"] = json!(" UNKNOWN_RULE");
        assert!(validate_request(&payload).is_err());
        payload["ruleId"] = json!("");
        assert!(validate_request(&payload).is_err());
    }

    #[test]
    fn exactly_the_five_conflict_rules_use_the_v2_owner_route() {
        let mut payload = valid_payload();
        for rule_id in [
            "OFFICER_OVERLAP_AWARD",
            "OWNERSHIP_LINKED_COMPETITORS",
            "BID_ROTATION",
            "REVOLVING_DOOR_CONTRACT",
            "SANCTIONED_SUCCESSOR",
        ] {
            payload["ruleId"] = json!(rule_id);
            assert!(matches!(
                validate_request(&payload),
                Ok(SnapshotBuildRoute::ConflictV2)
            ));
        }
    }
}
