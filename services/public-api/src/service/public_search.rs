async fn get_source(pool: &PgPool, id: &str) -> Result<Value, ServiceError> {
    let r=sqlx::query_as!(SourceDetailRow, "SELECT source_status.display_name,source_status.status,source_status.updated_at,source_official_urls.official_url AS \"official_url?\" FROM public.source_status source_status LEFT JOIN public.source_official_urls source_official_urls ON source_official_urls.source_id=source_status.source_id WHERE source_status.source_id=$1", id).fetch_optional(pool).await.map_err(db)?.ok_or(ServiceError::NotFound)?;
    let SourceDetailRow {
        display_name,
        status,
        updated_at,
        official_url,
    } = r;
    let title = format!("{display_name} 출처");
    Ok(json!({
        "id":{"id":id,"status":status,"version":1},
        "status":status,
        "data":{
            "sourceId":id,
            "displayName":display_name,
            "owner":"공개 데이터 제공기관",
            "accessType":"PUBLIC",
            "officialUrl":official_url,
            "status":status,
            "coverage":{"dateRange":{"label":"공개 projection 기간"},"sourceIds":[id],"recordCount":0,"knownGaps":[],"freshness":{"asOf":timestamp(updated_at)?,"status":"CURRENT"}},
            "freshness":{"asOf":timestamp(updated_at)?,"status":"CURRENT"},
            "knownIssues":[],
            "interpretationNotice":OPERATIONAL_INTERPRETATION_NOTICE
        },
        "links":[],
        "seo":seo_metadata(
            &title,
            operational_seo_description(&title),
            format!("/sources/{id}"),
        )
    }))
}

