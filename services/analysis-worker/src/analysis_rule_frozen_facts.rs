use serde_json::{Value, json};
use sqlx::{Postgres, Transaction};
use uuid::Uuid;

use super::{Failure, canonical_bytes, database, is_lower_sha256, sha256};
use crate::runner::analysis_rule_materializer::StrongIdentifierFact;

const SHARED_IDENTITY_RULE: &str = "SHARED_SUPPLIER_IDENTITY";
const FACT_SCHEMA_VERSION: &str = "dataset-snapshot-strong-identifier-fact.v1";

#[derive(Clone, Debug, Eq, PartialEq)]
struct FrozenStrongIdentifierFact {
    snapshot_member_id: Uuid,
    snapshot_member_digest: String,
    snapshot_member_object_version: i64,
    snapshot_member_object_content_sha256: String,
    contract_id: Uuid,
    fact_ordinal: i64,
    supplier_id: Uuid,
    identifier_id: Uuid,
    scheme: String,
    value_hash: String,
    verification_status: String,
    proof_state: String,
    candidate_id: Uuid,
    candidate_revision: i64,
    candidate_digest: String,
    source_locator_digest: String,
    verification_evidence_digest: String,
    identifier_fact_digest: String,
    fact_canonical: Vec<u8>,
    fact_digest: String,
}

pub(super) async fn load_for_rule(
    tx: &mut Transaction<'_, Postgres>,
    dataset_snapshot_id: Uuid,
    rule_id: &str,
    expected_count: Option<i64>,
    expected_set_sha256: Option<&str>,
) -> Result<Vec<StrongIdentifierFact>, Failure> {
    if rule_id != SHARED_IDENTITY_RULE {
        return Ok(Vec::new());
    }
    let expected_count = expected_count
        .filter(|value| *value >= 0)
        .ok_or_else(|| frozen_invalid("strong identifier fact count"))?;
    let expected_set_sha256 = expected_set_sha256
        .filter(|value| is_lower_sha256(value))
        .ok_or_else(|| frozen_invalid("strong identifier fact set digest"))?;
    let rows = sqlx::query!(
        "SELECT fact.snapshot_member_id, \
                btrim(fact.snapshot_member_digest::text) \
                  AS \"snapshot_member_digest!: String\", \
                fact.snapshot_member_object_version, \
                btrim(fact.snapshot_member_object_content_sha256::text) \
                  AS \"snapshot_member_object_content_sha256!: String\", \
                fact.contract_id,fact.fact_ordinal,fact.supplier_id, \
                fact.identifier_id,fact.scheme, \
                btrim(fact.value_hash::text) AS \"value_hash!: String\", \
                fact.verification_status,fact.proof_state, \
                fact.candidate_id,fact.candidate_revision, \
                btrim(fact.candidate_digest::text) AS \"candidate_digest!: String\", \
                btrim(fact.source_locator_digest::text) \
                  AS \"source_locator_digest!: String\", \
                btrim(fact.verification_evidence_digest::text) \
                  AS \"verification_evidence_digest!: String\", \
                btrim(fact.identifier_fact_digest::text) \
                  AS \"identifier_fact_digest!: String\", \
                fact.fact_canonical, \
                btrim(fact.fact_digest::text) AS \"fact_digest!: String\" \
           FROM core.dataset_snapshot_strong_identifier_facts fact \
           JOIN core.dataset_snapshot_members member \
             ON member.id=fact.snapshot_member_id \
            AND member.dataset_snapshot_id=fact.dataset_snapshot_id \
            AND member.member_digest=fact.snapshot_member_digest \
            AND member.object_type='CONTRACT' \
            AND member.object_id=fact.contract_id \
            AND member.object_version=fact.snapshot_member_object_version \
            AND member.object_content_sha256= \
                fact.snapshot_member_object_content_sha256 \
            AND member.canonical_payload->>'supplierId'=fact.supplier_id::text \
          WHERE fact.dataset_snapshot_id=$1 \
          ORDER BY fact.fact_ordinal,fact.id",
        dataset_snapshot_id,
    )
    .fetch_all(&mut **tx)
    .await
    .map_err(database)?
    .into_iter()
    .map(|row| FrozenStrongIdentifierFact {
        snapshot_member_id: row.snapshot_member_id,
        snapshot_member_digest: row.snapshot_member_digest,
        snapshot_member_object_version: row.snapshot_member_object_version,
        snapshot_member_object_content_sha256: row.snapshot_member_object_content_sha256,
        contract_id: row.contract_id,
        fact_ordinal: row.fact_ordinal,
        supplier_id: row.supplier_id,
        identifier_id: row.identifier_id,
        scheme: row.scheme,
        value_hash: row.value_hash,
        verification_status: row.verification_status,
        proof_state: row.proof_state,
        candidate_id: row.candidate_id,
        candidate_revision: row.candidate_revision,
        candidate_digest: row.candidate_digest,
        source_locator_digest: row.source_locator_digest,
        verification_evidence_digest: row.verification_evidence_digest,
        identifier_fact_digest: row.identifier_fact_digest,
        fact_canonical: row.fact_canonical,
        fact_digest: row.fact_digest,
    })
    .collect::<Vec<_>>();
    validate_frozen_set(
        dataset_snapshot_id,
        expected_count,
        expected_set_sha256,
        rows,
    )
}

