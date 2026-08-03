use super::*;

impl EconomicsRevenueRowImportV1 {
    fn validate(&self, expected_invoice_id: Uuid) -> Result<(), ServiceError> {
        if any_nil(&[
            self.deployment_id,
            self.organization_id,
            self.contract_period_id,
            self.contract_id,
            self.invoice_id,
            self.invoice_line_id,
        ]) || self.invoice_id != expected_invoice_id
            || self.recognition_period_end <= self.recognition_period_start
            || self.amount <= Decimal::ZERO
            || !valid_currency(&self.currency)
            || !valid_trimmed_bytes(&self.accounting_timezone, 255)
            || !valid_policy_version(&self.recognition_policy_version)
        {
            return Err(ServiceError::InvalidRequest);
        }
        let _signed_source = (
            self.sku,
            &self.invoice_line_digest,
            &self.accounting_policy_digest,
            &self.signature_digest,
            &self.recognized_at,
        );
        Ok(())
    }
}

impl EconomicsRevenueImportV1 {
    pub(in super::super::super) fn validate(&self) -> Result<(), ServiceError> {
        if self.expected_invoice_id.is_nil()
            || self.expected_invoice_revision < 1
            || self.rows.is_empty()
        {
            return Err(ServiceError::InvalidRequest);
        }
        let mut source_rows = BTreeSet::new();
        let mut import_receipts = BTreeSet::new();
        for row in &self.rows {
            row.validate(self.expected_invoice_id)?;
            if !source_rows.insert((
                row.source_receipt_digest.as_str(),
                row.source_record_digest.as_str(),
            )) || !import_receipts.insert(row.import_receipt_digest.as_str())
            {
                return Err(ServiceError::InvalidRequest);
            }
        }
        let _invoice_fence = (
            &self.expected_invoice_record_digest,
            &self.expected_invoice_reconciliation_digest,
        );
        Ok(())
    }
}

impl EconomicsAccountingCorrectionImportV1 {
    fn validate(&self) -> Result<(), ServiceError> {
        if any_nil(&[
            self.deployment_id,
            self.root_correction_id,
            self.target_fact_id,
        ]) || self
            .organization_id
            .as_option()
            .is_some_and(|id| id.is_nil())
            || self.revision < 1
            || self.correction_sequence < 1
            || self.period_end <= self.period_start
            || !valid_trimmed(&self.accounting_timezone, 63)
            || !valid_trimmed(&self.source_system_id, 100)
            || !valid_currency(&self.currency)
            || self.effective_delta == Decimal::ZERO
            || self.expected_resulting_effective_amount < Decimal::ZERO
            || !self.valid_scope()
            || !self.valid_target()
            || !self.valid_chain()
        {
            return Err(ServiceError::InvalidRequest);
        }
        let _immutable_evidence = (
            &self.accounting_policy_digest,
            &self.target_fact_digest,
            &self.expected_resulting_correction_set_digest,
            self.reason_code,
            &self.source_receipt_digest,
            &self.signature_digest,
        );
        Ok(())
    }

    fn valid_scope(&self) -> bool {
        matches!(
            (self.scope_kind, self.organization_id.as_option()),
            (AccountingScopeKind::Deployment, None) | (AccountingScopeKind::Organization, Some(_))
        )
    }

