#![forbid(unsafe_code)]

use std::{future::Future, pin::Pin};

use gurine_detection::snapshot::{
    ConflictRuleVersion, DatasetSnapshot, DatasetSnapshotBuildReceipt, DatasetSnapshotHeader,
    Sha256Digest,
};
use thiserror::Error;
use uuid::Uuid;

pub type DatasetSnapshotFuture<'a, T, E> = Pin<Box<dyn Future<Output = Result<T, E>> + Send + 'a>>;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BuildConflictDatasetSnapshot {
    job_id: Uuid,
    lease_token: Uuid,
    fencing_token: i64,
}

impl BuildConflictDatasetSnapshot {
    pub fn new(
        job_id: Uuid,
        lease_token: Uuid,
        fencing_token: i64,
    ) -> Result<Self, DatasetSnapshotRequestError> {
        if job_id.is_nil() || lease_token.is_nil() || fencing_token < 1 {
            return Err(DatasetSnapshotRequestError::InvalidBuildFence);
        }
        Ok(Self {
            job_id,
            lease_token,
            fencing_token,
        })
    }

    pub const fn job_id(&self) -> Uuid {
        self.job_id
    }

    pub const fn lease_token(&self) -> Uuid {
        self.lease_token
    }

    pub const fn fencing_token(&self) -> i64 {
        self.fencing_token
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BuildGeneralDatasetSnapshot {
    job_id: Uuid,
    lease_token: Uuid,
    fencing_token: i64,
}

impl BuildGeneralDatasetSnapshot {
    pub fn new(
        job_id: Uuid,
        lease_token: Uuid,
        fencing_token: i64,
    ) -> Result<Self, DatasetSnapshotRequestError> {
        if job_id.is_nil() || lease_token.is_nil() || fencing_token < 1 {
            return Err(DatasetSnapshotRequestError::InvalidBuildFence);
        }
        Ok(Self {
            job_id,
            lease_token,
            fencing_token,
        })
    }

    pub const fn job_id(&self) -> Uuid {
        self.job_id
    }

    pub const fn lease_token(&self) -> Uuid {
        self.lease_token
    }

    pub const fn fencing_token(&self) -> i64 {
        self.fencing_token
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GeneralDatasetSnapshotBuildReceipt {
    snapshot_id: Uuid,
    snapshot_sha256: Sha256Digest,
    member_count: i64,
    strong_identifier_fact_count: i64,
    strong_identifier_fact_set_sha256: Sha256Digest,
    replayed: bool,
}

impl GeneralDatasetSnapshotBuildReceipt {
    pub fn from_owner_result(
        snapshot_id: Uuid,
        snapshot_sha256: impl Into<String>,
        member_count: i64,
        strong_identifier_fact_count: i64,
        strong_identifier_fact_set_sha256: impl Into<String>,
        replayed: bool,
    ) -> Result<Self, DatasetSnapshotRequestError> {
        if snapshot_id.is_nil() || member_count < 0 || strong_identifier_fact_count < 0 {
            return Err(DatasetSnapshotRequestError::InvalidGeneralBuildResult);
        }
        let snapshot_sha256 = Sha256Digest::parse(snapshot_sha256)
            .map_err(|_| DatasetSnapshotRequestError::InvalidGeneralBuildResult)?;
        let strong_identifier_fact_set_sha256 =
            Sha256Digest::parse(strong_identifier_fact_set_sha256)
                .map_err(|_| DatasetSnapshotRequestError::InvalidGeneralBuildResult)?;
        Ok(Self {
            snapshot_id,
            snapshot_sha256,
            member_count,
            strong_identifier_fact_count,
            strong_identifier_fact_set_sha256,
            replayed,
        })
    }

    pub const fn snapshot_id(&self) -> Uuid {
        self.snapshot_id
    }

    pub fn snapshot_sha256(&self) -> &Sha256Digest {
        &self.snapshot_sha256
    }

    pub const fn member_count(&self) -> i64 {
        self.member_count
    }

    pub const fn strong_identifier_fact_count(&self) -> i64 {
        self.strong_identifier_fact_count
    }

    pub fn strong_identifier_fact_set_sha256(&self) -> &Sha256Digest {
        &self.strong_identifier_fact_set_sha256
    }

    pub const fn replayed(&self) -> bool {
        self.replayed
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LoadConflictDatasetSnapshot {
    header: DatasetSnapshotHeader,
    rule_version: ConflictRuleVersion,
}

impl LoadConflictDatasetSnapshot {
    pub const fn new(header: DatasetSnapshotHeader, rule_version: ConflictRuleVersion) -> Self {
        Self {
            header,
            rule_version,
        }
    }

    pub const fn header(&self) -> &DatasetSnapshotHeader {
        &self.header
    }

    pub const fn rule_version(&self) -> &ConflictRuleVersion {
        &self.rule_version
    }
}

/// The port deliberately exposes only the snapshot owner-routine boundaries.
/// Immutable snapshot children are never application-level write methods.
pub trait DatasetSnapshotRepository {
    type Error: std::error::Error + Send + Sync + 'static;

    fn build<'a>(
        &'a mut self,
        request: &'a BuildConflictDatasetSnapshot,
    ) -> DatasetSnapshotFuture<'a, DatasetSnapshotBuildReceipt, Self::Error>;

    fn build_general<'a>(
        &'a mut self,
        request: &'a BuildGeneralDatasetSnapshot,
    ) -> DatasetSnapshotFuture<'a, GeneralDatasetSnapshotBuildReceipt, Self::Error>;

    fn load<'a>(
        &'a mut self,
        request: &'a LoadConflictDatasetSnapshot,
    ) -> DatasetSnapshotFuture<'a, DatasetSnapshot, Self::Error>;
}

pub struct DatasetSnapshotUseCase<'a, Repository: ?Sized> {
    repository: &'a mut Repository,
}

impl<'a, Repository> DatasetSnapshotUseCase<'a, Repository>
where
    Repository: DatasetSnapshotRepository + ?Sized,
{
    pub const fn new(repository: &'a mut Repository) -> Self {
        Self { repository }
    }

    pub async fn build(
        &mut self,
        request: &BuildConflictDatasetSnapshot,
    ) -> Result<DatasetSnapshotBuildReceipt, Repository::Error> {
        self.repository.build(request).await
    }

    pub async fn build_general(
        &mut self,
        request: &BuildGeneralDatasetSnapshot,
    ) -> Result<GeneralDatasetSnapshotBuildReceipt, Repository::Error> {
        self.repository.build_general(request).await
    }

    pub async fn load(
        &mut self,
        request: &LoadConflictDatasetSnapshot,
    ) -> Result<DatasetSnapshot, Repository::Error> {
        self.repository.load(request).await
    }
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum DatasetSnapshotRequestError {
    #[error("dataset snapshot build requires a non-empty leased job fence")]
    InvalidBuildFence,
    #[error("general detection dataset snapshot owner result is invalid")]
    InvalidGeneralBuildResult,
}

#[cfg(test)]
mod tests {
    use super::*;
    use gurine_detection::snapshot::{
        ConflictInputOwnerRow, ConflictRuleId, DatasetSnapshotError, FrozenConflictInput,
        FrozenRelationshipOwnerRow, Sha256Digest,
    };
    use serde_json::{Value, json};

    const SHA: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    fn relationship() -> Value {
        json!({
            "relationship_id": Uuid::from_u128(10),
            "assertion_revision": 2,
            "assertion_digest": SHA,
        })
    }

    fn payload(relationships: Vec<Value>) -> Value {
        json!({
            "schema_version": "conflict-detection-input.v2",
            "rule_id": "OFFICER_OVERLAP_AWARD",
            "rule_version_id": Uuid::from_u128(3),
            "rule_version_digest": SHA,
            "coverage_status": "COMPLETE",
            "coverage": {
                "contracts_complete": true,
                "procurement_notices_complete": true,
                "procurement_awards_complete": true,
                "bidder_participations_complete": false,
                "typed_relationships_complete": true,
                "strong_identifier_facts_complete": true,
                "bidder_participation_authority": "koneps-structured-bidder-participation",
            },
            "contracts": [], "procurement_notices": [], "procurement_awards": [],
            "bidder_participations": [], "typed_relationship_assertions": relationships,
            "strong_identifier_facts": [], "suppliers": [], "sanctions": [],
        })
    }

    fn frozen(relationships: Vec<Value>) -> FrozenConflictInput {
        let payload = payload(relationships);
        let canonical = serde_json::to_vec(&payload).unwrap_or_else(|error| panic!("{error}"));
        let authority = ConflictRuleVersion::new(
            ConflictRuleId::OfficerOverlapAward,
            Uuid::from_u128(3),
            Sha256Digest::parse(SHA).unwrap_or_else(|error| panic!("{error}")),
        )
        .unwrap_or_else(|error| panic!("{error}"));
        FrozenConflictInput::restore(
            authority,
            ConflictInputOwnerRow {
                rule_id: "OFFICER_OVERLAP_AWARD".to_owned(),
                rule_version_id: Uuid::from_u128(3),
                coverage_status: "COMPLETE".to_owned(),
                input_sha256: Sha256Digest::calculate(&canonical).as_str().to_owned(),
                payload_json: serde_json::to_vec(&payload)
                    .unwrap_or_else(|error| panic!("{error}")),
                canonical,
            },
        )
        .unwrap_or_else(|error| panic!("{error}"))
    }

    #[test]
    fn build_request_requires_the_complete_positive_fence() {
        assert_eq!(
            BuildConflictDatasetSnapshot::new(Uuid::nil(), Uuid::from_u128(2), 1),
            Err(DatasetSnapshotRequestError::InvalidBuildFence)
        );
        assert_eq!(
            BuildConflictDatasetSnapshot::new(Uuid::from_u128(1), Uuid::from_u128(2), 0),
            Err(DatasetSnapshotRequestError::InvalidBuildFence)
        );
        assert_eq!(
            BuildGeneralDatasetSnapshot::new(Uuid::nil(), Uuid::from_u128(2), 1),
            Err(DatasetSnapshotRequestError::InvalidBuildFence)
        );
    }

    #[test]
    fn general_build_receipt_rejects_untyped_owner_output() {
        let valid = GeneralDatasetSnapshotBuildReceipt::from_owner_result(
            Uuid::from_u128(1),
            SHA,
            2,
            1,
            "b".repeat(64),
            false,
        )
        .unwrap_or_else(|error| panic!("{error}"));
        assert_eq!(valid.member_count(), 2);
        assert_eq!(valid.strong_identifier_fact_count(), 1);
        assert_eq!(valid.snapshot_sha256().as_str(), SHA);
        assert_eq!(
            valid.strong_identifier_fact_set_sha256().as_str(),
            "b".repeat(64)
        );
        assert!(!valid.replayed());
        assert_eq!(
            GeneralDatasetSnapshotBuildReceipt::from_owner_result(
                Uuid::from_u128(1),
                SHA,
                -1,
                0,
                SHA,
                false,
            ),
            Err(DatasetSnapshotRequestError::InvalidGeneralBuildResult)
        );
    }

    #[test]
    fn snapshot_rejects_duplicate_assertion_revisions_and_ordinal_gaps() {
        let header = DatasetSnapshotHeader::ready(
            Uuid::from_u128(4),
            2,
            Sha256Digest::parse("b".repeat(64)).unwrap_or_else(|error| panic!("{error}")),
        )
        .unwrap_or_else(|error| panic!("{error}"));
        let duplicate = DatasetSnapshot::restore(
            header.clone(),
            frozen(vec![relationship(), relationship()]),
            vec![
                FrozenRelationshipOwnerRow {
                    assertion_ordinal: 0,
                    assertion_payload_json: serde_json::to_vec(&relationship())
                        .unwrap_or_else(|error| panic!("{error}")),
                },
                FrozenRelationshipOwnerRow {
                    assertion_ordinal: 1,
                    assertion_payload_json: serde_json::to_vec(&relationship())
                        .unwrap_or_else(|error| panic!("{error}")),
                },
            ],
        );
        assert_eq!(duplicate, Err(DatasetSnapshotError::DuplicateSnapshotChild));
        let gap = DatasetSnapshot::restore(
            header,
            frozen(vec![relationship()]),
            vec![FrozenRelationshipOwnerRow {
                assertion_ordinal: 1,
                assertion_payload_json: serde_json::to_vec(&relationship())
                    .unwrap_or_else(|error| panic!("{error}")),
            }],
        );
        assert_eq!(gap, Err(DatasetSnapshotError::RelationshipBindingMismatch));
    }

    #[test]
    fn closed_conflict_input_rejects_an_extra_policy_section() {
        let mut payload = payload(Vec::new());
        payload["policy"] = json!({});
        let canonical = serde_json::to_vec(&payload).unwrap_or_else(|error| panic!("{error}"));
        let authority = ConflictRuleVersion::new(
            ConflictRuleId::OfficerOverlapAward,
            Uuid::from_u128(3),
            Sha256Digest::parse(SHA).unwrap_or_else(|error| panic!("{error}")),
        )
        .unwrap_or_else(|error| panic!("{error}"));
        let result = FrozenConflictInput::restore(
            authority,
            ConflictInputOwnerRow {
                rule_id: "OFFICER_OVERLAP_AWARD".to_owned(),
                rule_version_id: Uuid::from_u128(3),
                coverage_status: "COMPLETE".to_owned(),
                input_sha256: Sha256Digest::calculate(&canonical).as_str().to_owned(),
                payload_json: serde_json::to_vec(&payload)
                    .unwrap_or_else(|error| panic!("{error}")),
                canonical,
            },
        );
        assert_eq!(result, Err(DatasetSnapshotError::InvalidConflictInput));
    }
}
