struct CaseCardRow {
    slug: String,
    title: String,
    public_state: String,
    summary: String,
    latest_revision: i32,
    updated_at: OffsetDateTime,
    response_status: Option<String>,
    correction_status: Option<String>,
    payload: Value,
}

fn case_card(row: CaseCardRow) -> Result<Value, ServiceError> {
    let CaseCardRow {
        slug,
        title,
        public_state,
        summary,
        latest_revision,
        updated_at,
        response_status,
        correction_status,
        payload,
    } = row;
    let authority = payload.as_object().ok_or(ServiceError::Persistence)?;
    Ok(json!({
        "slug": slug,
        "title": title,
        "publicState": public_state,
        "summary": summary,
        "revision": latest_revision,
        "updatedAt": timestamp(updated_at)?,
        "responseStatus": response_status,
        "correctionStatus": correction_status,
        "nonConclusion": non_conclusion(&public_state, authority)?,
        "href": format!("/cases/{slug}"),
    }))
}

struct CaseFilters {
    states: Vec<String>,
    agency: Option<String>,
    supplier: Option<String>,
    rule: Option<String>,
    published_from: Option<Date>,
    published_to: Option<Date>,
    has_response: Option<bool>,
    has_correction: Option<bool>,
    sido_code: Option<String>,
    sigungu_code: Option<String>,
    sort: String,
}

fn case_filters(
    query: &Query,
    relation: Option<(&str, &str)>,
) -> Result<CaseFilters, ServiceError> {
    let states = query.many("publicationState");
    let agency = relation
        .filter(|value| value.0 == "agency")
        .map(|value| value.1.to_owned())
        .map_or_else(
            || optional_uuid(query, "agencyId").map(|value| value.map(|id| id.to_string())),
            |value| Ok(Some(value)),
        )?;
    let supplier = relation
        .filter(|value| value.0 == "supplier")
        .map(|value| value.1.to_owned())
        .map_or_else(
            || optional_uuid(query, "supplierId").map(|value| value.map(|id| id.to_string())),
            |value| Ok(Some(value)),
        )?;
    let rule = relation
        .filter(|value| value.0 == "rule")
        .map(|value| value.1.to_owned())
        .or_else(|| query.first("ruleId").map(str::to_owned));
    let published_from = optional_date(query, "publishedFrom")?;
    let published_to = optional_date(query, "publishedTo")?;
    let has_response = optional_bool(query, "hasResponse")?;
    let has_correction = optional_bool(query, "hasCorrection")?;
    let (sido_code, sigungu_code) = region_filters(query)?;
    validate_range(published_from.as_ref(), published_to.as_ref())?;
    let sort = if relation.is_some() {
        requested_sort(query, &["updated_desc", "created_asc"], "updated_desc")?
    } else {
        requested_sort(
            query,
            &["updated_desc", "published_desc", "title_asc"],
            "updated_desc",
        )?
    };
    Ok(CaseFilters {
        states,
        agency,
        supplier,
        rule,
        published_from,
        published_to,
        has_response,
        has_correction,
        sido_code,
        sigungu_code,
        sort: sort.to_owned(),
    })
}

fn case_applied_filters(
    query: &Query,
    relation: Option<(&str, &str)>,
    states: &[String],
) -> Result<Value, ServiceError> {
    if relation.is_some() {
        return Ok(json!({}));
    }
    let mut filters = Map::new();
    filters.insert("publicationState".into(), json!(states));
    for name in [
        "agencyId",
        "supplierId",
        "ruleId",
        "sidoCode",
        "sigunguCode",
        "publishedFrom",
        "publishedTo",
    ] {
        if let Some(value) = query.first(name) {
            filters.insert(name.into(), json!(value));
        }
    }
    for name in ["hasResponse", "hasCorrection"] {
        if let Some(value) = query.first(name) {
            filters.insert(
                name.into(),
                json!(
                    value
                        .parse::<bool>()
                        .map_err(|_| ServiceError::InvalidRequest)?
                ),
            );
        }
    }
    Ok(Value::Object(filters))
}

