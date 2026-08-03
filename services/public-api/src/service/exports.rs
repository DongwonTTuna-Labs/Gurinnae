const EXPORT_ROW_LIMIT: usize = 5_000;
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PublicExportFormat {
    Csv,
    Jsonl,
}

impl PublicExportFormat {
    fn parse(query: &Query) -> Result<Self, ServiceError> {
        match query.first("format") {
            Some("CSV") => Ok(Self::Csv),
            Some("JSONL") => Ok(Self::Jsonl),
            _ => Err(ServiceError::InvalidRequest),
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::Csv => "CSV",
            Self::Jsonl => "JSONL",
        }
    }

    fn extension(self) -> &'static str {
        match self {
            Self::Csv => "csv",
            Self::Jsonl => "jsonl",
        }
    }

    fn media_type(self) -> &'static str {
        match self {
            Self::Csv => "text/csv; charset=utf-8",
            Self::Jsonl => "application/x-ndjson; charset=utf-8",
        }
    }
}

async fn download_public_cases(pool: &PgPool, query: &Query) -> Result<Value, ServiceError> {
    let format = PublicExportFormat::parse(query)?;
    let filters = case_filters(query, None)?;
    let rows = sqlx::query_as!(
        CaseCardRow,
        "SELECT c.slug,c.title,c.public_state,c.summary,c.latest_revision,c.updated_at,CASE WHEN jsonb_path_exists(r.payload,'$.responses[*]') OR jsonb_path_exists(r.payload,'$.partyResponses[*]') THEN 'RECEIVED'::text END AS \"response_status?\",CASE WHEN EXISTS(SELECT 1 FROM public.corrections x WHERE x.case_id=c.id) THEN 'PUBLISHED'::text END AS \"correction_status?\",r.payload AS \"payload!\" FROM public.cases c JOIN public.case_revisions r ON r.case_id=c.id AND r.revision=c.latest_revision WHERE (cardinality($1::text[])=0 OR c.public_state=ANY($1)) AND ($2::text IS NULL OR r.payload->>'agencyId'=$2 OR COALESCE(r.payload->'agencyIds','[]'::jsonb) ? $2) AND ($3::text IS NULL OR r.payload->>'supplierId'=$3 OR COALESCE(r.payload->'supplierIds','[]'::jsonb) ? $3) AND ($4::text IS NULL OR r.payload->>'ruleId'=$4 OR COALESCE(r.payload->'ruleIds','[]'::jsonb) ? $4) AND ($5::date IS NULL OR c.published_at::date >= $5) AND ($6::date IS NULL OR c.published_at::date <= $6) AND ($7::boolean IS NULL OR (jsonb_path_exists(r.payload,'$.responses[*]') OR jsonb_path_exists(r.payload,'$.partyResponses[*]'))=$7) AND ($8::boolean IS NULL OR EXISTS(SELECT 1 FROM public.corrections x WHERE x.case_id=c.id)=$8) AND (($9::text IS NULL AND $10::text IS NULL) OR EXISTS(SELECT 1 FROM public.agencies a WHERE r.payload->>'agencyId'=a.id::text AND ($9::text IS NULL OR btrim(a.sido_code::text)=$9) AND ($10::text IS NULL OR btrim(a.sigungu_code::text)=$10))) ORDER BY CASE WHEN $11='updated_desc' THEN c.updated_at END DESC,CASE WHEN $11='created_asc' THEN c.published_at END ASC,CASE WHEN $11='published_desc' THEN c.published_at END DESC,CASE WHEN $11='title_asc' THEN c.title END ASC,c.id LIMIT 5001",
        &filters.states,
        &filters.agency as _,
        &filters.supplier as _,
        &filters.rule as _,
        filters.published_from,
        filters.published_to,
        filters.has_response,
        filters.has_correction,
        &filters.sido_code as _,
        &filters.sigungu_code as _,
        &filters.sort,
    )
    .fetch_all(pool)
    .await
    .map_err(db)?;
    enforce_export_limit(rows.len())?;
    let values = rows
        .into_iter()
        .map(case_card)
        .collect::<Result<Vec<_>, _>>()?;
    let mut applied_filters = case_applied_filters(query, None, &filters.states)?;
    applied_filters["sort"] = json!(filters.sort);
    render_export(
        "public-cases",
        format,
        &CASE_EXPORT_COLUMNS,
        &values,
        applied_filters,
    )
}

