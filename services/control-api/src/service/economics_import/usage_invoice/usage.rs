use super::*;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in super::super) struct EconomicsUsageReceiptImportV1 {
    root_receipt_id: Uuid,
    receipt_version: i64,
    receipt_effect: UsageEffect,
    supersedes_receipt_id: RequiredNullable<Uuid>,
    predecessor_receipt_digest: RequiredNullable<Sha256Digest>,
    deployment_id: Uuid,
    organization_id: Uuid,
    contract_period_id: Uuid,
    contract_id: Uuid,
    tariff_version_id: Uuid,
    sku: CommercialSku,
    accounting_timezone: String,
    accounting_policy_digest: Sha256Digest,
    period_start: DateText,
    period_end: DateText,
    measurement_window_digest: Sha256Digest,
    receipt_kind: UsageReceiptKind,
    meter_kind: UsageMeterKind,
    unit: UsageUnit,
    measurement_state: MeasurementState,
    expected_item_count: i64,
    observed_item_count: i64,
    observed_quantity: RequiredNullable<Decimal>,
    normalization_basis_kind: NormalizationBasisKind,
    normalization_input_quantity: RequiredNullable<Decimal>,
    coverage_digest: Sha256Digest,
    source_system_id: String,
    source_window_identity_hmac: Sha256Digest,
    source_window_hmac_key_version: String,
    source_cursor_set_digest: Sha256Digest,
    source_record_set_digest: Sha256Digest,
    source_signature_digest: Sha256Digest,
    meter_policy_version: String,
    meter_policy_digest: Sha256Digest,
    measured_at: DateTimeText,
    expected_head_id: RequiredNullable<Uuid>,
    expected_head_version: RequiredNullable<i64>,
    expected_head_digest: RequiredNullable<Sha256Digest>,
}