async fn list_cases(
    pool: &PgPool,
    query: &Query,
    relation: Option<(&str, &str)>,
) -> Result<Value, ServiceError> {
    let filters = case_filters(query, relation)?;
    let rows = sqlx::query_as!(
        CaseCardRow,
        "SELECT c.slug,c.title,c.public_state,c.summary,c.latest_revision,c.updated_at,CASE WHEN jsonb_path_exists(r.payload,'$.responses[*]') OR jsonb_path_exists(r.payload,'$.partyResponses[*]') THEN 'RECEIVED'::text END AS \"response_status?\",CASE WHEN EXISTS(SELECT 1 FROM public.corrections x WHERE x.case_id=c.id) THEN 'PUBLISHED'::text END AS \"correction_status?\",r.payload AS \"payload!\" FROM public.cases c JOIN public.case_revisions r ON r.case_id=c.id AND r.revision=c.latest_revision WHERE (cardinality($1::text[])=0 OR c.public_state=ANY($1)) AND ($2::text IS NULL OR r.payload->>'agencyId'=$2 OR COALESCE(r.payload->'agencyIds','[]'::jsonb) ? $2) AND ($3::text IS NULL OR r.payload->>'supplierId'=$3 OR COALESCE(r.payload->'supplierIds','[]'::jsonb) ? $3) AND ($4::text IS NULL OR r.payload->>'ruleId'=$4 OR COALESCE(r.payload->'ruleIds','[]'::jsonb) ? $4) AND ($5::date IS NULL OR c.published_at::date >= $5) AND ($6::date IS NULL OR c.published_at::date <= $6) AND ($7::boolean IS NULL OR (jsonb_path_exists(r.payload,'$.responses[*]') OR jsonb_path_exists(r.payload,'$.partyResponses[*]'))=$7) AND ($8::boolean IS NULL OR EXISTS(SELECT 1 FROM public.corrections x WHERE x.case_id=c.id)=$8) AND (($9::text IS NULL AND $10::text IS NULL) OR EXISTS(SELECT 1 FROM public.agencies a WHERE r.payload->>'agencyId'=a.id::text AND ($9::text IS NULL OR btrim(a.sido_code::text)=$9) AND ($10::text IS NULL OR btrim(a.sigungu_code::text)=$10))) ORDER BY CASE WHEN $11='updated_desc' THEN c.updated_at END DESC,CASE WHEN $11='created_asc' THEN c.published_at END ASC,CASE WHEN $11='published_desc' THEN c.published_at END DESC,CASE WHEN $11='title_asc' THEN c.title END ASC,c.id LIMIT $12 OFFSET $13",
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
        query.limit + 1,
        query.offset,
    )
    .fetch_all(pool)
    .await
    .map_err(db)?;
    let items = rows.into_iter().map(case_card).collect::<Result<_, _>>()?;
    let (title, canonical_url) = match relation {
        Some(("agency", id)) => ("기관 관련 사건", format!("/agencies/{id}/cases")),
        Some(("supplier", id)) => ("업체 관련 사건", format!("/suppliers/{id}/cases")),
        Some(("rule", id)) => (
            "탐지 규칙 관련 사건",
            format!("/methodology/rules/{id}/cases"),
        ),
        Some(_) => return Err(ServiceError::Persistence),
        None => ("공개 사건", "/cases".to_owned()),
    };
    page_with_notice_seo(
        items,
        query,
        case_applied_filters(query, relation, &filters.states)?,
        title,
        canonical_url,
        PageNoticeAuthority::PublicationCollection,
    )
}

async fn get_case(pool: &PgPool, slug: &str) -> Result<Value, ServiceError> {
    let row=sqlx::query!("SELECT c.slug,c.title,c.public_state,c.latest_revision,c.summary,c.published_at,c.updated_at,c.source_freshness,r.payload FROM public.cases c JOIN public.case_revisions r ON r.case_id=c.id AND r.revision=c.latest_revision WHERE c.slug=$1", slug)
        .fetch_optional(pool).await.map_err(db)?.ok_or(ServiceError::NotFound)?;
    let mut payload = row.payload;
    let obj = payload.as_object_mut().ok_or(ServiceError::Persistence)?;
    let title = row.title;
    let summary = row.summary;
    obj.insert("slug".into(), json!(slug));
    obj.insert("title".into(), json!(&title));
    let public_state = row.public_state;
    obj.insert("publicState".into(), json!(&public_state));
    obj.insert("revision".into(), json!(row.latest_revision));
    obj.insert("publishedAt".into(), json!(timestamp(row.published_at)?));
    obj.insert("updatedAt".into(), json!(timestamp(row.updated_at)?));
    obj.insert("summary".into(), json!(&summary));
    for key in [
        "confirmedFacts",
        "criticalUnknowns",
        "partyResponses",
        "signals",
        "counterEvidence",
        "claims",
        "evidence",
        "timeline",
        "corrections",
        "limitations",
    ] {
        obj.entry(key).or_insert(json!([]));
    }
    obj.entry("freshness").or_insert(row.source_freshness);
    normalize_public_case(obj, &public_state)?;
    let seo_description = case_seo_description(&summary, obj);
    obj.insert(
        "seo".into(),
        seo_metadata(&title, seo_description, format!("/cases/{slug}")),
    );
    retain_fields(obj, PUBLIC_CASE_RESPONSE_FIELDS);
    Ok(payload)
}

