const EXPORT_ROW_LIMIT: usize = 5_000;
const EXPORT_NOTICE: &str = "이상 징후 기록이며 위법·부패의 확정이 아님";

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
        "SELECT c.slug,c.title,c.public_state,c.summary,c.latest_revision,c.updated_at,CASE WHEN jsonb_path_exists(r.payload,'$.responses[*]') OR jsonb_path_exists(r.payload,'$.partyResponses[*]') THEN 'RECEIVED'::text END AS \"response_status?\",CASE WHEN EXISTS(SELECT 1 FROM public.corrections x WHERE x.case_id=c.id) THEN 'PUBLISHED'::text END AS \"correction_status?\" FROM public.cases c JOIN public.case_revisions r ON r.case_id=c.id AND r.revision=c.latest_revision WHERE (cardinality($1::text[])=0 OR c.public_state=ANY($1)) AND ($2::text IS NULL OR r.payload->>'agencyId'=$2 OR COALESCE(r.payload->'agencyIds','[]'::jsonb) ? $2) AND ($3::text IS NULL OR r.payload->>'supplierId'=$3 OR COALESCE(r.payload->'supplierIds','[]'::jsonb) ? $3) AND ($4::text IS NULL OR r.payload->>'ruleId'=$4 OR COALESCE(r.payload->'ruleIds','[]'::jsonb) ? $4) AND ($5::date IS NULL OR c.published_at::date >= $5) AND ($6::date IS NULL OR c.published_at::date <= $6) AND ($7::boolean IS NULL OR (jsonb_path_exists(r.payload,'$.responses[*]') OR jsonb_path_exists(r.payload,'$.partyResponses[*]'))=$7) AND ($8::boolean IS NULL OR EXISTS(SELECT 1 FROM public.corrections x WHERE x.case_id=c.id)=$8) AND (($9::text IS NULL AND $10::text IS NULL) OR EXISTS(SELECT 1 FROM public.agencies a WHERE r.payload->>'agencyId'=a.id::text AND ($9::text IS NULL OR btrim(a.sido_code::text)=$9) AND ($10::text IS NULL OR btrim(a.sigungu_code::text)=$10))) ORDER BY CASE WHEN $11='updated_desc' THEN c.updated_at END DESC,CASE WHEN $11='created_asc' THEN c.published_at END ASC,CASE WHEN $11='published_desc' THEN c.published_at END DESC,CASE WHEN $11='title_asc' THEN c.title END ASC,c.id LIMIT 5001",
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
}

