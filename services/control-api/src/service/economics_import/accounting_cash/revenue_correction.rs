use super::*;

#[path = "revenue_correction_validation.rs"]
mod validation;

macro_rules! closed_enum {
    ($name:ident { $($variant:ident),+ $(,)? }) => {
        #[derive(
            Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize,
        )]
        #[serde(rename_all = "SCREAMING_SNAKE_CASE")]
        enum $name { $($variant),+ }
    };
}

closed_enum!(CommercialSku {
    EvidenceWorkspaceOrganizationV1
});
closed_enum!(AccountingScopeKind {
    Deployment,
    Organization
});
closed_enum!(AccountingCorrectionKind {
    Adjustment,
    Replacement,
    Reversal
});
closed_enum!(AccountingFactKind {
    CostEvent,
    CostAllocation,
    InvoiceFact,
    InvoiceLineFact,
    RevenueFact,
});
closed_enum!(AccountingTargetAmountKind {
    CostEventAmount,
    CostAllocationAllocatedAmount,
    CostAllocationUnallocatedAmount,
    InvoiceTotal,
    InvoiceLineTotal,
    RevenueAmount,
});
closed_enum!(AccountingCorrectionReason {
    LateProviderInvoice,
    FxCorrection,
    UsageCorrection,
    TaxCorrection,
    Refund,
    Credit,
    AllocationCorrection,
    ServiceCredit,
});

// PROVISIONAL_0041_ABI: re-run the composite field-set audit after FINAL READY.
// This DTO is only the closed validation boundary and authorizes no owner call.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in super::super) struct EconomicsRevenueRowImportV1 {
    deployment_id: Uuid,
    organization_id: Uuid,
    contract_period_id: Uuid,
    contract_id: Uuid,
    invoice_id: Uuid,
    invoice_line_id: Uuid,
    invoice_line_digest: Sha256Digest,
    sku: CommercialSku,
    accounting_timezone: String,
    recognition_period_start: DateText,
    recognition_period_end: DateText,
    amount: Decimal,
    currency: String,
    recognition_policy_version: String,
    accounting_policy_digest: Sha256Digest,
    source_receipt_digest: Sha256Digest,
    source_record_digest: Sha256Digest,
    signature_digest: Sha256Digest,
    import_receipt_digest: Sha256Digest,
    recognized_at: DateTimeText,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in super::super) struct EconomicsRevenueImportV1 {
    expected_invoice_id: Uuid,
    expected_invoice_revision: i64,
    expected_invoice_record_digest: Sha256Digest,
    expected_invoice_reconciliation_digest: Sha256Digest,
    rows: Vec<EconomicsRevenueRowImportV1>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in super::super) struct EconomicsAccountingCorrectionImportV1 {
    deployment_id: Uuid,
    scope_kind: AccountingScopeKind,
    organization_id: RequiredNullable<Uuid>,
    accounting_timezone: String,
    accounting_policy_digest: Sha256Digest,
    root_correction_id: Uuid,
    revision: i64,
    correction_sequence: i64,
    correction_kind: AccountingCorrectionKind,
    supersedes_correction_id: RequiredNullable<Uuid>,
    reverses_correction_id: RequiredNullable<Uuid>,
    predecessor_correction_digest: RequiredNullable<Sha256Digest>,
    source_system_id: String,
    source_record_identity_digest: Sha256Digest,
    correction_identity_digest: Sha256Digest,
    target_fact_kind: AccountingFactKind,
    target_amount_kind: AccountingTargetAmountKind,
    target_fact_id: Uuid,
    target_cost_event_id: RequiredNullable<Uuid>,
    target_cost_allocation_id: RequiredNullable<Uuid>,
    target_invoice_fact_id: RequiredNullable<Uuid>,
    target_invoice_line_fact_id: RequiredNullable<Uuid>,
    target_revenue_fact_id: RequiredNullable<Uuid>,
    target_fact_digest: Sha256Digest,
    period_start: DateText,
    period_end: DateText,
    amount: Decimal,
    effective_delta: Decimal,
    expected_resulting_effective_amount: Decimal,
    expected_resulting_correction_set_digest: Sha256Digest,
    currency: String,
    reason_code: AccountingCorrectionReason,
    source_receipt_digest: Sha256Digest,
    signature_digest: Sha256Digest,
    expected_head_id: RequiredNullable<Uuid>,
    expected_head_revision: RequiredNullable<i64>,
    expected_head_digest: RequiredNullable<Sha256Digest>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in super::super) struct EconomicsAccountingCorrectionsImportV1 {
    rows: Vec<EconomicsAccountingCorrectionImportV1>,
}
