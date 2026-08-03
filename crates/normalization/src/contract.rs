use gurine_domain::{
    contract::{Contract, NewContract},
    error::DomainError,
};

use crate::{provenance::FieldProvenance, quality::QualityReport};

pub struct NormalizedContract {
    pub contract: Contract,
    pub provenance: Vec<FieldProvenance>,
    pub quality: QualityReport,
}

impl NormalizedContract {
    pub fn build(
        command: NewContract,
        provenance: Vec<FieldProvenance>,
        quality: QualityReport,
    ) -> Result<Self, DomainError> {
        if provenance.is_empty() || provenance.iter().any(|entry| !entry.is_valid()) {
            return Err(DomainError::EvidenceNotPublishable);
        }
        Ok(Self {
            contract: Contract::create(command)?,
            provenance,
            quality,
        })
    }
}