async fn search_export_rows(
    pool: &PgPool,
    filters: &SearchFilters,
) -> Result<Vec<SearchExportRow>, ServiceError> {
    sqlx::query_as!(
        SearchExportRow,
        "SELECT result_type AS \"result_type!\",id AS \"id!\",title AS \"title!\",subtitle,status,summary,updated_at,href AS \"href!\" FROM (\
         SELECT 'CASE'::text result_type,c.id::text,c.title,c.slug subtitle,c.public_state status,c.summary,c.updated_at,'/cases/'||c.slug href FROM public.cases c JOIN public.case_revisions r ON r.case_id=c.id AND r.revision=c.latest_revision WHERE (c.title ILIKE $1 OR c.summary ILIKE $1) AND (cardinality($2::text[])=0 OR 'CASE'=ANY($2)) AND (cardinality($3::text[])=0 OR c.public_state=ANY($3)) AND ($4::date IS NULL OR c.updated_at::date >= $4) AND ($5::date IS NULL OR c.updated_at::date <= $5) AND ($6::uuid IS NULL OR r.payload->>'agencyId'=$6::text OR COALESCE(r.payload->'agencyIds','[]'::jsonb) ? $6::text) AND (($7::text IS NULL AND $8::text IS NULL) OR EXISTS(SELECT 1 FROM public.agencies a WHERE r.payload->>'agencyId'=a.id::text AND ($7::text IS NULL OR btrim(a.sido_code::text)=$7) AND ($8::text IS NULL OR btrim(a.sigungu_code::text)=$8))) \
         UNION ALL SELECT 'AGENCY',a.id::text,a.name,a.jurisdiction,a.agency_type,NULL,a.updated_at,'/agencies/'||a.id::text FROM public.agencies a WHERE a.name ILIKE $1 AND (cardinality($2::text[])=0 OR 'AGENCY'=ANY($2)) AND cardinality($3::text[])=0 AND ($4::date IS NULL OR a.updated_at::date >= $4) AND ($5::date IS NULL OR a.updated_at::date <= $5) AND ($6::uuid IS NULL OR a.id=$6) AND ($7::text IS NULL OR btrim(a.sido_code::text)=$7) AND ($8::text IS NULL OR btrim(a.sigungu_code::text)=$8) \
         UNION ALL SELECT 'SUPPLIER',id::text,name,business_status,business_status,NULL,updated_at,'/suppliers/'||id::text FROM public.suppliers WHERE name ILIKE $1 AND (cardinality($2::text[])=0 OR 'SUPPLIER'=ANY($2)) AND cardinality($3::text[])=0 AND ($4::date IS NULL OR updated_at::date >= $4) AND ($5::date IS NULL OR updated_at::date <= $5) AND $6::uuid IS NULL AND $7::text IS NULL AND $8::text IS NULL \
         UNION ALL SELECT 'CONTRACT',c.id::text,c.title,c.contract_number,c.status,NULL,c.updated_at,'/contracts/'||c.id::text FROM public.contracts c LEFT JOIN public.agencies a ON a.id=c.agency_id WHERE (c.title ILIKE $1 OR c.contract_number ILIKE $1) AND (cardinality($2::text[])=0 OR 'CONTRACT'=ANY($2)) AND cardinality($3::text[])=0 AND ($4::date IS NULL OR c.updated_at::date >= $4) AND ($5::date IS NULL OR c.updated_at::date <= $5) AND ($6::uuid IS NULL OR c.agency_id=$6) AND ($7::text IS NULL OR btrim(a.sido_code::text)=$7) AND ($8::text IS NULL OR btrim(a.sigungu_code::text)=$8) \
         UNION ALL SELECT 'RULE',rule_id,name,active_version,'ACTIVE',public_description,updated_at,'/methodology/rules/'||rule_id FROM public.rules WHERE (name ILIKE $1 OR public_description ILIKE $1) AND (cardinality($2::text[])=0 OR 'RULE'=ANY($2)) AND cardinality($3::text[])=0 AND ($4::date IS NULL OR updated_at::date >= $4) AND ($5::date IS NULL OR updated_at::date <= $5) AND $6::uuid IS NULL AND $7::text IS NULL AND $8::text IS NULL \
         UNION ALL SELECT 'CORRECTION',x.id::text,x.summary,c.slug,c.public_state,x.reason,x.published_at,'/corrections/'||x.id::text FROM public.corrections x JOIN public.cases c ON c.id=x.case_id JOIN public.case_revisions r ON r.case_id=c.id AND r.revision=c.latest_revision WHERE (x.summary ILIKE $1 OR x.reason ILIKE $1) AND (cardinality($2::text[])=0 OR 'CORRECTION'=ANY($2)) AND (cardinality($3::text[])=0 OR c.public_state=ANY($3)) AND ($4::date IS NULL OR x.published_at::date >= $4) AND ($5::date IS NULL OR x.published_at::date <= $5) AND ($6::uuid IS NULL OR r.payload->>'agencyId'=$6::text OR COALESCE(r.payload->'agencyIds','[]'::jsonb) ? $6::text) AND (($7::text IS NULL AND $8::text IS NULL) OR EXISTS(SELECT 1 FROM public.agencies a WHERE r.payload->>'agencyId'=a.id::text AND ($7::text IS NULL OR btrim(a.sido_code::text)=$7) AND ($8::text IS NULL OR btrim(a.sigungu_code::text)=$8))) \
         UNION ALL SELECT 'DATASET',id,title,format,'PUBLISHED',description,updated_at,'/data' FROM public.datasets WHERE (title ILIKE $1 OR description ILIKE $1) AND (cardinality($2::text[])=0 OR 'DATASET'=ANY($2)) AND cardinality($3::text[])=0 AND ($4::date IS NULL OR updated_at::date >= $4) AND ($5::date IS NULL OR updated_at::date <= $5) AND $6::uuid IS NULL AND $7::text IS NULL AND $8::text IS NULL \
         UNION ALL SELECT 'SOURCE',source_id,display_name,status,status,public_message,updated_at,'/sources/'||source_id FROM public.source_status WHERE (display_name ILIKE $1 OR source_id ILIKE $1 OR public_message ILIKE $1) AND (cardinality($2::text[])=0 OR 'SOURCE'=ANY($2)) AND cardinality($3::text[])=0 AND ($4::date IS NULL OR updated_at::date >= $4) AND ($5::date IS NULL OR updated_at::date <= $5) AND $6::uuid IS NULL AND $7::text IS NULL AND $8::text IS NULL\
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

const CASE_EXPORT_COLUMNS: [(&str, &str); 9] = [
    ("slug", "slug"),
    ("title", "title"),
    ("publicState", "publicState"),
    ("summary", "summary"),
    ("revision", "revision"),
    ("updatedAt", "updatedAt"),
    ("responseStatus", "responseStatus"),
    ("correctionStatus", "correctionStatus"),
    ("href", "href"),
];

const SEARCH_EXPORT_COLUMNS: [(&str, &str); 8] = [
    ("resultType", "resultType"),
    ("id", "id"),
    ("title", "title"),
    ("subtitle", "subtitle"),
    ("status", "status"),
    ("summary", "summary"),
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
    let bytes = match format {
        PublicExportFormat::Csv => render_csv(columns, rows),
        PublicExportFormat::Jsonl => render_jsonl(rows)?,
    };
    let digest = hex(&Sha256::digest(&bytes));
    Ok(json!({
        "id": format!("{stem}-{digest}"),
        "status": "READY",
        "version": 1,
        "filename": format!("{stem}.{}", format.extension()),
        "mediaType": format.media_type(),
        "byteLength": bytes.len(),
        "contentSha256": digest,
        "contentBase64": base64::engine::general_purpose::STANDARD.encode(&bytes),
        "format": format.label(),
        "rowCount": rows.len(),
        "appliedFilters": applied_filters,
        "generatedAt": now()?,
    }))
}

fn render_csv(columns: &[(&str, &str)], rows: &[Value]) -> Vec<u8> {
    let mut output = String::new();
    output.push_str(&csv_cell(EXPORT_NOTICE));
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
    for row in std::iter::once(&json!({"notice": EXPORT_NOTICE})).chain(rows) {
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
mod export_tests {
    use super::*;

    #[test]
    fn region_binding_excludes_array_only_and_missing_scalar_agencies() {
        let matching_agency = "11111111-1111-4111-8111-111111111111";
        let other_agency = "22222222-2222-4222-8222-222222222222";
        let scalar_agency = |payload: &Value| {
            payload
                .get("agencyId")
                .and_then(Value::as_str)
                .map(str::to_owned)
        };

        assert_eq!(
            scalar_agency(&json!({
                "agencyId": matching_agency,
                "agencyIds": [other_agency]
            })),
            Some(matching_agency.to_owned())
        );
        assert_eq!(
            scalar_agency(&json!({"agencyIds": [matching_agency, other_agency]})),
            None
        );
        assert_eq!(scalar_agency(&json!({})), None);
        assert_ne!(
            scalar_agency(&json!({
                "agencyId": other_agency,
                "agencyIds": [matching_agency]
            }))
            .as_deref(),
            Some(matching_agency)
        );

        let source = [include_str!("cases.rs"), include_str!("exports.rs")].concat();
        let scalar_region_predicate = [
            "EXISTS(SELECT 1 FROM public.agencies a WHERE r.payload->>'agency",
            "Id'=a.id::text AND",
        ]
        .concat();
        let legacy_array_region_predicate = [
            "EXISTS(SELECT 1 FROM public.agencies a WHERE (r.payload->>'agency",
            "Id'=a.id::text OR ",
            "COALESCE(r.payload->'agencyIds','[]'::jsonb) ? a.id::text)",
        ]
        .concat();
        assert_eq!(source.matches(&scalar_region_predicate).count(), 6);
        assert!(!source.contains(&legacy_array_region_predicate));
    }

    #[test]
    fn export_limit_is_inclusive_and_fails_closed_above_cap() {
        assert!(enforce_export_limit(5_000).is_ok());
        assert!(matches!(
            enforce_export_limit(5_001),
            Err(ServiceError::PreconditionFailed)
        ));
    }

    #[test]
    fn csv_is_crlf_delimited_and_escapes_each_logical_cell() {
        let rows = [json!({"title":"쉼표, 따옴표 \"와\"\n줄바꿈","count":2})];
        let bytes = render_csv(&[("title", "title"), ("count", "count")], &rows);
        let rendered = String::from_utf8(bytes).expect("CSV is UTF-8");
        assert_eq!(
            rendered,
            concat!(
                "이상 징후 기록이며 위법·부패의 확정이 아님\r\n",
                "title,count\r\n",
                "\"쉼표, 따옴표 \"\"와\"\"\n줄바꿈\",2\r\n"
            )
        );
    }

    #[test]
    fn jsonl_starts_with_notice_and_keeps_one_object_per_line() {
        let rows = [json!({"id":"case-1"}), json!({"id":"case-2"})];
        let bytes = render_jsonl(&rows).expect("JSONL renders");
        let lines = std::str::from_utf8(&bytes)
            .expect("JSONL is UTF-8")
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).expect("valid JSON object"))
            .collect::<Vec<_>>();
        assert_eq!(lines.len(), 3);
        assert_eq!(lines[0], json!({"notice": EXPORT_NOTICE}));
        assert_eq!(lines[2], rows[1]);
    }

    #[test]
    fn response_has_exact_fields_and_digest_covers_file_bytes() {
        let response = render_export(
            "public-cases",
            PublicExportFormat::Jsonl,
            &CASE_EXPORT_COLUMNS,
            &[json!({"slug":"case-1"})],
            json!({"sort":"updated_desc"}),
        )
        .expect("export response");
        let object = response.as_object().expect("response object");
        assert_eq!(object.len(), 12);
        let content = base64::engine::general_purpose::STANDARD
            .decode(
                response
                    .get("contentBase64")
                    .and_then(Value::as_str)
                    .expect("base64 content"),
            )
            .expect("valid base64");
        assert_eq!(response["byteLength"], content.len());
        assert_eq!(response["contentSha256"], hex(&Sha256::digest(&content)));
        assert_eq!(response["rowCount"], 1);
    }
}