    fn valid_target(&self) -> bool {
        let selected = match self.target_fact_kind {
            AccountingFactKind::CostEvent => self.target_cost_event_id.as_option().as_ref(),
            AccountingFactKind::CostAllocation => {
                self.target_cost_allocation_id.as_option().as_ref()
            }
            AccountingFactKind::InvoiceFact => self.target_invoice_fact_id.as_option().as_ref(),
            AccountingFactKind::InvoiceLineFact => {
                self.target_invoice_line_fact_id.as_option().as_ref()
            }
            AccountingFactKind::RevenueFact => self.target_revenue_fact_id.as_option().as_ref(),
        };
        let target_count = [
            self.target_cost_event_id.as_option(),
            self.target_cost_allocation_id.as_option(),
            self.target_invoice_fact_id.as_option(),
            self.target_invoice_line_fact_id.as_option(),
            self.target_revenue_fact_id.as_option(),
        ]
        .into_iter()
        .flatten()
        .count();
        selected == Some(&self.target_fact_id)
            && target_count == 1
            && matches!(
                (self.target_fact_kind, self.target_amount_kind),
                (
                    AccountingFactKind::CostEvent,
                    AccountingTargetAmountKind::CostEventAmount
                ) | (
                    AccountingFactKind::CostAllocation,
                    AccountingTargetAmountKind::CostAllocationAllocatedAmount
                        | AccountingTargetAmountKind::CostAllocationUnallocatedAmount
                ) | (
                    AccountingFactKind::InvoiceFact,
                    AccountingTargetAmountKind::InvoiceTotal
                ) | (
                    AccountingFactKind::InvoiceLineFact,
                    AccountingTargetAmountKind::InvoiceLineTotal
                ) | (
                    AccountingFactKind::RevenueFact,
                    AccountingTargetAmountKind::RevenueAmount
                )
            )
    }

    fn valid_chain(&self) -> bool {
        let previous_id = match self.correction_kind {
            AccountingCorrectionKind::Adjustment => None,
            AccountingCorrectionKind::Replacement => *self.supersedes_correction_id.as_option(),
            AccountingCorrectionKind::Reversal => *self.reverses_correction_id.as_option(),
        };
        let valid_fence = valid_chain_fence(
            self.revision,
            previous_id,
            self.predecessor_correction_digest.as_option().as_ref(),
            *self.expected_head_id.as_option(),
            *self.expected_head_revision.as_option(),
            self.expected_head_digest.as_option().as_ref(),
        );
        match self.correction_kind {
            AccountingCorrectionKind::Adjustment => {
                valid_fence
                    && self.supersedes_correction_id.as_option().is_none()
                    && self.reverses_correction_id.as_option().is_none()
                    && self.amount != Decimal::ZERO
                    && self.effective_delta == self.amount
            }
            AccountingCorrectionKind::Replacement => {
                valid_fence
                    && self.revision > 1
                    && self.reverses_correction_id.as_option().is_none()
                    && self.amount != Decimal::ZERO
            }
            AccountingCorrectionKind::Reversal => {
                valid_fence
                    && self.revision > 1
                    && self.supersedes_correction_id.as_option().is_none()
                    && self.amount == Decimal::ZERO
            }
        }
    }
}

impl EconomicsAccountingCorrectionsImportV1 {
    pub(in super::super::super) fn validate(&self) -> Result<(), ServiceError> {
        if self.rows.is_empty() {
            return Err(ServiceError::InvalidRequest);
        }
        let mut roots = BTreeSet::new();
        let mut targets = BTreeSet::new();
        let mut sources = BTreeSet::new();
        let mut identities = BTreeSet::new();
        for row in &self.rows {
            row.validate()?;
            if !roots.insert((row.root_correction_id, row.revision))
                || !targets.insert((
                    row.target_fact_kind,
                    row.target_fact_id,
                    row.target_amount_kind,
                    row.correction_sequence,
                ))
                || !sources.insert((
                    row.deployment_id,
                    row.source_system_id.as_str(),
                    row.source_record_identity_digest.as_str(),
                    row.target_fact_kind,
                    row.target_fact_id,
                    row.target_amount_kind,
                ))
                || !identities.insert(row.correction_identity_digest.as_str())
            {
                return Err(ServiceError::InvalidRequest);
            }
        }
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

fn valid_trimmed_bytes(value: &str, max: usize) -> bool {
    value.trim_matches(' ') == value && (1..=max).contains(&value.len())
}

fn valid_policy_version(value: &str) -> bool {
    let mut bytes = value.bytes();
    bytes
        .next()
        .is_some_and(|byte| byte.is_ascii_alphanumeric())
        && value.len() <= 128
        && bytes.all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
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