async fn download_public_search_records(
    pool: &PgPool,
    query: &Query,
) -> Result<Value, ServiceError> {
    let format = PublicExportFormat::parse(query)?;
    let filters = search_filters(query)?;
    let rows = search_export_rows(pool, &filters).await?;
    enforce_export_limit(rows.len())?;
    let values = rows
        .into_iter()
        .map(search_export_value)
        .collect::<Result<Vec<_>, _>>()?;
    let mut applied_filters = search_applied_filters(query, &filters);
    applied_filters["sort"] = json!(filters.sort);
    render_export(
        "public-search-records",
        format,
        &SEARCH_EXPORT_COLUMNS,
        &values,
        applied_filters,
    )
}

struct SearchExportRow {
    result_type: String,
    id: String,
    title: String,
    subtitle: Option<String>,
    status: Option<String>,
    summary: Option<String>,
    updated_at: Option<OffsetDateTime>,
    href: String,
    notice_payload: Option<Value>,
}

async fn search_export_rows(
    pool: &PgPool,
    filters: &SearchFilters,
) -> Result<Vec<SearchExportRow>, ServiceError> {
    sqlx::query_as!(
        SearchExportRow,
        "SELECT result_type AS \"result_type!\",id AS \"id!\",title AS \"title!\",subtitle,status,summary,updated_at,href AS \"href!\",notice_payload FROM (\
         SELECT 'CASE'::text result_type,c.id::text,c.title,c.slug subtitle,c.public_state status,c.summary,c.updated_at,'/cases/'||c.slug href,r.payload notice_payload FROM public.cases c JOIN public.case_revisions r ON r.case_id=c.id AND r.revision=c.latest_revision WHERE (c.title ILIKE $1 OR c.summary ILIKE $1) AND (cardinality($2::text[])=0 OR 'CASE'=ANY($2)) AND (cardinality($3::text[])=0 OR c.public_state=ANY($3)) AND ($4::date IS NULL OR c.updated_at::date >= $4) AND ($5::date IS NULL OR c.updated_at::date <= $5) AND ($6::uuid IS NULL OR r.payload->>'agencyId'=$6::text OR COALESCE(r.payload->'agencyIds','[]'::jsonb) ? $6::text) AND (($7::text IS NULL AND $8::text IS NULL) OR EXISTS(SELECT 1 FROM public.agencies a WHERE r.payload->>'agencyId'=a.id::text AND ($7::text IS NULL OR btrim(a.sido_code::text)=$7) AND ($8::text IS NULL OR btrim(a.sigungu_code::text)=$8))) \
         UNION ALL SELECT 'AGENCY',a.id::text,a.name,a.jurisdiction,a.agency_type,NULL,a.updated_at,'/agencies/'||a.id::text,NULL::jsonb FROM public.agencies a WHERE a.name IS NOT NULL AND a.name ILIKE $1 AND (cardinality($2::text[])=0 OR 'AGENCY'=ANY($2)) AND cardinality($3::text[])=0 AND ($4::date IS NULL OR a.updated_at::date >= $4) AND ($5::date IS NULL OR a.updated_at::date <= $5) AND ($6::uuid IS NULL OR a.id=$6) AND ($7::text IS NULL OR btrim(a.sido_code::text)=$7) AND ($8::text IS NULL OR btrim(a.sigungu_code::text)=$8) \
         UNION ALL SELECT 'SUPPLIER',id::text,name,business_status,business_status,NULL,updated_at,'/suppliers/'||id::text,NULL::jsonb FROM public.suppliers WHERE name IS NOT NULL AND name ILIKE $1 AND (cardinality($2::text[])=0 OR 'SUPPLIER'=ANY($2)) AND cardinality($3::text[])=0 AND ($4::date IS NULL OR updated_at::date >= $4) AND ($5::date IS NULL OR updated_at::date <= $5) AND $6::uuid IS NULL AND $7::text IS NULL AND $8::text IS NULL \
         UNION ALL SELECT 'CONTRACT',c.id::text,c.title,c.contract_number,c.status,NULL,c.updated_at,'/contracts/'||c.id::text,NULL::jsonb FROM public.contracts c LEFT JOIN public.agencies a ON a.id=c.agency_id WHERE (c.title ILIKE $1 OR c.contract_number ILIKE $1) AND (cardinality($2::text[])=0 OR 'CONTRACT'=ANY($2)) AND cardinality($3::text[])=0 AND ($4::date IS NULL OR c.updated_at::date >= $4) AND ($5::date IS NULL OR c.updated_at::date <= $5) AND ($6::uuid IS NULL OR c.agency_id=$6) AND ($7::text IS NULL OR btrim(a.sido_code::text)=$7) AND ($8::text IS NULL OR btrim(a.sigungu_code::text)=$8) \
         UNION ALL SELECT 'RULE',rule_id,name,active_version,'ACTIVE',public_description,updated_at,'/methodology/rules/'||rule_id,NULL::jsonb FROM public.rules WHERE (name ILIKE $1 OR public_description ILIKE $1) AND (cardinality($2::text[])=0 OR 'RULE'=ANY($2)) AND cardinality($3::text[])=0 AND ($4::date IS NULL OR updated_at::date >= $4) AND ($5::date IS NULL OR updated_at::date <= $5) AND $6::uuid IS NULL AND $7::text IS NULL AND $8::text IS NULL \
         UNION ALL SELECT 'CORRECTION',x.id::text,x.summary,c.slug,c.public_state,x.reason,x.published_at,'/corrections/'||x.id::text,r.payload FROM public.corrections x JOIN public.cases c ON c.id=x.case_id JOIN public.case_revisions r ON r.case_id=c.id AND r.revision=c.latest_revision WHERE (x.summary ILIKE $1 OR x.reason ILIKE $1) AND (cardinality($2::text[])=0 OR 'CORRECTION'=ANY($2)) AND (cardinality($3::text[])=0 OR c.public_state=ANY($3)) AND ($4::date IS NULL OR x.published_at::date >= $4) AND ($5::date IS NULL OR x.published_at::date <= $5) AND ($6::uuid IS NULL OR r.payload->>'agencyId'=$6::text OR COALESCE(r.payload->'agencyIds','[]'::jsonb) ? $6::text) AND (($7::text IS NULL AND $8::text IS NULL) OR EXISTS(SELECT 1 FROM public.agencies a WHERE r.payload->>'agencyId'=a.id::text AND ($7::text IS NULL OR btrim(a.sido_code::text)=$7) AND ($8::text IS NULL OR btrim(a.sigungu_code::text)=$8))) \
         UNION ALL SELECT 'DATASET',id,title,format,'PUBLISHED',description,updated_at,'/data',NULL::jsonb FROM public.datasets WHERE (title ILIKE $1 OR description ILIKE $1) AND (cardinality($2::text[])=0 OR 'DATASET'=ANY($2)) AND cardinality($3::text[])=0 AND ($4::date IS NULL OR updated_at::date >= $4) AND ($5::date IS NULL OR updated_at::date <= $5) AND $6::uuid IS NULL AND $7::text IS NULL AND $8::text IS NULL \
         UNION ALL SELECT 'SOURCE',source_id,display_name,status,status,public_message,updated_at,'/sources/'||source_id,NULL::jsonb FROM public.source_status WHERE (display_name ILIKE $1 OR source_id ILIKE $1 OR public_message ILIKE $1) AND (cardinality($2::text[])=0 OR 'SOURCE'=ANY($2)) AND cardinality($3::text[])=0 AND ($4::date IS NULL OR updated_at::date >= $4) AND ($5::date IS NULL OR updated_at::date <= $5) AND $6::uuid IS NULL AND $7::text IS NULL AND $8::text IS NULL\
         ) x ORDER BY CASE WHEN $9='relevance' THEN (title ILIKE $1) END DESC,CASE WHEN $9 IN ('relevance','updated_desc') THEN updated_at END DESC NULLS LAST,CASE WHEN $9='title_asc' THEN title END ASC,id LIMIT 5001",
        &filters.pattern,
        &filters.types,
        &filters.states,
        filters.date_from,
        filters.date_to,
        filters.agency_id,
        &filters.sido_code as _,
        &filters.sigungu_code as _,
        &filters.sort,
    )
    .fetch_all(pool)
    .await
    .map_err(db)
}

