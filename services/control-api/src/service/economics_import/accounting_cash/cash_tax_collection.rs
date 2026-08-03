use super::*;

macro_rules! closed_enum {
    ($name:ident { $($variant:ident),+ $(,)? }) => {
        #[derive(
            Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize,
        )]
        #[serde(rename_all = "SCREAMING_SNAKE_CASE")]
        enum $name { $($variant),+ }
    };
}

closed_enum!(CashApplicationEffect { Original, Reversal });
closed_enum!(CashApplicationSourceKind {
    BankTransfer,
    PgSettlement
});
closed_enum!(TaxInvoiceReceiptEffect {
    Original,
    Replacement
});
closed_enum!(TaxInvoiceIssuanceState {
    PendingAsp,
    IssuedConfirmed,
    CancelledConfirmed,
});
closed_enum!(CollectionFailureAuthorityKind {
    ProviderFetchConfirmed,
    BankReturnConfirmed,
});

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in super::super) struct EconomicsCashApplicationImportV1 {
    root_fact_id: Uuid,
    revision: i64,
    fact_effect: CashApplicationEffect,
    supersedes_fact_id: RequiredNullable<Uuid>,
    predecessor_fact_digest: RequiredNullable<Sha256Digest>,
    invoice_fact_id: Uuid,
    invoice_fact_digest: Sha256Digest,
    invoice_reconciliation_digest: Sha256Digest,
    source_kind: CashApplicationSourceKind,
    source_system_id: String,
    source_settlement_identity_hmac: Sha256Digest,
    source_settlement_hmac_key_version: String,
    source_settlement_amount: Decimal,
    applied_amount: Decimal,
    currency: String,
    source_record_digest: Sha256Digest,
    source_signature_digest: Sha256Digest,
    import_receipt_digest: Sha256Digest,
    applied_at: DateTimeText,
    expected_invoice_revision: i64,
    expected_head_id: RequiredNullable<Uuid>,
    expected_head_revision: RequiredNullable<i64>,
    expected_head_digest: RequiredNullable<Sha256Digest>,
}

