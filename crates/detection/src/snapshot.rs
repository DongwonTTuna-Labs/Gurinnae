#![forbid(unsafe_code)]

use std::collections::BTreeSet;

use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use thiserror::Error;
use uuid::Uuid;

pub const DATASET_SNAPSHOT_KIND: &str = "DETECTION_DATASET";

const INPUT_SCHEMA: &str = "conflict-detection-input.v2";
const BIDDER_AUTHORITY: &str = "koneps-structured-bidder-participation";
const INPUT_KEYS: [&str; 14] = [
    "schema_version",
    "rule_id",
    "rule_version_id",
    "rule_version_digest",
    "coverage_status",
    "coverage",
    "contracts",
    "procurement_notices",
    "procurement_awards",
    "bidder_participations",
    "typed_relationship_assertions",
    "strong_identifier_facts",
    "suppliers",
    "sanctions",
];
const COVERAGE_KEYS: [&str; 7] = [
    "contracts_complete",
    "procurement_notices_complete",
    "procurement_awards_complete",
    "bidder_participations_complete",
    "typed_relationships_complete",
    "strong_identifier_facts_complete",
    "bidder_participation_authority",
];
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum DatasetSnapshotError {
    #[error("snapshot authority header is invalid")]
    InvalidHeader,
    #[error("SHA-256 digest is not lowercase hexadecimal")]
    InvalidDigest,
    #[error("owner build result violates the conflict snapshot contract")]
    InvalidBuildResult,
    #[error("conflict input is not the closed v2 document")]
    InvalidConflictInput,
    #[error("canonical JSON bytes do not bind the supplied value")]
    InvalidCanonicalJson,
    #[error("frozen relationship assertion violates the approved graph boundary")]
    InvalidRelationshipAssertion,
    #[error("snapshot contains a duplicate immutable child")]
    DuplicateSnapshotChild,
    #[error("frozen relationship rows do not match the conflict input")]
    RelationshipBindingMismatch,
}

#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct Sha256Digest(String);

impl Sha256Digest {
    pub fn parse(value: impl Into<String>) -> Result<Self, DatasetSnapshotError> {
        let value = value.into();
        if !is_digest(&value) {
            return Err(DatasetSnapshotError::InvalidDigest);
        }
        Ok(Self(value))
    }