async fn list_revisions(pool: &PgPool, query: &Query, slug: &str) -> Result<Value, ServiceError> {
    let sort = requested_sort(query, &["updated_desc", "created_asc"], "updated_desc")?;
    let rows = sqlx::query!(
        "SELECT r.revision,r.state::text \"state!\",r.published_at,r.payload FROM public.case_revisions r JOIN public.cases c ON c.id=r.case_id WHERE c.slug=$1 ORDER BY CASE WHEN $2='updated_desc' THEN r.revision END DESC,CASE WHEN $2='created_asc' THEN r.revision END ASC LIMIT $3 OFFSET $4",
        slug,
        sort,
        query.limit + 1,
        query.offset,
    )
    .fetch_all(pool)
    .await
    .map_err(db)?;
    if rows.is_empty() && query.offset == 0 {
        return Err(ServiceError::NotFound);
    }
    let mut items = Vec::new();
    for row in rows {
        let rev = row.revision;
        let payload = row.payload;
        let state: String = row.state;
        let published_at: OffsetDateTime = row.published_at;
        let authority = payload.as_object().ok_or(ServiceError::Persistence)?;
        items.push(json!({"revision":rev,"state":state,"nonConclusion":non_conclusion(&state, authority)?,"publishedAt":timestamp(published_at)?,"summary":payload.get("summary").and_then(Value::as_str).unwrap_or("공개 revision"),"href":format!("/cases/{slug}/revisions/{rev}")}));
    }
    page_with_notice_seo(
        items,
        query,
        json!({}),
        "사건 개정 이력",
        format!("/cases/{slug}/revisions"),
        PageNoticeAuthority::PublicationCollection,
    )
}

async fn get_revision(pool: &PgPool, slug: &str, revision: i32) -> Result<Value, ServiceError> {
    let row=sqlx::query!("SELECT c.latest_revision,c.public_state,r.revision,r.state::text \"state!\",r.payload,r.payload_sha256,r.published_at,r.supersedes_revision FROM public.case_revisions r JOIN public.cases c ON c.id=r.case_id WHERE c.slug=$1 AND r.revision=$2", slug, revision)
        .fetch_optional(pool).await.map_err(db)?.ok_or(ServiceError::NotFound)?;
    let payload = row.payload;
    let authority = payload.as_object().ok_or(ServiceError::Persistence)?;
    let notice_state = revision_non_conclusion_state(&row.public_state, &row.state);
    let notice = non_conclusion(notice_state, authority)?;
    let mut content = payload
        .get("content")
        .cloned()
        .unwrap_or_else(|| payload.clone());
    if let Some(object) = content.as_object_mut() {
        normalize_public_case_with_authority(object, notice_state, authority)?;
        retain_fields(object, PUBLIC_CASE_SNAPSHOT_FIELDS);
    }
    let description = format!("사건 {slug} 개정본 {revision} · {notice}");
    Ok(json!({
        "slug":slug,
        "revision":revision,
        "isLatest":row.latest_revision==revision,
        "snapshotHash":row.payload_sha256.trim(),
        "publishedAt":timestamp(row.published_at)?,
        "content":content,
        "diffFromPrevious":[],
        "seo":seo_metadata(
            &format!("사건 {slug} 개정본 {revision}"),
            description,
            format!("/cases/{slug}/revisions/{revision}"),
        ),
    }))
}

