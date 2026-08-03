use gurine_domain::economics::{MetricStatus, MetricValue};
use rust_decimal::Decimal;
use sqlx::{PgPool, Row};
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
    sqlx::query(
        "SELECT usage_root_fact_id, usage_fact_id, usage_fact_digest, meter_kind::text,
                period_start, period_end, measurement_state::text,
                membership_kind::text, current_invoice_id, current_membership_digest,
                blocker_code
           FROM ops.read_invoice_membership_v1($1,$2,$3,$4,$5)",
    )
    .bind(contract_period_id)
    .bind(contract_digest)
    .bind(period_start)
    .bind(period_end)
    .bind(billing_cutoff_at)
    .fetch_all(pool)
    .await?
    .into_iter()
    .map(|row| {
        Ok(InvoiceMembershipRow {
            usage_root_fact_id: row.try_get("usage_root_fact_id")?,
            usage_fact_id: row.try_get("usage_fact_id")?,
            usage_fact_digest: row.try_get("usage_fact_digest")?,
            meter_kind: row.try_get("meter_kind")?,
            period_start: row.try_get("period_start")?,
            period_end: row.try_get("period_end")?,
            measurement_state: row.try_get("measurement_state")?,
            membership_kind: row.try_get("membership_kind")?,
            current_invoice_id: row.try_get("current_invoice_id")?,
            current_membership_digest: row.try_get("current_membership_digest")?,
            blocker_code: row.try_get("blocker_code")?,
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
    sqlx::query(
        "SELECT organization_id, acquisition_amount, attribution_state,
                acquisition_source_receipt_digest, input_set_digest,
                metric_status, reason_code
           FROM ops.read_cac_metric_inputs_v1($1,$2,$3,$4)",
    )
    .bind(period_start)
    .bind(period_end)
    .bind(reporting_currency)
    .bind(accounting_policy_digest)
    .fetch_all(pool)
    .await?
    .into_iter()
    .map(|row| {
        let status = match row.try_get::<String, _>("metric_status")?.as_str() {
            "KNOWN" => MetricStatus::Known,
            "NOT_APPLICABLE" => MetricStatus::NotApplicable,
            _ => MetricStatus::Unknown,
        };
        Ok(CacMetricInputRow {
            organization_id: row.try_get("organization_id")?,
            acquisition_amount: row.try_get("acquisition_amount")?,
            attribution_state: row.try_get("attribution_state")?,
            acquisition_source_receipt_digest: row.try_get("acquisition_source_receipt_digest")?,
            input_set_digest: row.try_get("input_set_digest")?,
            metric_status: status,
            reason_code: row.try_get("reason_code")?,
        })
    })
    .collect()
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