    pub fn calculate(bytes: &[u8]) -> Self {
        Self(
            Sha256::digest(bytes)
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect(),
        )
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum ConflictRuleId {
    OfficerOverlapAward,
    OwnershipLinkedCompetitors,
    BidRotation,
    RevolvingDoorContract,
    SanctionedSuccessor,
}

impl ConflictRuleId {
    pub fn parse(value: &str) -> Result<Self, DatasetSnapshotError> {
        match value {
            "OFFICER_OVERLAP_AWARD" => Ok(Self::OfficerOverlapAward),
            "OWNERSHIP_LINKED_COMPETITORS" => Ok(Self::OwnershipLinkedCompetitors),
            "BID_ROTATION" => Ok(Self::BidRotation),
            "REVOLVING_DOOR_CONTRACT" => Ok(Self::RevolvingDoorContract),
            "SANCTIONED_SUCCESSOR" => Ok(Self::SanctionedSuccessor),
            _ => Err(DatasetSnapshotError::InvalidHeader),
        }
    }

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::OfficerOverlapAward => "OFFICER_OVERLAP_AWARD",
            Self::OwnershipLinkedCompetitors => "OWNERSHIP_LINKED_COMPETITORS",
            Self::BidRotation => "BID_ROTATION",
            Self::RevolvingDoorContract => "REVOLVING_DOOR_CONTRACT",
            Self::SanctionedSuccessor => "SANCTIONED_SUCCESSOR",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ConflictCoverageStatus {
    Complete,
    Partial,
    Blocked,
}

impl ConflictCoverageStatus {
    fn parse(value: &str) -> Result<Self, DatasetSnapshotError> {
        match value {
            "COMPLETE" => Ok(Self::Complete),
            "PARTIAL" => Ok(Self::Partial),
            "BLOCKED" => Ok(Self::Blocked),
            _ => Err(DatasetSnapshotError::InvalidConflictInput),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConflictRuleVersion {
    rule_id: ConflictRuleId,
    version_id: Uuid,
    version_digest: Sha256Digest,
}

impl ConflictRuleVersion {
    pub fn new(
        rule_id: ConflictRuleId,
        version_id: Uuid,
        version_digest: Sha256Digest,
    ) -> Result<Self, DatasetSnapshotError> {
        if version_id.is_nil() {
            return Err(DatasetSnapshotError::InvalidHeader);
        }
        Ok(Self {
            rule_id,
            version_id,
            version_digest,
        })
    }
    pub const fn rule_id(&self) -> ConflictRuleId {
        self.rule_id
    }
    pub const fn version_id(&self) -> Uuid {
        self.version_id
    }
    pub fn version_digest(&self) -> &Sha256Digest {
        &self.version_digest
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DatasetSnapshotHeader {
    snapshot_id: Uuid,
    producer_generation: i64,
    snapshot_sha256: Sha256Digest,
}

impl DatasetSnapshotHeader {
    pub fn ready(
        snapshot_id: Uuid,
        producer_generation: i64,
        snapshot_sha256: Sha256Digest,
    ) -> Result<Self, DatasetSnapshotError> {
        if snapshot_id.is_nil() || producer_generation < 1 {
            return Err(DatasetSnapshotError::InvalidHeader);
        }
        Ok(Self {
            snapshot_id,
            producer_generation,
            snapshot_sha256,
        })
    }
    pub const fn snapshot_id(&self) -> Uuid {
        self.snapshot_id
    }
    pub const fn producer_generation(&self) -> i64 {
        self.producer_generation
    }
    pub fn snapshot_sha256(&self) -> &Sha256Digest {
        &self.snapshot_sha256
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DatasetSnapshotBuildReceipt {
    snapshot_id: Uuid,
    snapshot_sha256: Sha256Digest,
    conflict_input_set_sha256: Sha256Digest,
    replayed: bool,
}

impl DatasetSnapshotBuildReceipt {
    pub fn from_owner_result(
        snapshot_id: Uuid,
        snapshot_sha256: impl Into<String>,
        member_count: i64,
        conflict_input_count: i64,
        conflict_input_set_sha256: impl Into<String>,
        replayed: bool,
    ) -> Result<Self, DatasetSnapshotError> {
        if snapshot_id.is_nil() || member_count != 0 || conflict_input_count != 1 {
            return Err(DatasetSnapshotError::InvalidBuildResult);
        }
        Ok(Self {
            snapshot_id,
            snapshot_sha256: Sha256Digest::parse(snapshot_sha256)?,
            conflict_input_set_sha256: Sha256Digest::parse(conflict_input_set_sha256)?,
            replayed,
        })
    }
    pub const fn snapshot_id(&self) -> Uuid {
        self.snapshot_id
    }
    pub fn snapshot_sha256(&self) -> &Sha256Digest {
        &self.snapshot_sha256
    }
    pub fn conflict_input_set_sha256(&self) -> &Sha256Digest {
        &self.conflict_input_set_sha256
    }
    pub const fn replayed(&self) -> bool {
        self.replayed
    }
}

#[derive(Debug)]
pub struct ConflictInputOwnerRow {
    pub rule_id: String,
    pub rule_version_id: Uuid,
    pub coverage_status: String,
    pub payload_json: Vec<u8>,
    pub canonical: Vec<u8>,
    pub input_sha256: String,
}

#[derive(Debug)]
pub struct FrozenRelationshipOwnerRow {
    pub assertion_ordinal: i64,
    pub assertion_payload_json: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct FrozenConflictInput {
    authority: ConflictRuleVersion,
    coverage_status: ConflictCoverageStatus,
    canonical: Vec<u8>,
    input_sha256: Sha256Digest,
    relationship_payloads: Vec<Value>,
}

pub type ConflictDetectionInputV2 = FrozenConflictInput;

impl FrozenConflictInput {
    pub fn restore(
        authority: ConflictRuleVersion,
        row: ConflictInputOwnerRow,
    ) -> Result<Self, DatasetSnapshotError> {
        let input_sha256 = Sha256Digest::parse(row.input_sha256.as_str())?;
        let payload = serde_json::from_slice::<Value>(&row.payload_json)
            .map_err(|_| DatasetSnapshotError::InvalidConflictInput)?;
        if Sha256Digest::calculate(&row.canonical) != input_sha256
            || serde_json::from_slice::<Value>(&row.canonical)
                .ok()
                .as_ref()
                != Some(&payload)
            || canonical_json_bytes(&payload)? != row.canonical
        {
            return Err(DatasetSnapshotError::InvalidCanonicalJson);
        }
        let object = exact_object(
            &payload,
            &INPUT_KEYS,
            DatasetSnapshotError::InvalidConflictInput,
        )?;
        validate_input_header(object, &authority, &row)?;
        validate_coverage(object.get("coverage"))?;
        for key in [
            "contracts",
            "procurement_notices",
            "procurement_awards",
            "bidder_participations",
            "suppliers",
            "sanctions",
        ] {
            if !object.get(key).is_some_and(Value::is_array) {
                return Err(DatasetSnapshotError::InvalidConflictInput);
            }
        }
        let relationship_payloads = array(object, "typed_relationship_assertions")?.to_vec();
        relationship_payloads
            .iter()
            .try_for_each(|value| parse_relationship(value).map(|_| ()))?;
        array(object, "strong_identifier_facts")?;
        Ok(Self {
            authority,
            coverage_status: ConflictCoverageStatus::parse(&row.coverage_status)?,
            canonical: row.canonical,
            input_sha256,
            relationship_payloads,
        })
    }
    pub fn authority(&self) -> &ConflictRuleVersion {
        &self.authority
    }
    pub const fn coverage_status(&self) -> ConflictCoverageStatus {
        self.coverage_status
    }
    pub fn canonical(&self) -> &[u8] {
        &self.canonical
    }
    pub fn input_sha256(&self) -> &Sha256Digest {
        &self.input_sha256
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct FrozenRelationship {
    assertion_id: Uuid,
    assertion_revision: i64,
    assertion_digest: Sha256Digest,
}

#[derive(Clone, Debug, PartialEq)]
pub struct RelationshipAssertionBinding {
    ordinal: i64,
    assertion: FrozenRelationship,
    canonical: Vec<u8>,
    binding_digest: Sha256Digest,
}

impl RelationshipAssertionBinding {
    fn restore(
        header: &DatasetSnapshotHeader,
        row: FrozenRelationshipOwnerRow,
    ) -> Result<Self, DatasetSnapshotError> {
        if row.assertion_ordinal < 0 {
            return Err(DatasetSnapshotError::RelationshipBindingMismatch);
        }
        let assertion_payload = serde_json::from_slice(&row.assertion_payload_json)
            .map_err(|_| DatasetSnapshotError::InvalidRelationshipAssertion)?;
        let assertion = parse_relationship(&assertion_payload)?;
        let canonical = canonical_json_bytes(&json!({
            "schemaVersion": "dataset-snapshot-relationship-binding.v2",
            "snapshotId": header.snapshot_id, "snapshotSha256": header.snapshot_sha256.as_str(),
            "snapshotGeneration": header.producer_generation, "assertionOrdinal": row.assertion_ordinal,
            "assertionId": assertion.assertion_id, "assertionRevision": assertion.assertion_revision,
            "assertionDigest": assertion.assertion_digest.as_str(),
        }))?;
        Ok(Self {
            ordinal: row.assertion_ordinal,
            assertion,
            binding_digest: Sha256Digest::calculate(&canonical),
            canonical,
        })
    }
    pub const fn ordinal(&self) -> i64 {
        self.ordinal
    }
    pub const fn assertion_id(&self) -> Uuid {
        self.assertion.assertion_id
    }
    pub const fn assertion_revision(&self) -> i64 {
        self.assertion.assertion_revision
    }
    pub fn assertion_digest(&self) -> &Sha256Digest {
        &self.assertion.assertion_digest
    }
    pub fn canonical(&self) -> &[u8] {
        &self.canonical
    }
    pub fn binding_digest(&self) -> &Sha256Digest {
        &self.binding_digest
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct DatasetSnapshot {
    header: DatasetSnapshotHeader,
    conflict_input: FrozenConflictInput,
    conflict_input_set_sha256: Sha256Digest,
    relationship_assertions: Vec<RelationshipAssertionBinding>,
}

impl DatasetSnapshot {
    pub fn restore(
        header: DatasetSnapshotHeader,
        conflict_input: FrozenConflictInput,
        relationship_rows: Vec<FrozenRelationshipOwnerRow>,
    ) -> Result<Self, DatasetSnapshotError> {
        if conflict_input.relationship_payloads.len() != relationship_rows.len() {
            return Err(DatasetSnapshotError::RelationshipBindingMismatch);
        }
        let mut assertion_keys = BTreeSet::new();
        let mut binding_digests = BTreeSet::new();
        let mut bindings = Vec::with_capacity(relationship_rows.len());
        for (expected, row) in relationship_rows.into_iter().enumerate() {
            let returned_payload = serde_json::from_slice::<Value>(&row.assertion_payload_json)
                .map_err(|_| DatasetSnapshotError::InvalidRelationshipAssertion)?;
            if row.assertion_ordinal != expected as i64
                || conflict_input.relationship_payloads[expected] != returned_payload
            {
                return Err(DatasetSnapshotError::RelationshipBindingMismatch);
            }
            let binding = RelationshipAssertionBinding::restore(&header, row)?;
            let assertion_key = (binding.assertion_id(), binding.assertion_revision());
            if !assertion_keys.insert(assertion_key)
                || !binding_digests.insert(binding.binding_digest.clone())
            {
                return Err(DatasetSnapshotError::DuplicateSnapshotChild);
            }
            bindings.push(binding);
        }
        let set = canonical_json_bytes(&json!([conflict_input.input_sha256.as_str()]))?;
        Ok(Self {
            header,
            conflict_input,
            conflict_input_set_sha256: Sha256Digest::calculate(&set),
            relationship_assertions: bindings,
        })
    }
    pub fn header(&self) -> &DatasetSnapshotHeader {
        &self.header
    }
    pub fn conflict_input(&self) -> &FrozenConflictInput {
        &self.conflict_input
    }
    pub fn conflict_input_set_sha256(&self) -> &Sha256Digest {
        &self.conflict_input_set_sha256
    }
    pub fn relationship_assertions(&self) -> &[RelationshipAssertionBinding] {
        &self.relationship_assertions
    }
}

fn validate_input_header(
    object: &Map<String, Value>,
    authority: &ConflictRuleVersion,
    row: &ConflictInputOwnerRow,
) -> Result<(), DatasetSnapshotError> {
    if text(object, "schema_version")? != INPUT_SCHEMA
        || text(object, "rule_id")? != authority.rule_id.as_str()
        || row.rule_id != authority.rule_id.as_str()
        || parse_uuid(text(object, "rule_version_id")?)? != authority.version_id
        || row.rule_version_id != authority.version_id
        || text(object, "rule_version_digest")? != authority.version_digest.as_str()
        || text(object, "coverage_status")? != row.coverage_status
    {
        return Err(DatasetSnapshotError::InvalidConflictInput);
    }
    Ok(())
}

fn validate_coverage(value: Option<&Value>) -> Result<(), DatasetSnapshotError> {
    let coverage = value
        .ok_or(DatasetSnapshotError::InvalidConflictInput)
        .and_then(|value| {
            exact_object(
                value,
                &COVERAGE_KEYS,
                DatasetSnapshotError::InvalidConflictInput,
            )
        })?;
    if COVERAGE_KEYS[..6]
        .iter()
        .any(|key| !coverage.get(*key).is_some_and(Value::is_boolean))
        || text(coverage, "bidder_participation_authority")? != BIDDER_AUTHORITY
    {
        return Err(DatasetSnapshotError::InvalidConflictInput);
    }
    Ok(())
}

fn parse_relationship(value: &Value) -> Result<FrozenRelationship, DatasetSnapshotError> {
    let item = value
        .as_object()
        .ok_or(DatasetSnapshotError::InvalidRelationshipAssertion)?;
    let assertion_id = parse_uuid(text(item, "relationship_id")?)?;
    let assertion_revision = integer(item, "assertion_revision")?;
    if assertion_id.is_nil() || assertion_revision < 2 {
        return Err(DatasetSnapshotError::InvalidRelationshipAssertion);
    }
    Ok(FrozenRelationship {
        assertion_id,
        assertion_revision,
        assertion_digest: Sha256Digest::parse(text(item, "assertion_digest")?)?,
    })
}

fn canonical_json_bytes(value: &Value) -> Result<Vec<u8>, DatasetSnapshotError> {
    fn validate(value: &Value) -> Result<(), DatasetSnapshotError> {
        match value {
            Value::Null | Value::Bool(_) | Value::String(_) => Ok(()),
            Value::Number(value) if value.is_i64() || value.is_u64() => Ok(()),
            Value::Number(_) => Err(DatasetSnapshotError::InvalidCanonicalJson),
            Value::Array(values) => values.iter().try_for_each(validate),
            Value::Object(values) => {
                if values.keys().any(|key| !key.is_ascii()) {
                    return Err(DatasetSnapshotError::InvalidCanonicalJson);
                }
                values.values().try_for_each(validate)
            }
        }
    }
    validate(value)?;
    serde_json::to_vec(value).map_err(|_| DatasetSnapshotError::InvalidCanonicalJson)
}

fn exact_object<'a>(
    value: &'a Value,
    keys: &[&str],
    error: DatasetSnapshotError,
) -> Result<&'a Map<String, Value>, DatasetSnapshotError> {
    let object = value.as_object().ok_or_else(|| error.clone())?;
    if object.len() != keys.len() || keys.iter().any(|key| !object.contains_key(*key)) {
        return Err(error);
    }
    Ok(object)
}

fn text<'a>(object: &'a Map<String, Value>, key: &str) -> Result<&'a str, DatasetSnapshotError> {
    object
        .get(key)
        .and_then(Value::as_str)
        .ok_or(DatasetSnapshotError::InvalidConflictInput)
}

fn integer(object: &Map<String, Value>, key: &str) -> Result<i64, DatasetSnapshotError> {
    object
        .get(key)
        .and_then(Value::as_i64)
        .ok_or(DatasetSnapshotError::InvalidRelationshipAssertion)
}

fn array<'a>(
    object: &'a Map<String, Value>,
    key: &str,
) -> Result<&'a [Value], DatasetSnapshotError> {
    object
        .get(key)
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .ok_or(DatasetSnapshotError::InvalidConflictInput)
}

fn parse_uuid(value: &str) -> Result<Uuid, DatasetSnapshotError> {
    Uuid::parse_str(value).map_err(|_| DatasetSnapshotError::InvalidConflictInput)
}

fn is_digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    const SHA: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    #[test]
    fn canonical_digest_and_owner_cardinality_fail_closed() {
        assert_eq!(
            canonical_json_bytes(&json!(1.5)),
            Err(DatasetSnapshotError::InvalidCanonicalJson)
        );
        assert_eq!(
            DatasetSnapshotBuildReceipt::from_owner_result(
                Uuid::from_u128(1),
                SHA,
                1,
                1,
                "b".repeat(64),
                false
            ),
            Err(DatasetSnapshotError::InvalidBuildResult)
        );
    }
}
