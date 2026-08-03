const FUNDING_REPORT_KIND: &str = "FUNDING_DISCLOSURE";
const FUNDING_REPORT_SCHEMA_VERSION: i64 = 1;
const FUNDING_INDEPENDENCE_NOTICE: &str = "후원은 접근권이 아니며 조사 대상 면제가 아닙니다";
const PUBLIC_FUNDING_EXPENSE_AUTHORITY_NOTICE: &str = "승인된 공개 비용 계약이 없어 비용 공개 권위가 없습니다. 내부 원가를 추정하거나 공개값으로 바꾸지 않습니다.";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum FundingDownloadFormat {
    Json,
    Csv,
}

impl FundingDownloadFormat {
    fn parse(query: &Query) -> Result<Self, ServiceError> {
        query.require_closed_singletons(&["format"])?;
        match query.values.get("format").map(Vec::as_slice) {
            None => Ok(Self::Json),
            Some([value]) if value == "JSON" => Ok(Self::Json),
            Some([value]) if value == "CSV" => Ok(Self::Csv),
            Some(_) => Err(ServiceError::InvalidRequest),
        }
    }

    const fn label(self) -> &'static str {
        match self {
            Self::Json => "JSON",
            Self::Csv => "CSV",
        }
    }

    const fn extension(self) -> &'static str {
        match self {
            Self::Json => "json",
            Self::Csv => "csv",
        }
    }

    const fn media_type(self) -> &'static str {
        match self {
            Self::Json => "application/json",
            Self::Csv => "text/csv",
        }
    }
}

#[derive(Clone, sqlx::FromRow)]
struct FundingReportRow {
    id: Uuid,
    period_start: Date,
    period_end: Date,
    title: String,
    summary: String,
    report: Value,
    published_at: OffsetDateTime,
    report_kind: String,
    source_revision_id: Option<Uuid>,
    source_disclosure_id: Option<Uuid>,
    source_revision: Option<i64>,
    source_revision_digest: Option<String>,
    supersedes_report_id: Option<Uuid>,
    report_schema_version: Option<i64>,
    projection_digest: Option<String>,
    projected_at: Option<OffsetDateTime>,
    supersedes_binding_valid: bool,
}

struct VerifiedFundingReport {
    row: FundingReportRow,
    disclosure: FundingDisclosurePublicV1,
    source_revision_digest: String,
    projection_digest: String,
    projected_at: OffsetDateTime,
}

#[derive(Clone, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct FundingDisclosurePublicV1 {
    schema_version: i64,
    disclosure_id: Uuid,
    revision: i64,
    fiscal_year: i32,
    fiscal_quarter: i16,
    period_start: String,
    period_end: String,
    reporting_currency: String,
    concentration_band: String,
    caveat: Option<String>,
    purpose: String,
    policy_requests: FundingPolicyRequestsPublicV1,
    sources: Vec<String>,
    entries: Vec<FundingDisclosurePublicEntryV1>,
    effective_at: String,
    published_at: String,
    supersedes_revision: Option<i64>,
    source_revision_digest: String,
    public_content_digest: String,
}

#[derive(Clone, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct FundingPolicyRequestsPublicV1 {
    total: i32,
    accepted: i32,
    partially_accepted: i32,
    rejected: i32,
    withdrawn: i32,
    pending: i32,
    outcome_digest: String,
}

#[derive(Clone, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct FundingDisclosurePublicEntryV1 {
    ordinal: i32,
    identity_disclosure_mode: String,
    public_display_name: Option<String>,
    withholding_public_explanation: Option<String>,
    counterparty_category: String,
    funding_source_kind: String,
    amount_band_lower: String,
    amount_band_upper: Option<String>,
    reporting_currency: String,
    concentration_band: String,
    denominator_unknown_reason: Option<String>,
    grouping_dispute_reason: Option<String>,
    concentration_unknown_reason: Option<String>,
    public_caveat_text: Option<String>,
    purpose: String,
    conflict_disclosure: String,
    mitigation_summary: String,
    government_related: bool,
    political_party_related: bool,
    procurement_supplier_related: bool,
    investigated_subject_related: bool,
    related_party: bool,
    public_case_refs: Vec<String>,
    public_source_links: Vec<String>,
    entry_digest: String,
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct FundingReportDownloadV1<'a> {
    schema_version: i64,
    notice: &'static str,
    report_id: Uuid,
    source_revision: i64,
    source_revision_digest: &'a str,
    projection_digest: &'a str,
    report: &'a FundingDisclosurePublicV1,
}

async fn funding_content(pool: &PgPool) -> Result<Value, ServiceError> {
    let row = latest_funding_report(pool).await?;
    match row {
        Some(row) => render_funding_content(verify_ready_funding_report(row)?),
        None => render_unknown_funding_content(),
    }
}

