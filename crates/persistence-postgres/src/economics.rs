use gurine_domain::economics::{MetricStatus, MetricValue};
use rust_decimal::Decimal;
use sqlx::PgPool;
use uuid::Uuid;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InvoiceMembershipRow {
    pub usage_root_fact_id: Uuid,
    pub usage_fact_id: Uuid,
    pub usage_fact_digest: String,
    pub meter_kind: String,
    pub period_start: time::Date,
    pub period_end: time::Date,
    pub measurement_state: String,
    pub membership_kind: Option<String>,
    pub current_invoice_id: Option<Uuid>,
    pub current_membership_digest: Option<String>,
    pub blocker_code: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CacMetricInputRow {
    pub organization_id: Option<Uuid>,
    pub acquisition_amount: Decimal,
    pub attribution_state: String,
    pub acquisition_source_receipt_digest: Option<String>,
    pub input_set_digest: String,
    pub metric_status: MetricStatus,
    pub reason_code: String,
}

pub async fn read_invoice_memberships(
    pool: &PgPool,
    contract_period_id: Uuid,
    contract_digest: &str,
    period_start: time::Date,
    period_end: time::Date,
    billing_cutoff_at: time::OffsetDateTime,
) -> Result<Vec<InvoiceMembershipRow>, sqlx::Error> {
    sqlx::query!(
        "SELECT usage_root_fact_id, usage_fact_id, usage_fact_digest, meter_kind::text,
                period_start, period_end, measurement_state::text,
                membership_kind::text, current_invoice_id, current_membership_digest,
                blocker_code
           FROM ops.read_invoice_membership_v1($1,$2,$3,$4,$5)",
        contract_period_id,
        contract_digest,
        period_start,
        period_end,
        billing_cutoff_at,
    )
    .fetch_all(pool)
    .await?
    .into_iter()
    .map(|row| {
        Ok(InvoiceMembershipRow {
            usage_root_fact_id: required(row.usage_root_fact_id)?,
            usage_fact_id: required(row.usage_fact_id)?,
            usage_fact_digest: required(row.usage_fact_digest)?,
            meter_kind: required(row.meter_kind)?,
            period_start: required(row.period_start)?,
            period_end: required(row.period_end)?,
            measurement_state: required(row.measurement_state)?,
            membership_kind: row.membership_kind,
            current_invoice_id: row.current_invoice_id,
            current_membership_digest: row.current_membership_digest,
            blocker_code: row.blocker_code,
        })
    })
    .collect()
}

pub async fn read_cac_metric_inputs(
    pool: &PgPool,
    period_start: time::Date,
    period_end: time::Date,
    reporting_currency: &str,
    accounting_policy_digest: &str,
) -> Result<Vec<CacMetricInputRow>, sqlx::Error> {
    sqlx::query!(
        "SELECT organization_id, acquisition_amount, attribution_state,
                acquisition_source_receipt_digest, input_set_digest,
                metric_status AS \"metric_status?: String\", reason_code
           FROM ops.read_cac_metric_inputs_v1($1,$2,$3,$4)",
        period_start,
        period_end,
        reporting_currency,
        accounting_policy_digest,
    )
    .fetch_all(pool)
    .await?
    .into_iter()
    .map(|row| {
        let status = match required(row.metric_status)?.as_str() {
            "KNOWN" => MetricStatus::Known,
            "NOT_APPLICABLE" => MetricStatus::NotApplicable,
            _ => MetricStatus::Unknown,
        };
        Ok(CacMetricInputRow {
            organization_id: row.organization_id,
            acquisition_amount: required(row.acquisition_amount)?,
            attribution_state: required(row.attribution_state)?,
            acquisition_source_receipt_digest: row.acquisition_source_receipt_digest,
            input_set_digest: required(row.input_set_digest)?,
            metric_status: status,
            reason_code: required(row.reason_code)?,
        })
    })
    .collect()
}

fn required<T>(value: Option<T>) -> Result<T, sqlx::Error> {
    value.ok_or_else(|| sqlx::Error::Decode(Box::new(sqlx::error::UnexpectedNullError)))
}

pub fn metric_value<T>(
    status: MetricStatus,
    value: Option<T>,
    reason_code: String,
    evidence_digest: String,
) -> MetricValue<T> {
    MetricValue {
        status,
        value,
        reason_code,
        evidence_digest,
    }
}