fn search_export_value(row: SearchExportRow) -> Result<Value, ServiceError> {
    let (non_conclusion, interpretation_notice) = search_result_notices(
        &row.result_type,
        row.status.as_deref(),
        row.notice_payload.as_ref().and_then(Value::as_object),
    )?;
    let mut value = Map::new();
    value.insert("resultType".into(), json!(row.result_type));
    value.insert("id".into(), json!(row.id));
    value.insert("title".into(), json!(row.title));
    value.insert("href".into(), json!(row.href));
    for (key, optional) in [
        ("subtitle", row.subtitle),
        ("status", row.status),
        ("summary", row.summary),
    ] {
        if let Some(item) = optional {
            value.insert(key.into(), json!(item));
        }
    }
    if let Some(updated_at) = row.updated_at {
        value.insert("updatedAt".into(), json!(timestamp(updated_at)?));
    }
    value.insert("nonConclusion".into(), json!(non_conclusion));
    value.insert("interpretationNotice".into(), json!(interpretation_notice));
    Ok(Value::Object(value))
}

fn search_applied_filters(query: &Query, filters: &SearchFilters) -> Value {
    let mut applied = Map::new();
    applied.insert("q".into(), json!(filters.q));
    applied.insert("types".into(), json!(filters.types));
    applied.insert("publicationState".into(), json!(filters.states));
    for name in ["agencyId", "sidoCode", "sigunguCode", "dateFrom", "dateTo"] {
        if let Some(value) = query.first(name) {
            applied.insert(name.into(), json!(value));
        }
    }
    Value::Object(applied)
}