async fn latest_funding_report(pool: &PgPool) -> Result<Option<FundingReportRow>, ServiceError> {
    sqlx::query_as::<_, FundingReportRow>(
        "SELECT report.id,report.period_start,report.period_end,report.title,report.summary,\
         report.report,report.published_at,report.report_kind,\
         source_revision_id,source_disclosure_id,source_revision,source_revision_digest,\
         supersedes_report_id,report_schema_version,projection_digest,projected_at,\
         CASE WHEN report.source_revision=1 THEN report.supersedes_report_id IS NULL \
         ELSE EXISTS(SELECT 1 FROM public.transparency_reports AS predecessor \
         WHERE predecessor.id=report.supersedes_report_id \
         AND predecessor.report_kind='FUNDING_DISCLOSURE' \
         AND predecessor.source_disclosure_id=report.source_disclosure_id \
         AND predecessor.source_revision=report.source_revision-1) \
         END AS supersedes_binding_valid \
         FROM public.transparency_reports AS report \
         WHERE report.report_kind='FUNDING_DISCLOSURE' \
         ORDER BY report.published_at DESC,report.source_revision DESC,report.id DESC LIMIT 1",
    )
    .fetch_optional(pool)
    .await
    .map_err(db)
}

async fn list_funding_reports(pool: &PgPool, query: &Query) -> Result<Value, ServiceError> {
    validate_funding_list_query(query)?;
    let period_from = optional_date(query, "periodFrom")?;
    let period_to = optional_date(query, "periodTo")?;
    validate_range(period_from.as_ref(), period_to.as_ref())?;
    let sort = requested_sort(query, &["published_desc", "period_desc"], "published_desc")?;
    let rows = sqlx::query_as::<_, FundingReportRow>(
        "SELECT report.id,report.period_start,report.period_end,report.title,report.summary,\
         report.report,report.published_at,report.report_kind,\
         source_revision_id,source_disclosure_id,source_revision,source_revision_digest,\
         supersedes_report_id,report_schema_version,projection_digest,projected_at,\
         CASE WHEN report.source_revision=1 THEN report.supersedes_report_id IS NULL \
         ELSE EXISTS(SELECT 1 FROM public.transparency_reports AS predecessor \
         WHERE predecessor.id=report.supersedes_report_id \
         AND predecessor.report_kind='FUNDING_DISCLOSURE' \
         AND predecessor.source_disclosure_id=report.source_disclosure_id \
         AND predecessor.source_revision=report.source_revision-1) \
         END AS supersedes_binding_valid \
         FROM public.transparency_reports AS report \
         WHERE report.report_kind='FUNDING_DISCLOSURE' \
         AND ($1::date IS NULL OR report.period_end >= $1) \
         AND ($2::date IS NULL OR report.period_start <= $2) \
         ORDER BY CASE WHEN $3='published_desc' THEN report.published_at END DESC,\
         CASE WHEN $3='period_desc' THEN report.period_end END DESC,\
         CASE WHEN $3='period_desc' THEN report.period_start END DESC,\
         report.source_revision DESC,report.id DESC LIMIT $4 OFFSET $5",
    )
    .bind(period_from)
    .bind(period_to)
    .bind(sort)
    .bind(query.limit + 1)
    .bind(query.offset)
    .fetch_all(pool)
    .await
    .map_err(db)?;
    let items = rows
        .into_iter()
        .map(verify_ready_funding_report)
        .map(|report| report.and_then(funding_report_item))
        .collect::<Result<Vec<_>, _>>()?;
    let mut filters = Map::new();
    for name in ["periodFrom", "periodTo"] {
        if let Some(value) = query.first(name) {
            filters.insert(name.to_owned(), json!(value));
        }
    }
    page(items, query, Value::Object(filters))
}

fn validate_funding_list_query(query: &Query) -> Result<(), ServiceError> {
    query.require_closed_singletons(&["cursor", "limit", "periodFrom", "periodTo", "sort"])?;
    if query.limit <= 100 {
        Ok(())
    } else {
        Err(ServiceError::InvalidRequest)
    }
}

async fn download_funding_report(
    pool: &PgPool,
    report_id: Uuid,
    query: &Query,
) -> Result<Value, ServiceError> {
    let format = FundingDownloadFormat::parse(query)?;
    let row = sqlx::query_as::<_, FundingReportRow>(
        "SELECT report.id,report.period_start,report.period_end,report.title,report.summary,\
         report.report,report.published_at,report.report_kind,\
         source_revision_id,source_disclosure_id,source_revision,source_revision_digest,\
         supersedes_report_id,report_schema_version,projection_digest,projected_at,\
         CASE WHEN report.source_revision=1 THEN report.supersedes_report_id IS NULL \
         ELSE EXISTS(SELECT 1 FROM public.transparency_reports AS predecessor \
         WHERE predecessor.id=report.supersedes_report_id \
         AND predecessor.report_kind='FUNDING_DISCLOSURE' \
         AND predecessor.source_disclosure_id=report.source_disclosure_id \
         AND predecessor.source_revision=report.source_revision-1) \
         END AS supersedes_binding_valid \
         FROM public.transparency_reports AS report WHERE report.id=$1",
    )
    .bind(report_id)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    render_funding_report_download(&verify_ready_funding_report(row)?, format)
}