async fn reproducibility(pool: &PgPool, slug: &str) -> Result<Value, ServiceError> {
    let row = sqlx::query!("SELECT c.public_state,r.payload FROM public.case_revisions r JOIN public.cases c ON c.id=r.case_id AND r.revision=c.latest_revision WHERE c.slug=$1", slug)
        .fetch_optional(pool).await.map_err(db)?.ok_or(ServiceError::NotFound)?;
    let authority = row.payload.as_object().ok_or(ServiceError::Persistence)?;
    let mut value = row
        .payload
        .get("reproducibility")
        .cloned()
        .ok_or(ServiceError::NotFound)?;
    let object = value.as_object_mut().ok_or(ServiceError::Persistence)?;
    let notice = non_conclusion(&row.public_state, authority)?;
    object.insert("nonConclusion".into(), json!(&notice));
    object.insert(
        "seo".into(),
        seo_metadata(
            &format!("{slug} 재현 정보"),
            format!("사건 {slug} 재현 정보 · {notice}"),
            format!("/cases/{slug}/reproducibility"),
        ),
    );
    retain_fields(object, CASE_REPRODUCIBILITY_FIELDS);
    Ok(value)
}

async fn download_reproducibility(
    pool: &PgPool,
    slug: &str,
    query: &Query,
) -> Result<Value, ServiceError> {
    let format = query.first("format").ok_or(ServiceError::InvalidRequest)?;
    if !matches!(format, "JSON" | "CSV") {
        return Err(ServiceError::InvalidRequest);
    }
    let value = reproducibility(pool, slug).await?;
    let (extension, media_type, bytes) = if format == "JSON" {
        let payload = json!({
            "notice": PUBLIC_REDISTRIBUTION_NOTICE,
            "nonConclusion": value.get("nonConclusion"),
            "data": value,
        });
        (
            "json",
            "application/json; charset=utf-8",
            serde_json::to_vec(&payload).map_err(|_| ServiceError::Persistence)?,
        )
    } else {
        let rows = [json!({
            "caseSlug": slug,
            "nonConclusion": value.get("nonConclusion"),
            "reproducibilityJson": value,
        })];
        (
            "csv",
            "text/csv; charset=utf-8",
            render_csv(
                &[
                    ("caseSlug", "caseSlug"),
                    ("nonConclusion", "nonConclusion"),
                    ("reproducibilityJson", "reproducibilityJson"),
                ],
                &rows,
            ),
        )
    };
    render_download_bytes(
        &format!("case-{slug}-reproducibility"),
        format,
        extension,
        media_type,
        bytes,
        1,
        json!({"caseSlug":slug}),
    )
}

async fn list_corrections(pool: &PgPool, query: &Query) -> Result<Value, ServiceError> {
    let states = query.many("publicationState");
    let published_from = optional_date(query, "publishedFrom")?;
    let published_to = optional_date(query, "publishedTo")?;
    validate_range(published_from.as_ref(), published_to.as_ref())?;
    let sort = requested_sort(query, &["published_desc", "title_asc"], "published_desc")?;
    let rows = sqlx::query!(
        "SELECT x.id,x.source_revision,x.target_revision,x.summary,x.reason,x.published_at,c.slug,c.public_state,r.payload FROM public.corrections x JOIN public.cases c ON c.id=x.case_id JOIN public.case_revisions r ON r.case_id=c.id AND r.revision=c.latest_revision WHERE (cardinality($1::text[])=0 OR c.public_state=ANY($1)) AND ($2::date IS NULL OR x.published_at::date >= $2) AND ($3::date IS NULL OR x.published_at::date <= $3) ORDER BY CASE WHEN $4='published_desc' THEN x.published_at END DESC,CASE WHEN $4='title_asc' THEN x.summary END ASC,x.id LIMIT $5 OFFSET $6",
        &states,
        published_from,
        published_to,
        sort,
        query.limit + 1,
        query.offset,
    )
    .fetch_all(pool)
    .await
    .map_err(db)?;
    let mut items = Vec::new();
    for row in rows {
        let id = row.id;
        let authority = row.payload.as_object().ok_or(ServiceError::Persistence)?;
        items.push(json!({"id":id,"sourceRevision":row.source_revision,"targetRevision":row.target_revision,"summary":row.summary,"reason":row.reason,"publicState":row.public_state,"nonConclusion":non_conclusion(&row.public_state, authority)?,"publishedAt":timestamp(row.published_at)?,"href":format!("/corrections/{id}")}));
    }
    let mut filters = Map::new();
    filters.insert("publicationState".into(), json!(states));
    for name in ["publishedFrom", "publishedTo"] {
        if let Some(value) = query.first(name) {
            filters.insert(name.into(), json!(value));
        }
    }
    page_with_notice_seo(
        items,
        query,
        Value::Object(filters),
        "정정 기록",
        "/corrections".to_owned(),
        PageNoticeAuthority::PublicationCollection,
    )
}