fn validate_frozen_set(
    snapshot_id: Uuid,
    expected_count: i64,
    expected_set_sha256: &str,
    mut rows: Vec<FrozenStrongIdentifierFact>,
) -> Result<Vec<StrongIdentifierFact>, Failure> {
    rows.sort_by_key(|row| row.fact_ordinal);
    if i64::try_from(rows.len()).ok() != Some(expected_count) {
        return Err(frozen_invalid("strong identifier fact count mismatch"));
    }
    let mut facts = Vec::with_capacity(rows.len());
    let mut fact_digests = Vec::with_capacity(rows.len());
    for (index, row) in rows.into_iter().enumerate() {
        if i64::try_from(index).ok() != Some(row.fact_ordinal) {
            return Err(frozen_invalid("strong identifier fact ordinal"));
        }
        validate_frozen_fact(snapshot_id, &row)?;
        fact_digests.push(Value::String(row.fact_digest));
        facts.push(StrongIdentifierFact {
            supplier_id: row.supplier_id,
            scheme: row.scheme,
            value_hash: row.value_hash,
            verification_status: row.verification_status,
            proof_state: row.proof_state,
        });
    }
    let actual_set_sha256 = sha256(&canonical_bytes(&Value::Array(fact_digests))?);
    if actual_set_sha256 != expected_set_sha256 {
        return Err(frozen_invalid("strong identifier fact set mismatch"));
    }
    Ok(facts)
}

fn validate_frozen_fact(
    snapshot_id: Uuid,
    row: &FrozenStrongIdentifierFact,
) -> Result<(), Failure> {
    if row.snapshot_member_object_version < 1
        || row.candidate_revision < 1
        || !is_canonical_scheme(&row.scheme)
        || row.verification_status != "VERIFIED"
        || row.proof_state != "PROVEN_V1"
        || [
            row.snapshot_member_digest.as_str(),
            row.snapshot_member_object_content_sha256.as_str(),
            row.value_hash.as_str(),
            row.candidate_digest.as_str(),
            row.source_locator_digest.as_str(),
            row.verification_evidence_digest.as_str(),
            row.identifier_fact_digest.as_str(),
            row.fact_digest.as_str(),
        ]
        .into_iter()
        .any(|value| !is_lower_sha256(value))
    {
        return Err(frozen_invalid("strong identifier fact shape"));
    }
    let expected_canonical = canonical_frozen_fact(snapshot_id, row)?;
    if expected_canonical != row.fact_canonical || sha256(&expected_canonical) != row.fact_digest {
        return Err(frozen_invalid("strong identifier fact digest"));
    }
    Ok(())
}

fn canonical_frozen_fact(
    snapshot_id: Uuid,
    row: &FrozenStrongIdentifierFact,
) -> Result<Vec<u8>, Failure> {
    canonical_bytes(&json!({
        "schemaVersion": FACT_SCHEMA_VERSION,
        "snapshotId": snapshot_id,
        "snapshotMemberId": row.snapshot_member_id,
        "snapshotMemberDigest": row.snapshot_member_digest,
        "snapshotMemberObjectType": "CONTRACT",
        "snapshotMemberObjectVersion": row.snapshot_member_object_version,
        "snapshotMemberObjectContentSha256": row.snapshot_member_object_content_sha256,
        "contractId": row.contract_id,
        "factOrdinal": row.fact_ordinal,
        "supplierId": row.supplier_id,
        "identifierId": row.identifier_id,
        "scheme": row.scheme,
        "valueHash": row.value_hash,
        "verificationStatus": row.verification_status,
        "proofState": row.proof_state,
        "candidateId": row.candidate_id,
        "candidateRevision": row.candidate_revision,
        "candidateDigest": row.candidate_digest,
        "sourceLocatorDigest": row.source_locator_digest,
        "verificationEvidenceDigest": row.verification_evidence_digest,
        "identifierFactDigest": row.identifier_fact_digest,
    }))
}