const CASE_EXPORT_COLUMNS: [(&str, &str); 10] = [
    ("slug", "slug"),
    ("title", "title"),
    ("publicState", "publicState"),
    ("summary", "summary"),
    ("revision", "revision"),
    ("updatedAt", "updatedAt"),
    ("responseStatus", "responseStatus"),
    ("correctionStatus", "correctionStatus"),
    ("nonConclusion", "nonConclusion"),
    ("href", "href"),
];

const SEARCH_EXPORT_COLUMNS: [(&str, &str); 10] = [
    ("resultType", "resultType"),
    ("id", "id"),
    ("title", "title"),
    ("subtitle", "subtitle"),
    ("status", "status"),
    ("summary", "summary"),
    ("nonConclusion", "nonConclusion"),
    ("interpretationNotice", "interpretationNotice"),
    ("updatedAt", "updatedAt"),
    ("href", "href"),
];

fn enforce_export_limit(count: usize) -> Result<(), ServiceError> {
    if count > EXPORT_ROW_LIMIT {
        Err(ServiceError::PreconditionFailed)
    } else {
        Ok(())
    }
}

fn render_export(
    stem: &str,
    format: PublicExportFormat,
    columns: &[(&str, &str)],
    rows: &[Value],
    applied_filters: Value,
) -> Result<Value, ServiceError> {
    let envelope_notices = export_envelope_notices(stem, rows)?;
    let bytes = match format {
        PublicExportFormat::Csv => render_csv(columns, rows),
        PublicExportFormat::Jsonl => render_jsonl(rows)?,
    };
    let mut download = render_download_bytes(
        stem,
        format.label(),
        format.extension(),
        format.media_type(),
        bytes,
        rows.len(),
        applied_filters,
    )?;
    let object = download.as_object_mut().ok_or(ServiceError::Persistence)?;
    object.insert(
        "nonConclusionNotices".into(),
        json!(envelope_notices.non_conclusion_notices),
    );
    object.insert(
        "interpretationNotice".into(),
        json!(envelope_notices.interpretation_notice),
    );
    Ok(download)
}