async fn get_correction(pool: &PgPool, id: Uuid) -> Result<Value, ServiceError> {
    let row=sqlx::query!("SELECT x.id,x.source_revision,x.target_revision,x.summary,x.reason,x.published_at,c.slug,c.public_state,r.payload FROM public.corrections x JOIN public.cases c ON c.id=x.case_id JOIN public.case_revisions r ON r.case_id=c.id AND r.revision=c.latest_revision WHERE x.id=$1", id).fetch_optional(pool).await.map_err(db)?.ok_or(ServiceError::NotFound)?;
    let authority = row.payload.as_object().ok_or(ServiceError::Persistence)?;
    let notice = non_conclusion(&row.public_state, authority)?;
    let title = format!("{} 정정 기록", row.slug);
    Ok(json!({
        "id":{"id":id,"status":"PUBLISHED","version":1},
        "status":"PUBLISHED",
        "data":{
            "id":id,
            "caseSlug":row.slug,
            "sourceRevision":row.source_revision,
            "targetRevision":row.target_revision,
            "summary":row.summary,
            "reason":row.reason,
            "publicState":row.public_state,
            "nonConclusion":notice,
            "publishedAt":timestamp(row.published_at)?,
            "affectedClaims":[]
        },
        "seo":seo_metadata(
            &title,
            format!("{} · {}", row.summary, notice),
            format!("/corrections/{id}"),
        ),
        "links":[]
    }))
}

async fn coverage(pool: &PgPool) -> Result<Value, ServiceError> {
    let counts=sqlx::query!("SELECT (SELECT count(*) FROM public.contracts) \"contracts!\",(SELECT count(*) FROM public.agencies WHERE name IS NOT NULL) \"agencies!\",(SELECT count(*) FROM public.suppliers WHERE name IS NOT NULL) \"suppliers!\",(SELECT count(*) FROM public.cases) \"cases!\"").fetch_one(pool).await.map_err(db)?;
    let contracts: i64 = counts.contracts;
    let agencies: i64 = counts.agencies;
    let suppliers: i64 = counts.suppliers;
    let cases: i64 = counts.cases;
    let source_status = list_source_values(pool, &[], 200, 0, "name_asc").await?;
    let coverage_as_of = now()?;
    let sources = source_status
        .into_iter()
        .map(|source| {
            json!({
                "sourceId":source["sourceId"],
                "displayName":source["displayName"],
                "status":source["status"],
                "dateRange":{"label":"공개 projection 기간"},
                "recordCount":0,
                "freshness":{
                    "asOf":coverage_as_of,
                    "lastSuccessfulFetchAt":source["lastSuccessAt"],
                    "lagSeconds":source["lagSeconds"],
                    "status":"CURRENT"
                },
                "knownGaps":[],
                "interpretationNotice":source["interpretationNotice"]
            })
        })
        .collect::<Vec<_>>();
    Ok(
        json!({"asOf":now()?,"sources":sources,"dateRange":{"label":"projection 전체 보유 기간"},"recordCounts":{"sourceDocuments":0,"contracts":contracts,"contractLineItems":0,"agencies":agencies,"suppliers":suppliers,"publicCases":cases},"knownGaps":[],"methodologyVersion":"v13.0.0"}),
    )
}

async fn list_datasets(pool: &PgPool, query: &Query) -> Result<Value, ServiceError> {
    let formats = query.many("format");
    let sort = requested_sort(query, &["updated_desc", "title_asc"], "updated_desc")?;
    let rows = sqlx::query!(
        "SELECT id,title,description,format,coverage,license,download_url,updated_at FROM public.datasets WHERE cardinality($1::text[])=0 OR format=ANY($1) ORDER BY CASE WHEN $2='updated_desc' THEN updated_at END DESC,CASE WHEN $2='title_asc' THEN title END ASC,id LIMIT $3 OFFSET $4",
        &formats,
        sort,
        query.limit + 1,
        query.offset,
    )
    .fetch_all(pool)
    .await
    .map_err(db)?;
    let mut items = Vec::new();
    for r in rows {
        items.push(json!({"id":r.id,"title":r.title,"description":r.description,"format":r.format,"coverage":r.coverage,"license":r.license,"downloadUrl":r.download_url,"redistributionNotice":PUBLIC_REDISTRIBUTION_NOTICE,"updatedAt":timestamp(r.updated_at)?}));
    }
    page_with_notice_seo(
        items,
        query,
        json!({"format":formats}),
        "공개 데이터",
        "/data".to_owned(),
        PageNoticeAuthority::RedistributionCollection,
    )
}