fn is_canonical_scheme(scheme: &str) -> bool {
    matches!(
        scheme,
        "KOREAN_BUSINESS_NUMBER" | "OPEN_DART_CORP_CODE" | "KONEPS_PARTY_KEY"
    )
}

fn frozen_invalid(detail: &str) -> Failure {
    Failure::Terminal("RULE_SNAPSHOT_STRONG_FACT_INVALID", detail.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frozen_fact(snapshot_id: Uuid, ordinal: i64, scheme: &str) -> FrozenStrongIdentifierFact {
        let mut fact = FrozenStrongIdentifierFact {
            snapshot_member_id: Uuid::from_u128(10),
            snapshot_member_digest: "a".repeat(64),
            snapshot_member_object_version: 1,
            snapshot_member_object_content_sha256: "0".repeat(64),
            contract_id: Uuid::from_u128(15),
            fact_ordinal: ordinal,
            supplier_id: Uuid::from_u128(20),
            identifier_id: Uuid::from_u128(30 + u128::try_from(ordinal).unwrap_or_default()),
            scheme: scheme.to_owned(),
            value_hash: "b".repeat(64),
            verification_status: "VERIFIED".to_owned(),
            proof_state: "PROVEN_V1".to_owned(),
            candidate_id: Uuid::from_u128(40),
            candidate_revision: 1,
            candidate_digest: "c".repeat(64),
            source_locator_digest: "d".repeat(64),
            verification_evidence_digest: "e".repeat(64),
            identifier_fact_digest: "f".repeat(64),
            fact_canonical: Vec::new(),
            fact_digest: String::new(),
        };
        fact.fact_canonical = canonical_frozen_fact(snapshot_id, &fact).unwrap_or_default();
        fact.fact_digest = sha256(&fact.fact_canonical);
        fact
    }

    fn set_digest(rows: &[FrozenStrongIdentifierFact]) -> String {
        sha256(
            &canonical_bytes(&Value::Array(
                rows.iter()
                    .map(|row| Value::String(row.fact_digest.clone()))
                    .collect(),
            ))
            .unwrap_or_default(),
        )
    }

    #[test]
    fn exact_canonical_frozen_schemes_are_accepted() {
        let snapshot_id = Uuid::from_u128(1);
        let rows = [
            frozen_fact(snapshot_id, 0, "KOREAN_BUSINESS_NUMBER"),
            frozen_fact(snapshot_id, 1, "OPEN_DART_CORP_CODE"),
            frozen_fact(snapshot_id, 2, "KONEPS_PARTY_KEY"),
        ];
        let result = validate_frozen_set(snapshot_id, 3, &set_digest(&rows), rows.to_vec());
        assert!(
            matches!(result, Ok(facts) if facts.len() == 3 && facts.iter().all(|fact| fact.verification_status == "VERIFIED" && fact.proof_state == "PROVEN_V1"))
        );
    }

    #[test]
    fn legacy_scheme_and_digest_mismatch_fail_closed() {
        let snapshot_id = Uuid::from_u128(1);
        let legacy = frozen_fact(snapshot_id, 0, "BUSINESS_NUMBER");
        assert!(
            validate_frozen_set(
                snapshot_id,
                1,
                &set_digest(std::slice::from_ref(&legacy)),
                vec![legacy]
            )
            .is_err()
        );

        let mut mismatched = frozen_fact(snapshot_id, 0, "KONEPS_PARTY_KEY");
        let expected_set = set_digest(std::slice::from_ref(&mismatched));
        mismatched.value_hash = "0".repeat(64);
        assert!(validate_frozen_set(snapshot_id, 1, &expected_set, vec![mismatched]).is_err());
    }

    #[test]
    fn missing_row_or_set_digest_mismatch_fails_closed() {
        let snapshot_id = Uuid::from_u128(1);
        let row = frozen_fact(snapshot_id, 0, "KONEPS_PARTY_KEY");
        assert!(
            validate_frozen_set(
                snapshot_id,
                2,
                &set_digest(std::slice::from_ref(&row)),
                vec![row.clone()]
            )
            .is_err()
        );
        assert!(validate_frozen_set(snapshot_id, 1, &"0".repeat(64), vec![row]).is_err());
    }

    #[test]
    fn contract_member_binding_change_fails_closed() {
        let snapshot_id = Uuid::from_u128(1);
        let mut row = frozen_fact(snapshot_id, 0, "KONEPS_PARTY_KEY");
        let expected_set = set_digest(std::slice::from_ref(&row));
        row.contract_id = Uuid::from_u128(99);
        assert!(validate_frozen_set(snapshot_id, 1, &expected_set, vec![row]).is_err());
    }
}