include!("public_export_notices.rs");

fn render_download_bytes(
    stem: &str,
    format: &str,
    extension: &str,
    media_type: &str,
    bytes: Vec<u8>,
    row_count: usize,
    applied_filters: Value,
) -> Result<Value, ServiceError> {
    if !artifact_contains_redistribution_notice(format, &bytes) {
        return Err(ServiceError::Persistence);
    }
    let digest = hex(&Sha256::digest(&bytes));
    Ok(json!({
        "id": format!("{stem}-{digest}"),
        "status": "READY",
        "version": 1,
        "notice": PUBLIC_REDISTRIBUTION_NOTICE,
        "filename": format!("{stem}.{extension}"),
        "mediaType": media_type,
        "byteLength": bytes.len(),
        "contentSha256": digest,
        "contentBase64": base64::engine::general_purpose::STANDARD.encode(&bytes),
        "format": format,
        "rowCount": row_count,
        "appliedFilters": applied_filters,
        "generatedAt": now()?,
    }))
}

fn artifact_contains_redistribution_notice(format: &str, bytes: &[u8]) -> bool {
    match format {
        "CSV" => bytes.starts_with(format!("{PUBLIC_REDISTRIBUTION_NOTICE}\r\n").as_bytes()),
        "JSON" => serde_json::from_slice::<Value>(bytes)
            .map(|value| {
                value.get("notice").and_then(Value::as_str) == Some(PUBLIC_REDISTRIBUTION_NOTICE)
            })
            .unwrap_or(false),
        "JSONL" => bytes
            .split(|byte| *byte == b'\n')
            .next()
            .and_then(|line| serde_json::from_slice::<Value>(line).ok())
            .map(|value| {
                value.get("notice").and_then(Value::as_str) == Some(PUBLIC_REDISTRIBUTION_NOTICE)
            })
            .unwrap_or(false),
        _ => false,
    }
}

fn render_csv(columns: &[(&str, &str)], rows: &[Value]) -> Vec<u8> {
    let mut output = String::new();
    output.push_str(&csv_cell(PUBLIC_REDISTRIBUTION_NOTICE));
    output.push_str("\r\n");
    output.push_str(
        &columns
            .iter()
            .map(|(_, heading)| csv_cell(heading))
            .collect::<Vec<_>>()
            .join(","),
    );
    output.push_str("\r\n");
    for row in rows {
        output.push_str(
            &columns
                .iter()
                .map(|(key, _)| csv_cell(&export_scalar(row.get(*key))))
                .collect::<Vec<_>>()
                .join(","),
        );
        output.push_str("\r\n");
    }
    output.into_bytes()
}

fn render_jsonl(rows: &[Value]) -> Result<Vec<u8>, ServiceError> {
    let mut bytes = Vec::new();
    for row in std::iter::once(&json!({"notice": PUBLIC_REDISTRIBUTION_NOTICE})).chain(rows) {
        serde_json::to_writer(&mut bytes, row).map_err(|_| ServiceError::Persistence)?;
        bytes.push(b'\n');
    }
    Ok(bytes)
}

fn export_scalar(value: Option<&Value>) -> String {
    match value {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(value)) => value.clone(),
        Some(Value::Bool(value)) => value.to_string(),
        Some(Value::Number(value)) => value.to_string(),
        Some(value) => value.to_string(),
    }
}

fn csv_cell(value: &str) -> String {
    if value.contains([',', '"', '\r', '\n']) {
        format!("\"{}\"", value.replace('"', "\"\""))
    } else {
        value.to_owned()
    }
}

#[cfg(test)]
include!("exports_tests.rs");