async fn list_rules(pool: &PgPool, query: &Query) -> Result<Value, ServiceError> {
    let statuses = query.many("status");
    let sort = requested_sort(query, &["name_asc", "updated_desc"], "name_asc")?;
    let rows = sqlx::query_as!(
        RuleRow,
        "SELECT rule_id,name,active_version,public_description,requirements,exclusions,limitations,updated_at FROM public.rules WHERE cardinality($1::text[])=0 OR 'ACTIVE'::text=ANY($1) ORDER BY CASE WHEN $2='name_asc' THEN name END ASC,CASE WHEN $2='updated_desc' THEN updated_at END DESC,rule_id LIMIT $3 OFFSET $4",
        &statuses,
        sort,
        query.limit + 1,
        query.offset,
    )
    .fetch_all(pool)
    .await
    .map_err(db)?;
    let mut items = Vec::new();
    for r in rows {
        items.push(rule_value(r)?)
    }
    page(items, query, json!({"status":statuses}))
}
fn rule_value(r: RuleRow) -> Result<Value, ServiceError> {
    Ok(
        json!({"ruleId":r.rule_id,"name":r.name,"activeVersion":r.active_version,"description":r.public_description,"requiredFields":r.requirements,"exclusions":r.exclusions,"limitations":r.limitations,"formula":"authority-defined deterministic evaluation","updatedAt":timestamp(r.updated_at)?}),
    )
}
async fn get_rule(pool: &PgPool, id: &str) -> Result<Value, ServiceError> {
    let r=sqlx::query_as!(RuleRow, "SELECT rule_id,name,active_version,public_description,requirements,exclusions,limitations,updated_at FROM public.rules WHERE rule_id=$1", id).fetch_optional(pool).await.map_err(db)?.ok_or(ServiceError::NotFound)?;
    Ok(
        json!({"id":{"id":id,"status":"ACTIVE","version":1},"status":"ACTIVE","data":rule_value(r)?,"links":[]}),
    )
}

async fn list_source_values(
    pool: &PgPool,
    statuses: &[String],
    limit: i64,
    offset: i64,
    sort: &str,
) -> Result<Vec<Value>, ServiceError> {
    if !matches!(sort, "status_asc" | "last_success_desc" | "name_asc") {
        return Err(ServiceError::InvalidRequest);
    }
    let rows = sqlx::query_as!(
        SourceRow,
        "SELECT source_id,display_name,status,last_success_at,lag_seconds,affected_scope,public_message FROM public.source_status WHERE cardinality($1::text[])=0 OR status=ANY($1) ORDER BY CASE WHEN $2='status_asc' THEN status END ASC,CASE WHEN $2='last_success_desc' THEN last_success_at END DESC NULLS LAST,CASE WHEN $2='name_asc' THEN display_name END ASC,source_id LIMIT $3 OFFSET $4",
        statuses,
        sort,
        limit,
        offset,
    )
    .fetch_all(pool)
    .await
    .map_err(db)?;
    let mut values = Vec::new();
    for r in rows {
        let SourceRow {
            source_id,
            display_name,
            status,
            last_success_at,
            lag_seconds,
            affected_scope: _affected_scope,
            public_message,
        } = r;
        values.push(json!({"sourceId":source_id,"displayName":display_name,"status":status,"lastSuccessAt":last_success_at.map(timestamp).transpose()?,"lagSeconds":lag_seconds,"publicMessage":public_message,"interpretationNotice":OPERATIONAL_INTERPRETATION_NOTICE}));
    }
    Ok(values)
}
async fn list_sources(pool: &PgPool, query: &Query) -> Result<Value, ServiceError> {
    let statuses = query.many("status");
    let sort = requested_sort(
        query,
        &["status_asc", "last_success_desc", "name_asc"],
        "name_asc",
    )?;
    let items = list_source_values(pool, &statuses, query.limit + 1, query.offset, sort).await?;
    page_with_notice_seo(
        items,
        query,
        json!({"status":statuses}),
        "데이터 출처 대장",
        "/sources".to_owned(),
        PageNoticeAuthority::OperationalCollection,
    )
}
