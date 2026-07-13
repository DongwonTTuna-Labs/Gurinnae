use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{
    error::{DomainError, validated_text},
    ids::{EvidenceId, SourceDocumentId, UserId},
    state_catalog::EvidenceVerificationStatus,
};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct EvidenceLocator {
    pub kind: String,
    pub value: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Evidence {
    pub id: EvidenceId,
    pub source_document_id: SourceDocumentId,
    pub parser_run_id: Uuid,
    pub locator: EvidenceLocator,
    pub source_revision: i64,
    pub content_sha256: String,
    pub verification_status: EvidenceVerificationStatus,
    pub verified_by: Option<UserId>,
}

impl Evidence {
    pub fn new(
        id: EvidenceId,
        source_document_id: SourceDocumentId,
        parser_run_id: Uuid,
        locator: EvidenceLocator,
        source_revision: i64,
        content_sha256: String,
    ) -> Result<Self, DomainError> {
        validated_text(locator.kind.clone(), 64)?;
        validated_text(locator.value.clone(), 2_000)?;
        if source_revision < 1 || !is_hash(&content_sha256) {
            return Err(DomainError::EvidenceNotPublishable);
        }
        Ok(Self {
            id,
            source_document_id,
            parser_run_id,
            locator,
            source_revision,
            content_sha256,
            verification_status: EvidenceVerificationStatus::Pending,
            verified_by: None,
        })
    }

    pub fn verify(&mut self, verifier: UserId) -> Result<(), DomainError> {
        if self.verification_status != EvidenceVerificationStatus::Pending
            && self.verification_status != EvidenceVerificationStatus::NeedsWork
        {
            return Err(DomainError::InvalidTransition);
        }
        self.verification_status = EvidenceVerificationStatus::Verified;
        self.verified_by = Some(verifier);
        Ok(())
    }

    pub fn is_publishable(&self) -> bool {
        self.verification_status == EvidenceVerificationStatus::Verified
            && self.source_revision > 0
            && is_hash(&self.content_sha256)
    }
}

fn is_hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
