use serde::{Deserialize, Serialize};
use time::Date;

use crate::{
    error::{DomainError, validated_text},
    ids::{AgencyId, ContractId, SourceDocumentId, SupplierId},
    money::Money,
};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Contract {
    pub id: ContractId,
    pub source_document_id: SourceDocumentId,
    pub external_id: String,
    pub agency_id: AgencyId,
    pub supplier_id: SupplierId,
    pub title: String,
    pub amount: Money,
    pub signed_on: Date,
    pub cancelled: bool,
}

pub struct NewContract {
    pub id: ContractId,
    pub source_document_id: SourceDocumentId,
    pub external_id: String,
    pub agency_id: AgencyId,
    pub supplier_id: SupplierId,
    pub title: String,
    pub amount: Money,
    pub signed_on: Date,
}

impl Contract {
    pub fn create(command: NewContract) -> Result<Self, DomainError> {
        Ok(Self {
            id: command.id,
            source_document_id: command.source_document_id,
            external_id: validated_text(command.external_id, 300)?,
            agency_id: command.agency_id,
            supplier_id: command.supplier_id,
            title: validated_text(command.title, 1_000)?,
            amount: command.amount,
            signed_on: command.signed_on,
            cancelled: false,
        })
    }
}