impl EconomicsUsageReceiptImportV1 {
    fn validate(&self) -> Result<(), ServiceError> {
        let chain = match self.receipt_effect {
            UsageEffect::Original => {
                self.receipt_version == 1
                    && no_fence(
                        &self.supersedes_receipt_id,
                        &self.predecessor_receipt_digest,
                    )
            }
            UsageEffect::Replacement | UsageEffect::Reversal => {
                self.receipt_version > 1
                    && full_fence(
                        &self.supersedes_receipt_id,
                        &self.predecessor_receipt_digest,
                    )
            }
        };
        let quantities = match (self.receipt_effect, self.measurement_state) {
            (UsageEffect::Reversal, MeasurementState::Unknown) => {
                self.observed_quantity.is_none() && self.normalization_input_quantity.is_none()
            }
            (UsageEffect::Reversal, _) => false,
            (_, MeasurementState::Complete) => {
                self.observed_item_count == self.expected_item_count
                    && nonnegative(&self.observed_quantity)
                    && nonnegative(&self.normalization_input_quantity)
            }
            (_, MeasurementState::Partial | MeasurementState::Unknown) => {
                self.observed_quantity.is_none() && self.normalization_input_quantity.is_none()
            }
        };
        if any_nil(&[
            self.root_receipt_id,
            self.deployment_id,
            self.organization_id,
            self.contract_period_id,
            self.contract_id,
            self.tariff_version_id,
        ]) || !optional_uuid(&self.supersedes_receipt_id)
            || !valid_head(
                &self.expected_head_id,
                &self.expected_head_version,
                &self.expected_head_digest,
            )
            || !chain
            || self.period_end <= self.period_start
            || self.expected_item_count < 0
            || self.observed_item_count < 0
            || self.observed_item_count > self.expected_item_count
            || !quantities
            || !valid_usage_shape(self)
            || !valid_trimmed(&self.accounting_timezone, 63)
            || !valid_source_system(&self.source_system_id)
            || !valid_trimmed(&self.source_window_hmac_key_version, 100)
            || !valid_trimmed(&self.meter_policy_version, 100)
        {
            return Err(ServiceError::InvalidRequest);
        }
        let _evidence = (
            &self.accounting_policy_digest,
            &self.measurement_window_digest,
            &self.coverage_digest,
            &self.source_window_identity_hmac,
            &self.source_cursor_set_digest,
            &self.source_record_set_digest,
            &self.source_signature_digest,
            &self.meter_policy_digest,
            &self.measured_at,
            self.sku,
        );
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in super::super) struct EconomicsUsageFactImportV1 {
    root_usage_fact_id: Uuid,
    revision: i64,
    fact_effect: UsageEffect,
    supersedes_usage_fact_id: RequiredNullable<Uuid>,
    predecessor_record_digest: RequiredNullable<Sha256Digest>,
    deployment_id: Uuid,
    organization_id: Uuid,
    contract_period_id: Uuid,
    contract_id: Uuid,
    tariff_version_id: Uuid,
    sku: CommercialSku,
    accounting_timezone: String,
    accounting_policy_digest: Sha256Digest,
    period_start: DateText,
    period_end: DateText,
    measurement_window_digest: Sha256Digest,
    measurement_state: MeasurementState,
    expected_item_count: i64,
    observed_item_count: i64,
    coverage_digest: Sha256Digest,
    meter_kind: UsageMeterKind,
    unit: UsageUnit,
    quantity: RequiredNullable<Decimal>,
    billable_metric: BillableMetric,
    billable_quantity: RequiredNullable<Decimal>,
    billable_unit: BillableUnit,
    conversion_policy_digest: Sha256Digest,
    source_receipt_kind: UsageReceiptKind,
    source_receipt_id: Uuid,
    source_receipt_version: i64,
    source_receipt_digest: Sha256Digest,
    meter_policy_version: String,
    meter_policy_digest: Sha256Digest,
    measured_at: DateTimeText,
    expected_head_id: RequiredNullable<Uuid>,
    expected_head_revision: RequiredNullable<i64>,
    expected_head_digest: RequiredNullable<Sha256Digest>,
}

impl EconomicsUsageFactImportV1 {
    fn validate(&self) -> Result<(), ServiceError> {
        let chain = match self.fact_effect {
            UsageEffect::Original => {
                self.revision == 1
                    && no_fence(
                        &self.supersedes_usage_fact_id,
                        &self.predecessor_record_digest,
                    )
            }
            UsageEffect::Replacement | UsageEffect::Reversal => {
                self.revision > 1
                    && full_fence(
                        &self.supersedes_usage_fact_id,
                        &self.predecessor_record_digest,
                    )
            }
        };
        let quantities = match (self.fact_effect, self.measurement_state) {
            (UsageEffect::Reversal, MeasurementState::Unknown) => {
                self.quantity.is_none() && self.billable_quantity.is_none()
            }
            (UsageEffect::Reversal, _) => false,
            (_, MeasurementState::Complete) => {
                self.observed_item_count == self.expected_item_count
                    && nonnegative(&self.quantity)
                    && nonnegative(&self.billable_quantity)
            }
            (_, MeasurementState::Partial | MeasurementState::Unknown) => {
                self.quantity.is_none() && self.billable_quantity.is_none()
            }
        };
        if any_nil(&[
            self.root_usage_fact_id,
            self.deployment_id,
            self.organization_id,
            self.contract_period_id,
            self.contract_id,
            self.tariff_version_id,
            self.source_receipt_id,
        ]) || !optional_uuid(&self.supersedes_usage_fact_id)
            || self.source_receipt_version < 1
            || !valid_head(
                &self.expected_head_id,
                &self.expected_head_revision,
                &self.expected_head_digest,
            )
            || !chain
            || self.period_end <= self.period_start
            || self.expected_item_count < 0
            || self.observed_item_count < 0
            || self.observed_item_count > self.expected_item_count
            || !quantities
            || !valid_fact_shape(self)
            || !valid_trimmed(&self.accounting_timezone, 63)
            || !valid_trimmed(&self.meter_policy_version, 100)
        {
            return Err(ServiceError::InvalidRequest);
        }
        let _evidence = (
            &self.accounting_policy_digest,
            &self.measurement_window_digest,
            &self.coverage_digest,
            &self.conversion_policy_digest,
            &self.source_receipt_digest,
            &self.meter_policy_digest,
            &self.measured_at,
            self.sku,
        );
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in super::super) struct EconomicsUsageWindowImportV1 {
    receipt: EconomicsUsageReceiptImportV1,
    fact: EconomicsUsageFactImportV1,
}

impl EconomicsUsageWindowImportV1 {
    pub(in super::super) fn validate(&self) -> Result<(), ServiceError> {
        self.receipt.validate()?;
        self.fact.validate()?;
        let r = &self.receipt;
        let f = &self.fact;
        if r.root_receipt_id != f.source_receipt_id
            || r.receipt_version != f.source_receipt_version
            || r.receipt_kind != f.source_receipt_kind
            || r.deployment_id != f.deployment_id
            || r.organization_id != f.organization_id
            || r.contract_period_id != f.contract_period_id
            || r.contract_id != f.contract_id
            || r.tariff_version_id != f.tariff_version_id
            || r.sku != f.sku
            || r.accounting_timezone != f.accounting_timezone
            || r.accounting_policy_digest != f.accounting_policy_digest
            || r.period_start != f.period_start
            || r.period_end != f.period_end
            || r.measurement_window_digest != f.measurement_window_digest
            || r.measurement_state != f.measurement_state
            || r.expected_item_count != f.expected_item_count
            || r.observed_item_count != f.observed_item_count
            || r.coverage_digest != f.coverage_digest
            || r.meter_kind != f.meter_kind
            || r.unit != f.unit
            || r.meter_policy_version != f.meter_policy_version
            || r.meter_policy_digest != f.meter_policy_digest
            || r.measured_at != f.measured_at
        {
            return Err(ServiceError::InvalidRequest);
        }
        Ok(())
    }
}

fn valid_usage_shape(value: &EconomicsUsageReceiptImportV1) -> bool {
    matches!(
        (
            value.meter_kind,
            value.receipt_kind,
            value.unit,
            value.normalization_basis_kind,
        ),
        (
            UsageMeterKind::Seat,
            UsageReceiptKind::IdentityUsageWindow,
            UsageUnit::Count,
            NormalizationBasisKind::ActiveContributorCount,
        ) | (
            UsageMeterKind::AgentToken,
            UsageReceiptKind::AgentUsageWindow,
            UsageUnit::Token,
            NormalizationBasisKind::AgentTokenCount,
        ) | (
            UsageMeterKind::ModelRequest,
            UsageReceiptKind::ModelUsageWindow,
            UsageUnit::Request,
            NormalizationBasisKind::ModelRequestCostUnit,
        ) | (
            UsageMeterKind::SourcePage,
            UsageReceiptKind::SourceUsageWindow,
            UsageUnit::Page,
            NormalizationBasisKind::SourcePageCount,
        ) | (
            UsageMeterKind::StorageByteHour,
            UsageReceiptKind::StorageUsageWindow,
            UsageUnit::ByteHour,
            NormalizationBasisKind::EncryptedByteHour,
        ) | (
            UsageMeterKind::DeliveryAttempt,
            UsageReceiptKind::DeliveryUsageWindow,
            UsageUnit::Attempt,
            NormalizationBasisKind::DeliveryAttemptCount,
        ) | (
            UsageMeterKind::ExportByte,
            UsageReceiptKind::ExportUsageWindow,
            UsageUnit::Byte,
            NormalizationBasisKind::ExportByteCount,
        ) | (
            UsageMeterKind::ApiRequest,
            UsageReceiptKind::ApiUsageWindow,
            UsageUnit::Request,
            NormalizationBasisKind::ApiRecordReturnedCount,
        )
    )
}

fn valid_fact_shape(value: &EconomicsUsageFactImportV1) -> bool {
    matches!(
        (
            value.meter_kind,
            value.unit,
            value.source_receipt_kind,
            value.billable_metric,
            value.billable_unit,
        ),
        (
            UsageMeterKind::Seat,
            UsageUnit::Count,
            UsageReceiptKind::IdentityUsageWindow,
            BillableMetric::ActiveContributor,
            BillableUnit::ContributorMonth,
        ) | (
            UsageMeterKind::AgentToken,
            UsageUnit::Token,
            UsageReceiptKind::AgentUsageWindow,
            BillableMetric::ProcessingCredit,
            BillableUnit::Credit,
        ) | (
            UsageMeterKind::ModelRequest,
            UsageUnit::Request,
            UsageReceiptKind::ModelUsageWindow,
            BillableMetric::ProcessingCredit,
            BillableUnit::Credit,
        ) | (
            UsageMeterKind::SourcePage,
            UsageUnit::Page,
            UsageReceiptKind::SourceUsageWindow,
            BillableMetric::ProcessingCredit,
            BillableUnit::Credit,
        ) | (
            UsageMeterKind::StorageByteHour,
            UsageUnit::ByteHour,
            UsageReceiptKind::StorageUsageWindow,
            BillableMetric::StorageGbMonth,
            BillableUnit::GbMonth,
        ) | (
            UsageMeterKind::DeliveryAttempt,
            UsageUnit::Attempt,
            UsageReceiptKind::DeliveryUsageWindow,
            BillableMetric::IncludedDelivery,
            BillableUnit::Attempt,
        ) | (
            UsageMeterKind::ExportByte,
            UsageUnit::Byte,
            UsageReceiptKind::ExportUsageWindow,
            BillableMetric::IncludedExport,
            BillableUnit::Byte,
        ) | (
            UsageMeterKind::ApiRequest,
            UsageUnit::Request,
            UsageReceiptKind::ApiUsageWindow,
            BillableMetric::ApiRecordUnit,
            BillableUnit::KiloRecords,
        )
    )
}