impl EconomicsCashApplicationImportV1 {
    fn validate(&self) -> Result<(), ServiceError> {
        let valid_fence = valid_chain_fence(
            self.revision,
            *self.supersedes_fact_id.as_option(),
            self.predecessor_fact_digest.as_option().as_ref(),
            *self.expected_head_id.as_option(),
            *self.expected_head_revision.as_option(),
            self.expected_head_digest.as_option().as_ref(),
        );
        let valid_chain = match self.fact_effect {
            CashApplicationEffect::Original => self.revision == 1 && valid_fence,
            CashApplicationEffect::Reversal => self.revision > 1 && valid_fence,
        };
        if any_nil(&[self.root_fact_id, self.invoice_fact_id])
            || self
                .supersedes_fact_id
                .as_option()
                .is_some_and(|id| id.is_nil())
            || self.expected_invoice_revision < 1
            || !valid_chain
            || !valid_trimmed(&self.source_system_id, 128)
            || !valid_trimmed(&self.source_settlement_hmac_key_version, 100)
            || self.source_settlement_amount <= Decimal::ZERO
            || self.applied_amount <= Decimal::ZERO
            || self.applied_amount > self.source_settlement_amount
            || !valid_currency(&self.currency)
        {
            return Err(ServiceError::InvalidRequest);
        }
        let _signed_invoice_bound_source = (
            self.source_kind,
            &self.invoice_fact_digest,
            &self.invoice_reconciliation_digest,
            &self.source_record_digest,
            &self.source_signature_digest,
            &self.import_receipt_digest,
            &self.applied_at,
        );
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in super::super) struct EconomicsCashApplicationsImportV1 {
    rows: Vec<EconomicsCashApplicationImportV1>,
}

impl EconomicsCashApplicationsImportV1 {
    pub(in super::super) fn validate(&self) -> Result<(), ServiceError> {
        if self.rows.is_empty() {
            return Err(ServiceError::InvalidRequest);
        }
        let mut roots = BTreeSet::new();
        let mut sources = BTreeSet::new();
        let mut successors = BTreeSet::new();
        for row in &self.rows {
            row.validate()?;
            if !roots.insert((row.root_fact_id, row.revision))
                || !sources.insert((
                    row.source_system_id.as_str(),
                    row.source_settlement_identity_hmac.as_str(),
                    row.revision,
                ))
                || row
                    .supersedes_fact_id
                    .as_option()
                    .is_some_and(|id| !successors.insert(id))
            {
                return Err(ServiceError::InvalidRequest);
            }
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in super::super) struct EconomicsTaxInvoiceImportV1 {
    root_receipt_id: Uuid,
    revision: i64,
    receipt_effect: TaxInvoiceReceiptEffect,
    supersedes_receipt_id: RequiredNullable<Uuid>,
    predecessor_receipt_digest: RequiredNullable<Sha256Digest>,
    invoice_fact_id: Uuid,
    invoice_fact_digest: Sha256Digest,
    invoice_reconciliation_digest: Sha256Digest,
    taxable_amount: Decimal,
    tax_amount: Decimal,
    currency: String,
    issuance_state: TaxInvoiceIssuanceState,
    approval_number_hmac: RequiredNullable<Sha256Digest>,
    approval_number_hmac_key_version: RequiredNullable<String>,
    asp_receipt_reference_hmac: RequiredNullable<Sha256Digest>,
    asp_receipt_reference_hmac_key_version: RequiredNullable<String>,
    asp_receipt_digest: RequiredNullable<Sha256Digest>,
    source_system_id: String,
    source_record_digest: Sha256Digest,
    source_signature_digest: Sha256Digest,
    import_receipt_digest: Sha256Digest,
    issued_at: RequiredNullable<DateTimeText>,
    cancelled_at: RequiredNullable<DateTimeText>,
    expected_invoice_revision: i64,
    expected_head_id: RequiredNullable<Uuid>,
    expected_head_revision: RequiredNullable<i64>,
    expected_head_digest: RequiredNullable<Sha256Digest>,
}

impl EconomicsTaxInvoiceImportV1 {
    fn validate(&self) -> Result<(), ServiceError> {
        let valid_fence = valid_chain_fence(
            self.revision,
            *self.supersedes_receipt_id.as_option(),
            self.predecessor_receipt_digest.as_option().as_ref(),
            *self.expected_head_id.as_option(),
            *self.expected_head_revision.as_option(),
            self.expected_head_digest.as_option().as_ref(),
        );
        let valid_chain = match self.receipt_effect {
            TaxInvoiceReceiptEffect::Original => self.revision == 1 && valid_fence,
            TaxInvoiceReceiptEffect::Replacement => self.revision > 1 && valid_fence,
        };
        if any_nil(&[self.root_receipt_id, self.invoice_fact_id])
            || self
                .supersedes_receipt_id
                .as_option()
                .is_some_and(|id| id.is_nil())
            || self.expected_invoice_revision < 1
            || !valid_chain
            || !self.valid_issuance_state()
            || self.taxable_amount < Decimal::ZERO
            || self.tax_amount < Decimal::ZERO
            || !valid_currency(&self.currency)
            || !valid_trimmed(&self.source_system_id, 128)
        {
            return Err(ServiceError::InvalidRequest);
        }
        let _signed_invoice_binding = (
            &self.invoice_fact_digest,
            &self.invoice_reconciliation_digest,
            &self.source_record_digest,
            &self.source_signature_digest,
            &self.import_receipt_digest,
        );
        Ok(())
    }

    fn valid_issuance_state(&self) -> bool {
        let external_receipt_complete = self.approval_number_hmac.as_option().is_some()
            && self
                .approval_number_hmac_key_version
                .as_option()
                .as_deref()
                .is_some_and(valid_external_reference_version)
            && self.asp_receipt_reference_hmac.as_option().is_some()
            && self
                .asp_receipt_reference_hmac_key_version
                .as_option()
                .as_deref()
                .is_some_and(valid_external_reference_version)
            && self.asp_receipt_digest.as_option().is_some();
        let external_receipt_absent = self.approval_number_hmac.as_option().is_none()
            && self.approval_number_hmac_key_version.as_option().is_none()
            && self.asp_receipt_reference_hmac.as_option().is_none()
            && self
                .asp_receipt_reference_hmac_key_version
                .as_option()
                .is_none()
            && self.asp_receipt_digest.as_option().is_none();
        match self.issuance_state {
            TaxInvoiceIssuanceState::PendingAsp => {
                external_receipt_absent
                    && self.issued_at.as_option().is_none()
                    && self.cancelled_at.as_option().is_none()
            }
            TaxInvoiceIssuanceState::IssuedConfirmed => {
                external_receipt_complete
                    && self.issued_at.as_option().is_some()
                    && self.cancelled_at.as_option().is_none()
            }
            TaxInvoiceIssuanceState::CancelledConfirmed => {
                external_receipt_complete
                    && matches!(
                        (self.issued_at.as_option(), self.cancelled_at.as_option()),
                        (Some(issued), Some(cancelled))
                            if datetime(cancelled) >= datetime(issued)
                    )
            }
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in super::super) struct EconomicsTaxInvoicesImportV1 {
    rows: Vec<EconomicsTaxInvoiceImportV1>,
}

impl EconomicsTaxInvoicesImportV1 {
    pub(in super::super) fn validate(&self) -> Result<(), ServiceError> {
        if self.rows.is_empty() {
            return Err(ServiceError::InvalidRequest);
        }
        let mut roots = BTreeSet::new();
        let mut successors = BTreeSet::new();
        for row in &self.rows {
            row.validate()?;
            if !roots.insert((row.root_receipt_id, row.revision))
                || row
                    .supersedes_receipt_id
                    .as_option()
                    .is_some_and(|id| !successors.insert(id))
            {
                return Err(ServiceError::InvalidRequest);
            }
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in super::super) struct EconomicsCollectionFailureImportV1 {
    authority_kind: CollectionFailureAuthorityKind,
    provider_charge_attempt_id: RequiredNullable<Uuid>,
    provider_charge_attempt_digest: RequiredNullable<Sha256Digest>,
    provider_fetch_digest: RequiredNullable<Sha256Digest>,
    invoice_fact_id: RequiredNullable<Uuid>,
    invoice_fact_digest: RequiredNullable<Sha256Digest>,
    invoice_reconciliation_digest: RequiredNullable<Sha256Digest>,
    expected_invoice_revision: RequiredNullable<i64>,
    signed_evidence_segment_id: RequiredNullable<Uuid>,
    signed_evidence_segment_digest: RequiredNullable<Sha256Digest>,
    task_assignee_id: Uuid,
    task_due_at: DateTimeText,
    reason_code: String,
    reason_digest: Sha256Digest,
}

impl EconomicsCollectionFailureImportV1 {
    pub(in super::super) fn validate(&self) -> Result<(), ServiceError> {
        if self.task_assignee_id.is_nil()
            || self.reason_code.is_empty()
            || self.reason_code.trim() != self.reason_code
        {
            return Err(ServiceError::InvalidRequest);
        }
        let valid_authority = match self.authority_kind {
            CollectionFailureAuthorityKind::ProviderFetchConfirmed => {
                self.provider_charge_attempt_id
                    .as_option()
                    .is_some_and(|id| !id.is_nil())
                    && self.provider_charge_attempt_digest.as_option().is_some()
                    && self.provider_fetch_digest.as_option().is_some()
                    && self.invoice_fact_id.as_option().is_none()
                    && self.invoice_fact_digest.as_option().is_none()
                    && self.invoice_reconciliation_digest.as_option().is_none()
                    && self.expected_invoice_revision.as_option().is_none()
                    && self.signed_evidence_segment_id.as_option().is_none()
                    && self.signed_evidence_segment_digest.as_option().is_none()
            }
            CollectionFailureAuthorityKind::BankReturnConfirmed => {
                self.provider_charge_attempt_id.as_option().is_none()
                    && self.provider_charge_attempt_digest.as_option().is_none()
                    && self.provider_fetch_digest.as_option().is_none()
                    && self
                        .invoice_fact_id
                        .as_option()
                        .is_some_and(|id| !id.is_nil())
                    && self.invoice_fact_digest.as_option().is_some()
                    && self.invoice_reconciliation_digest.as_option().is_some()
                    && self
                        .expected_invoice_revision
                        .as_option()
                        .is_some_and(|revision| revision > 0)
                    && self
                        .signed_evidence_segment_id
                        .as_option()
                        .is_some_and(|id| !id.is_nil())
                    && self.signed_evidence_segment_digest.as_option().is_some()
            }
        };
        if !valid_authority {
            return Err(ServiceError::InvalidRequest);
        }
        let _task_and_reason_binding = (
            &self.task_due_at,
            &self.reason_digest,
            self.task_assignee_id,
        );
        Ok(())
    }
}

fn any_nil(values: &[Uuid]) -> bool {
    values.iter().any(Uuid::is_nil)
}

fn valid_currency(value: &str) -> bool {
    value.len() == 3 && value.bytes().all(|byte| byte.is_ascii_uppercase())
}

fn valid_trimmed(value: &str, max: usize) -> bool {
    value.trim_matches(' ') == value && (1..=max).contains(&value.chars().count())
}

fn valid_external_reference_version(value: &str) -> bool {
    value.trim() == value && !value.is_empty()
}

fn valid_chain_fence(
    revision: i64,
    previous_id: Option<Uuid>,
    predecessor_digest: Option<&Sha256Digest>,
    expected_head_id: Option<Uuid>,
    expected_head_revision: Option<i64>,
    expected_head_digest: Option<&Sha256Digest>,
) -> bool {
    if revision == 1 {
        return previous_id.is_none()
            && predecessor_digest.is_none()
            && expected_head_id.is_none()
            && expected_head_revision.is_none()
            && expected_head_digest.is_none();
    }
    previous_id.is_some_and(|id| !id.is_nil())
        && expected_head_id == previous_id
        && expected_head_revision == Some(revision - 1)
        && expected_head_digest.map(Sha256Digest::as_str)
            == predecessor_digest.map(Sha256Digest::as_str)
        && predecessor_digest.is_some()
}

fn datetime(value: &DateTimeText) -> Option<OffsetDateTime> {
    OffsetDateTime::parse(value.as_str(), &Rfc3339).ok()
}
