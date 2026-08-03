use super::*;

#[path = "invoice_bindings.rs"]
mod invoice_bindings;
#[path = "invoice_import_validation.rs"]
mod invoice_import_validation;
#[path = "invoice_validation.rs"]
mod invoice_validation;

use invoice_bindings::*;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in super::super) struct EconomicsInvoiceHeaderImportV1 {
    root_invoice_id: Uuid,
    invoice_revision: i64,
    invoice_effect: InvoiceEffect,
    supersedes_invoice_id: RequiredNullable<Uuid>,
    predecessor_reconciliation_digest: RequiredNullable<Sha256Digest>,
    deployment_id: Uuid,
    organization_id: Uuid,
    contract_period_id: Uuid,
    contract_id: Uuid,
    sku: CommercialSku,
    accounting_timezone: String,
    source_system_id: String,
    external_invoice_reference_digest: Sha256Digest,
    period_start: DateText,
    period_end: DateText,
    billing_cutoff_at: DateTimeText,
    currency: String,
    expected_line_count: i32,
    expected_line_set_digest: Sha256Digest,
    expected_usage_membership_count: i32,
    expected_usage_membership_set_digest: Sha256Digest,
    expected_usage_fact_set_digest: Sha256Digest,
    expected_usage_window_receipt_set_digest: Sha256Digest,
    expected_tariff_set_digest: Sha256Digest,
    expected_discount_leaf_set_digest: Sha256Digest,
    expected_correction_set_digest: Sha256Digest,
    expected_contract_state_interval_set_digest: Sha256Digest,
    tax_policy_digest: Sha256Digest,
    rounding_policy_digest: Sha256Digest,
    expected_subtotal: Decimal,
    expected_discount_total: Decimal,
    expected_taxable_amount: Decimal,
    expected_tax_total: Decimal,
    expected_correction_total: Decimal,
    expected_invoice_total: Decimal,
    provider_receipt_digest: Sha256Digest,
    source_record_digest: Sha256Digest,
    signature_digest: Sha256Digest,
    import_receipt_digest: Sha256Digest,
    accounting_policy_digest: Sha256Digest,
    expected_reconciliation_digest: Sha256Digest,
    reconciled_at: DateTimeText,
    expected_head_id: RequiredNullable<Uuid>,
    expected_head_revision: RequiredNullable<i64>,
    expected_head_reconciliation_digest: RequiredNullable<Sha256Digest>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in super::super) struct EconomicsInvoiceLineImportV1 {
    line_ordinal: i32,
    line_kind: InvoiceLineKind,
    sku: CommercialSku,
    service_period_start: DateText,
    service_period_end: DateText,
    usage_fact_id: RequiredNullable<Uuid>,
    usage_fact_digest: RequiredNullable<Sha256Digest>,
    tariff_version_id: RequiredNullable<Uuid>,
    tariff_record_digest: RequiredNullable<Sha256Digest>,
    discount_decision_id: RequiredNullable<Uuid>,
    discount_record_digest: RequiredNullable<Sha256Digest>,
    discount_source_ordinal: RequiredNullable<i32>,
    corrects_line_id: RequiredNullable<Uuid>,
    meter_kind: RequiredNullable<UsageMeterKind>,
    quantity: Decimal,
    unit_price: Decimal,
    expected_subtotal: Decimal,
    expected_discount_amount: Decimal,
    expected_taxable_amount: Decimal,
    tax_category: TaxCategory,
    tax_rate_basis_points: i32,
    tax_exemption_digest: RequiredNullable<Sha256Digest>,
    tax_policy_digest: Sha256Digest,
    expected_tax_amount: Decimal,
    expected_correction_amount: Decimal,
    correction_set_digest: Sha256Digest,
    rounding_policy_digest: Sha256Digest,
    expected_line_total: Decimal,
    currency: String,
    source_line_digest: Sha256Digest,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in super::super) struct EconomicsInvoiceMembershipImportV1 {
    root_membership_id: Uuid,
    revision: i64,
    membership_effect: MembershipEffect,
    supersedes_membership_id: RequiredNullable<Uuid>,
    predecessor_invoice_id: RequiredNullable<Uuid>,
    predecessor_membership_digest: RequiredNullable<Sha256Digest>,
    deployment_id: Uuid,
    organization_id: Uuid,
    contract_period_id: Uuid,
    contract_id: Uuid,
    sku: CommercialSku,
    accounting_timezone: String,
    currency: String,
    usage_root_fact_id: Uuid,
    usage_fact_id: Uuid,
    usage_fact_revision: i64,
    usage_fact_digest: Sha256Digest,
    usage_window_receipt_id: Uuid,
    usage_window_receipt_version: i64,
    usage_window_receipt_digest: Sha256Digest,
    meter_kind: UsageMeterKind,
    period_start: DateText,
    period_end: DateText,
    measurement_window_digest: Sha256Digest,
    measurement_state: MeasurementState,
    membership_kind: MembershipKind,
    billable_quantity: Decimal,
    included_quantity: Decimal,
    charged_quantity: Decimal,
    billable_unit: BillableUnit,
    invoice_line_ordinal: RequiredNullable<i32>,
    allocation_policy_digest: Sha256Digest,
    expected_head_id: RequiredNullable<Uuid>,
    expected_head_revision: RequiredNullable<i64>,
    expected_head_digest: RequiredNullable<Sha256Digest>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in super::super) struct EconomicsInvoiceImportV1 {
    invoice: EconomicsInvoiceHeaderImportV1,
    lines: Vec<EconomicsInvoiceLineImportV1>,
    memberships: Vec<EconomicsInvoiceMembershipImportV1>,
    discounts: Vec<EconomicsDiscountSourceImportV1>,
}
