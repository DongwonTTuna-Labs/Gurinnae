use super::*;

#[path = "fx_validation.rs"]
mod fx_validation;
#[path = "cost_validation.rs"]
mod validation;

macro_rules! closed_enum {
    ($name:ident { $($variant:ident => $wire:literal),+ $(,)? }) => {
        #[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
        enum $name {
            $(#[serde(rename = $wire)] $variant),+
        }
    };
}

closed_enum!(CostCaptureState { Measured => "MEASURED", Unknown => "UNKNOWN" });
closed_enum!(CostClaimState {
    Eligible => "ELIGIBLE", Incomplete => "INCOMPLETE", NoActivity => "NO_ACTIVITY",
});
closed_enum!(CostAllocationKind {
    Direct => "DIRECT", Shared => "SHARED", Unallocated => "UNALLOCATED",
});
closed_enum!(CostCategory {
    Compute => "COMPUTE", DatabaseWalBackup => "DATABASE_WAL_BACKUP", Storage => "STORAGE",
    Egress => "EGRESS", ModelOcr => "MODEL_OCR", Search => "SEARCH", Delivery => "DELIVERY",
    Observability => "OBSERVABILITY", Support => "SUPPORT", HumanReview => "HUMAN_REVIEW",
    LegalSecurity => "LEGAL_SECURITY", SalesCustomerAcquisition => "SALES_CUSTOMER_ACQUISITION",
});
closed_enum!(CostTargetKind {
    Job => "JOB", AgentRun => "AGENT_RUN", Case => "CASE", Organization => "ORGANIZATION",
    OutcomeFact => "OUTCOME_FACT", Unallocated => "UNALLOCATED",
});
closed_enum!(AcquisitionAttributionState {
    Attributed => "ATTRIBUTED", Unattributed => "UNATTRIBUTED",
});
closed_enum!(CostDriverKind {
    DirectIdentity => "DIRECT_IDENTITY", RawRecord => "RAW_RECORD",
    NormalizedLine => "NORMALIZED_LINE", OcrPage => "OCR_PAGE", AnalysisJob => "ANALYSIS_JOB",
    CohortRerun => "COHORT_RERUN", EvidencePacket => "EVIDENCE_PACKET",
    ApiRecordUnit => "API_RECORD_UNIT", GbMonth => "GB_MONTH",
    DeliveryAttempt1000 => "DELIVERY_ATTEMPT_1000", SupportHour => "SUPPORT_HOUR",
    MaterialCorrectionHour => "MATERIAL_CORRECTION_HOUR", None => "NONE",
});
closed_enum!(FxFactKind {
    Observation => "OBSERVATION", Replacement => "REPLACEMENT", Withdrawal => "WITHDRAWAL",
});
closed_enum!(FxQuoteConvention { TargetPerSource => "TARGET_PER_SOURCE" });
closed_enum!(FxRateKind {
    Transaction => "TRANSACTION", DailyClose => "DAILY_CLOSE", Contractual => "CONTRACTUAL",
});
closed_enum!(FxCorrectionReason {
    SourceRestatement => "SOURCE_RESTATEMENT", SourceWithdrawal => "SOURCE_WITHDRAWAL",
    ManualReconciliation => "MANUAL_RECONCILIATION",
});

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct EconomicsFxRateAppendV1 {
    root_rate_id: RequiredNullable<Uuid>,
    revision: i64,
    fact_kind: FxFactKind,
    supersedes_rate_id: RequiredNullable<Uuid>,
    source_currency: String,
    target_currency: String,
    quote_convention: FxQuoteConvention,
    rate: RequiredNullable<Decimal>,
    rate_kind: FxRateKind,
    source_id: String,
    source_record_identity_hmac: Sha256Digest,
    source_record_hmac_key_version: String,
    source_priority: i16,
    observed_at: DateTimeText,
    valid_until: DateTimeText,
    rate_policy_digest: Sha256Digest,
    source_receipt_digest: Sha256Digest,
    signature_digest: Sha256Digest,
    correction_reason: RequiredNullable<FxCorrectionReason>,
    expected_record_digest: Sha256Digest,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct EconomicsFxRateSourceImportV1 {
    resolution: EconomicsSourceResolutionV1,
    existing_rate_id: RequiredNullable<Uuid>,
    existing_rate_revision: RequiredNullable<i64>,
    existing_rate_digest: RequiredNullable<Sha256Digest>,
    append_value: RequiredNullable<EconomicsFxRateAppendV1>,
    evidence_segment_id: Uuid,
    evidence_segment_digest: Sha256Digest,
    source_signature_digest: Sha256Digest,
    expected_head_id: RequiredNullable<Uuid>,
    expected_head_revision: RequiredNullable<i64>,
    expected_head_digest: RequiredNullable<Sha256Digest>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in super::super) struct EconomicsCostPeriodImportV1 {
    period_revision_id: Uuid,
    supersedes_period_revision_id: RequiredNullable<Uuid>,
    deployment_id: Uuid,
    accounting_timezone: String,
    accounting_policy_digest: Sha256Digest,
    period_start: DateText,
    period_end: DateText,
    currency: String,
    period_version: i64,
    source_set_digest: Sha256Digest,
    pool_set_digest: Sha256Digest,
    driver_set_digest: Sha256Digest,
    correction_set_digest: Sha256Digest,
    expected_allocation_set_digest: Sha256Digest,
    expected_captured_cost_count: i64,
    expected_cost_count: RequiredNullable<i64>,
    expected_cost_capture_state: CostCaptureState,
    expected_cost_capture_coverage: RequiredNullable<Decimal>,
    expected_direct_eligible_amount: Decimal,
    expected_direct_allocated_amount: Decimal,
    expected_captured_cost_amount: Decimal,
    expected_attributed_cost_amount: Decimal,
    expected_unallocated_amount: Decimal,
    expected_direct_coverage: Decimal,
    expected_total_coverage: Decimal,
    expected_claim_state: CostClaimState,
    incomplete_reason_set_digest: RequiredNullable<Sha256Digest>,
    unknown_cost_scope_digest: RequiredNullable<Sha256Digest>,
    close_receipt_id: Uuid,
    close_receipt_digest: Sha256Digest,
    closed_at: DateTimeText,
    schedule_revision: i64,
    schedule_digest: Sha256Digest,
    expected_head_id: RequiredNullable<Uuid>,
    expected_head_version: RequiredNullable<i64>,
    expected_head_digest: RequiredNullable<Sha256Digest>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in super::super) struct EconomicsCostLineImportV1 {
    line_sequence: i64,
    allocation_kind: CostAllocationKind,
    cost_category: CostCategory,
    source_cost_event_id: Uuid,
    source_effective_digest: Sha256Digest,
    source_currency: String,
    source_amount: Decimal,
    fx_rate_fact_id: RequiredNullable<Uuid>,
    fx_source_ordinal: RequiredNullable<i32>,
    reporting_source_amount: Decimal,
    target_kind: CostTargetKind,
    job_id: RequiredNullable<Uuid>,
    agent_run_id: RequiredNullable<Uuid>,
    case_id: RequiredNullable<Uuid>,
    organization_id: RequiredNullable<Uuid>,
    outcome_fact_id: RequiredNullable<Uuid>,
    acquisition_campaign_digest: RequiredNullable<Sha256Digest>,
    acquisition_source_receipt_id: RequiredNullable<Uuid>,
    acquisition_source_receipt_digest: RequiredNullable<Sha256Digest>,
    acquisition_attribution_state: RequiredNullable<AcquisitionAttributionState>,
    unattributed_acquisition_pool_digest: RequiredNullable<Sha256Digest>,
    driver_kind: CostDriverKind,
    driver_quantity: RequiredNullable<Decimal>,
    driver_total_quantity: RequiredNullable<Decimal>,
    allocation_ratio: RequiredNullable<Decimal>,
    rounding_adjustment: Decimal,
    allocated_amount: Decimal,
    allocation_rule_version: i64,
    allocation_rule_digest: Sha256Digest,
    schedule_revision: i64,
    schedule_digest: Sha256Digest,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in super::super) struct EconomicsCostCloseImportV1 {
    period: EconomicsCostPeriodImportV1,
    lines: Vec<EconomicsCostLineImportV1>,
    fx_rates: Vec<EconomicsFxRateSourceImportV1>,
}