fn ensure_funding_report_kind(row: &FundingReportRow) -> Result<(), ServiceError> {
    if row.report_kind == FUNDING_REPORT_KIND {
        Ok(())
    } else {
        Err(ServiceError::ReportPreconditionFailed)
    }
}

fn verify_ready_funding_report(
    row: FundingReportRow,
) -> Result<VerifiedFundingReport, ServiceError> {
    ensure_funding_report_kind(&row)?;
    verify_funding_report(row).map_err(|error| match error {
        ServiceError::Persistence => ServiceError::ReportPreconditionFailed,
        other => other,
    })
}

fn verify_funding_report(row: FundingReportRow) -> Result<VerifiedFundingReport, ServiceError> {
    let source_revision_id = row.source_revision_id.ok_or(ServiceError::Persistence)?;
    let source_disclosure_id = row.source_disclosure_id.ok_or(ServiceError::Persistence)?;
    let source_revision = row.source_revision.ok_or(ServiceError::Persistence)?;
    let source_revision_digest = row
        .source_revision_digest
        .as_deref()
        .map(str::trim)
        .filter(|value| funding_sha256(value))
        .ok_or(ServiceError::Persistence)?
        .to_owned();
    let projection_digest = row
        .projection_digest
        .as_deref()
        .map(str::trim)
        .filter(|value| funding_sha256(value))
        .ok_or(ServiceError::Persistence)?
        .to_owned();
    let projected_at = row.projected_at.ok_or(ServiceError::Persistence)?;
    if row.report_kind != FUNDING_REPORT_KIND
        || row.report_schema_version != Some(FUNDING_REPORT_SCHEMA_VERSION)
        || !row.supersedes_binding_valid
        || source_revision <= 0
        || row.period_start >= row.period_end
        || row.title.trim().is_empty()
        || row.summary.trim().is_empty()
        || row.published_at > projected_at
        || !exact_object_keys(&row.report, FUNDING_REPORT_FIELDS)
    {
        return Err(ServiceError::Persistence);
    }
    let disclosure: FundingDisclosurePublicV1 =
        serde_json::from_value(row.report.clone()).map_err(|_| ServiceError::Persistence)?;
    validate_disclosure(&disclosure)?;
    if disclosure.schema_version != FUNDING_REPORT_SCHEMA_VERSION
        || disclosure.disclosure_id != source_disclosure_id
        || disclosure.revision != source_revision
        || disclosure.source_revision_digest != source_revision_digest
        || disclosure.period_start != row.period_start.to_string()
        || disclosure.period_end != row.period_end.to_string()
        || parse_timestamp(&disclosure.published_at)? != row.published_at
    {
        return Err(ServiceError::Persistence);
    }
    // The inner funding digests remain opaque bindings: their private preimages
    // are deliberately absent from the public row and 0029 does not approve an
    // executable framing for them.  The specified outer projection digest binds
    // the entire closed public report and is the only digest recomputed here.
    let expected_projection_digest = funding_projection_digest(
        &row,
        source_revision_id,
        source_disclosure_id,
        source_revision,
        &source_revision_digest,
    )?;
    if expected_projection_digest != projection_digest {
        return Err(ServiceError::Persistence);
    }
    Ok(VerifiedFundingReport {
        row,
        disclosure,
        source_revision_digest,
        projection_digest,
        projected_at,
    })
}

include!("public_funding_validation.rs");

fn funding_projection_digest(
    row: &FundingReportRow,
    source_revision_id: Uuid,
    source_disclosure_id: Uuid,
    source_revision: i64,
    source_revision_digest: &str,
) -> Result<String, ServiceError> {
    let preimage = json!({
        "reportKind": row.report_kind,
        "sourceRevisionId": source_revision_id,
        "sourceDisclosureId": source_disclosure_id,
        "sourceRevision": source_revision,
        "sourceRevisionDigest": source_revision_digest,
        "periodStart": row.period_start.to_string(),
        "periodEnd": row.period_end.to_string(),
        "title": row.title,
        "summary": row.summary,
        "report": row.report,
        "publishedAt": timestamp(row.published_at)?,
        "supersedesReportId": row.supersedes_report_id,
    });
    Ok(hex(&Sha256::digest(canonical_json_bytes(&preimage)?)))
}

include!("public_funding_render.rs");

#[cfg(test)]
include!("public_funding_tests.rs");