async fn search(pool: &PgPool, query: &Query) -> Result<Value, ServiceError> {
    let criteria = search_filters(query)?;
    let rows = sqlx::query!(
        "SELECT result_type AS \"result_type!\",id AS \"id!\",title AS \"title!\",subtitle,status,summary,updated_at,href AS \"href!\",notice_payload FROM (\
         SELECT 'CASE'::text result_type,c.id::text,c.title,c.slug subtitle,c.public_state status,c.summary,c.updated_at,'/cases/'||c.slug href,r.payload notice_payload FROM public.cases c JOIN public.case_revisions r ON r.case_id=c.id AND r.revision=c.latest_revision WHERE (c.title ILIKE $1 OR c.summary ILIKE $1) AND (cardinality($2::text[])=0 OR 'CASE'=ANY($2)) AND (cardinality($3::text[])=0 OR c.public_state=ANY($3)) AND ($4::date IS NULL OR c.updated_at::date >= $4) AND ($5::date IS NULL OR c.updated_at::date <= $5) AND ($6::uuid IS NULL OR r.payload->>'agencyId'=$6::text OR COALESCE(r.payload->'agencyIds','[]'::jsonb) ? $6::text) AND (($7::text IS NULL AND $8::text IS NULL) OR EXISTS(SELECT 1 FROM public.agencies a WHERE r.payload->>'agencyId'=a.id::text AND ($7::text IS NULL OR btrim(a.sido_code::text)=$7) AND ($8::text IS NULL OR btrim(a.sigungu_code::text)=$8))) \
         UNION ALL SELECT 'AGENCY',a.id::text,a.name,a.jurisdiction,a.agency_type,NULL,a.updated_at,'/agencies/'||a.id::text,NULL::jsonb FROM public.agencies a WHERE a.name IS NOT NULL AND a.name ILIKE $1 AND (cardinality($2::text[])=0 OR 'AGENCY'=ANY($2)) AND cardinality($3::text[])=0 AND ($4::date IS NULL OR a.updated_at::date >= $4) AND ($5::date IS NULL OR a.updated_at::date <= $5) AND ($6::uuid IS NULL OR a.id=$6) AND ($7::text IS NULL OR btrim(a.sido_code::text)=$7) AND ($8::text IS NULL OR btrim(a.sigungu_code::text)=$8) \
         UNION ALL SELECT 'SUPPLIER',id::text,name,business_status,business_status,NULL,updated_at,'/suppliers/'||id::text,NULL::jsonb FROM public.suppliers WHERE name IS NOT NULL AND name ILIKE $1 AND (cardinality($2::text[])=0 OR 'SUPPLIER'=ANY($2)) AND cardinality($3::text[])=0 AND ($4::date IS NULL OR updated_at::date >= $4) AND ($5::date IS NULL OR updated_at::date <= $5) AND $6::uuid IS NULL AND $7::text IS NULL AND $8::text IS NULL \
         UNION ALL SELECT 'CONTRACT',c.id::text,c.title,c.contract_number,c.status,NULL,c.updated_at,'/contracts/'||c.id::text,NULL::jsonb FROM public.contracts c LEFT JOIN public.agencies a ON a.id=c.agency_id WHERE (c.title ILIKE $1 OR c.contract_number ILIKE $1) AND (cardinality($2::text[])=0 OR 'CONTRACT'=ANY($2)) AND cardinality($3::text[])=0 AND ($4::date IS NULL OR c.updated_at::date >= $4) AND ($5::date IS NULL OR c.updated_at::date <= $5) AND ($6::uuid IS NULL OR c.agency_id=$6) AND ($7::text IS NULL OR btrim(a.sido_code::text)=$7) AND ($8::text IS NULL OR btrim(a.sigungu_code::text)=$8) \
         UNION ALL SELECT 'RULE',rule_id,name,active_version,'ACTIVE',public_description,updated_at,'/methodology/rules/'||rule_id,NULL::jsonb FROM public.rules WHERE (name ILIKE $1 OR public_description ILIKE $1) AND (cardinality($2::text[])=0 OR 'RULE'=ANY($2)) AND cardinality($3::text[])=0 AND ($4::date IS NULL OR updated_at::date >= $4) AND ($5::date IS NULL OR updated_at::date <= $5) AND $6::uuid IS NULL AND $7::text IS NULL AND $8::text IS NULL \
         UNION ALL SELECT 'CORRECTION',x.id::text,x.summary,c.slug,c.public_state,x.reason,x.published_at,'/corrections/'||x.id::text,r.payload FROM public.corrections x JOIN public.cases c ON c.id=x.case_id JOIN public.case_revisions r ON r.case_id=c.id AND r.revision=c.latest_revision WHERE (x.summary ILIKE $1 OR x.reason ILIKE $1) AND (cardinality($2::text[])=0 OR 'CORRECTION'=ANY($2)) AND (cardinality($3::text[])=0 OR c.public_state=ANY($3)) AND ($4::date IS NULL OR x.published_at::date >= $4) AND ($5::date IS NULL OR x.published_at::date <= $5) AND ($6::uuid IS NULL OR r.payload->>'agencyId'=$6::text OR COALESCE(r.payload->'agencyIds','[]'::jsonb) ? $6::text) AND (($7::text IS NULL AND $8::text IS NULL) OR EXISTS(SELECT 1 FROM public.agencies a WHERE r.payload->>'agencyId'=a.id::text AND ($7::text IS NULL OR btrim(a.sido_code::text)=$7) AND ($8::text IS NULL OR btrim(a.sigungu_code::text)=$8))) \
         UNION ALL SELECT 'DATASET',id,title,format,'PUBLISHED',description,updated_at,'/data',NULL::jsonb FROM public.datasets WHERE (title ILIKE $1 OR description ILIKE $1) AND (cardinality($2::text[])=0 OR 'DATASET'=ANY($2)) AND cardinality($3::text[])=0 AND ($4::date IS NULL OR updated_at::date >= $4) AND ($5::date IS NULL OR updated_at::date <= $5) AND $6::uuid IS NULL AND $7::text IS NULL AND $8::text IS NULL \
         UNION ALL SELECT 'SOURCE',source_id,display_name,status,status,public_message,updated_at,'/sources/'||source_id,NULL::jsonb FROM public.source_status WHERE (display_name ILIKE $1 OR source_id ILIKE $1 OR public_message ILIKE $1) AND (cardinality($2::text[])=0 OR 'SOURCE'=ANY($2)) AND cardinality($3::text[])=0 AND ($4::date IS NULL OR updated_at::date >= $4) AND ($5::date IS NULL OR updated_at::date <= $5) AND $6::uuid IS NULL AND $7::text IS NULL AND $8::text IS NULL\
         ) x ORDER BY CASE WHEN $9='relevance' THEN (title ILIKE $1) END DESC,CASE WHEN $9 IN ('relevance','updated_desc') THEN updated_at END DESC NULLS LAST,CASE WHEN $9='title_asc' THEN title END ASC,id LIMIT $10 OFFSET $11",
        &criteria.pattern,
        &criteria.types,
        &criteria.states,
        criteria.date_from,
        criteria.date_to,
        criteria.agency_id,
        &criteria.sido_code as _,
        &criteria.sigungu_code as _,
        &criteria.sort,
        query.limit + 1,
        query.offset,
    )
    .fetch_all(pool)
    .await
    .map_err(db)?;
    let mut items = Vec::new();
    for r in rows {
        let result_type: String = r.result_type;
        let id: String = r.id;
        let title: String = r.title;
        let href: String = r.href;
        let subtitle: Option<String> = r.subtitle;
        let status: Option<String> = r.status;
        let summary: Option<String> = r.summary;
        let updated_at: Option<OffsetDateTime> = r.updated_at;
        let notice_payload: Option<Value> = r.notice_payload;
        let (non_conclusion, interpretation_notice) = search_result_notices(
            &result_type,
            status.as_deref(),
            notice_payload.as_ref().and_then(Value::as_object),
        )?;
        let mut v = Map::new();
        for (key, value) in [
            ("resultType", result_type),
            ("id", id),
            ("title", title),
            ("href", href),
        ] {
            v.insert(key.into(), json!(value));
        }
        for (key, value) in [
            ("subtitle", subtitle),
            ("status", status),
            ("summary", summary),
        ] {
            if let Some(value) = value {
                v.insert(key.into(), json!(value));
            }
        }
        v.insert("nonConclusion".into(), json!(non_conclusion));
        v.insert("interpretationNotice".into(), json!(interpretation_notice));
        if let Some(updated_at) = updated_at {
            v.insert("updatedAt".into(), json!(timestamp(updated_at)?));
        }
        items.push(Value::Object(v));
    }
    let mut filters = Map::new();
    filters.insert("q".into(), json!(criteria.q));
    filters.insert("types".into(), json!(criteria.types));
    filters.insert("publicationState".into(), json!(criteria.states));
    for name in ["agencyId", "sidoCode", "sigunguCode", "dateFrom", "dateTo"] {
        if let Some(value) = query.first(name) {
            filters.insert(name.into(), json!(value));
        }
    }
    page_with_notice_seo(
        items,
        query,
        Value::Object(filters),
        "공개 기록 검색",
        "/search".to_owned(),
        PageNoticeAuthority::Search,
    )
}

async fn system_status(pool: &PgPool) -> Result<Value, ServiceError> {
    let sources = list_source_values(pool, &[], 200, 0, "name_asc").await?;
    let incident = sources.iter().any(|v| {
        v.get("status")
            .and_then(Value::as_str)
            .is_some_and(|s| matches!(s, "FAILED" | "INCIDENT"))
    });
    let degraded = sources.iter().any(|v| {
        v.get("status")
            .and_then(Value::as_str)
            .is_some_and(|s| matches!(s, "DEGRADED" | "STALE"))
    });
    Ok(
        json!({"status":if incident{"incident"}else if degraded{"degraded"}else{"operational"},"asOf":now()?,"affectedCapabilities":if incident||degraded{json!(["source freshness"])}else{json!([])},"sourceStatus":sources}),
    )
}
