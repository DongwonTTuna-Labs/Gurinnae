async fn list_agencies(pool: &PgPool, query: &Query) -> Result<Value, ServiceError> {
    let q = query.first("q").unwrap_or("");
    let types = query.many("agencyType");
    let jurisdiction = query.first("jurisdiction").unwrap_or("");
    let sort = requested_sort(
        query,
        &["name_asc", "updated_desc", "contract_count_desc"],
        "name_asc",
    )?;
    let rows = sqlx::query!(
        "SELECT a.id,a.name,a.agency_type,a.jurisdiction,a.coverage,a.case_counts,a.updated_at FROM public.agencies a WHERE ($1='' OR a.name ILIKE '%'||$1||'%') AND (cardinality($2::text[])=0 OR a.agency_type=ANY($2)) AND ($3='' OR a.jurisdiction=$3) ORDER BY CASE WHEN $4='name_asc' THEN a.name END ASC,CASE WHEN $4='updated_desc' THEN a.updated_at END DESC,CASE WHEN $4='contract_count_desc' THEN (SELECT count(*) FROM public.contracts c WHERE c.agency_id=a.id) END DESC,a.id LIMIT $5 OFFSET $6",
        q,
        &types,
        jurisdiction,
        sort,
        query.limit + 1,
        query.offset,
    )
    .fetch_all(pool)
    .await
    .map_err(db)?;
    let mut items = Vec::with_capacity(rows.len());
    for row in rows {
        let id = row.id;
        items.push(json!({
            "id": id,
            "name": row.name,
            "agencyType": row.agency_type,
            "jurisdiction": row.jurisdiction,
            "caseCounts": row.case_counts,
            "coverage": row.coverage,
            "href": format!("/agencies/{id}"),
        }));
    }
    page(
        items,
        query,
        json!({"q":q,"agencyType":types,"jurisdiction":jurisdiction}),
    )
}

async fn get_agency(pool: &PgPool, id: Uuid) -> Result<Value, ServiceError> {
    let row = sqlx::query!("SELECT id,name,agency_type,jurisdiction,coverage,descriptive_metrics,case_counts,updated_at FROM public.agencies WHERE id=$1", id)
        .fetch_optional(pool).await.map_err(db)?.ok_or(ServiceError::NotFound)?;
    let cases = recent_cases(pool, "agency", id).await?;
    let contracts = recent_contracts(pool, "agency", id).await?;
    Ok(json!({
        "id": id,
        "name": row.name,
        "agencyType": row.agency_type,
        "jurisdiction": row.jurisdiction,
        "identifiers": [],
        "coverage": row.coverage,
        "metrics": row.descriptive_metrics,
        "caseCountsByState": row.case_counts,
        "recentCases": cases,
        "recentContracts": contracts,
        "identityWarnings": [],
        "freshness": {"asOf":timestamp(row.updated_at)?,"status":"CURRENT"},
    }))
}

async fn list_suppliers(pool: &PgPool, query: &Query) -> Result<Value, ServiceError> {
    let q = query.first("q").unwrap_or("");
    let statuses = query.many("businessStatus");
    let identity_statuses = query.many("identityStatus");
    let sort = requested_sort(
        query,
        &["name_asc", "updated_desc", "contract_count_desc"],
        "name_asc",
    )?;
    let rows = sqlx::query!(
        "SELECT s.id,s.name,s.business_status,s.coverage,s.case_counts,s.identity_warnings FROM public.suppliers s WHERE ($1='' OR s.name ILIKE '%'||$1||'%') AND (cardinality($2::text[])=0 OR s.business_status=ANY($2)) AND (cardinality($3::text[])=0 OR CASE WHEN jsonb_array_length(s.identity_warnings)=0 THEN 'VERIFIED' ELSE 'AMBIGUOUS' END=ANY($3)) ORDER BY CASE WHEN $4='name_asc' THEN s.name END ASC,CASE WHEN $4='updated_desc' THEN s.updated_at END DESC,CASE WHEN $4='contract_count_desc' THEN (SELECT count(*) FROM public.contracts c WHERE c.supplier_id=s.id) END DESC,s.id LIMIT $5 OFFSET $6",
        q,
        &statuses,
        &identity_statuses,
        sort,
        query.limit + 1,
        query.offset,
    )
    .fetch_all(pool)
    .await
    .map_err(db)?;
    let mut items = Vec::with_capacity(rows.len());
    for row in rows {
        let id = row.id;
        items.push(json!({
            "id":id,"name":row.name,
            "businessStatus":row.business_status,
            "caseCounts":row.case_counts,
            "coverage":row.coverage,
            "identityWarnings":row.identity_warnings,
            "href":format!("/suppliers/{id}")
        }));
    }
    page(
        items,
        query,
        json!({"q":q,"businessStatus":statuses,"identityStatus":identity_statuses}),
    )
}

async fn get_supplier(pool: &PgPool, id: Uuid) -> Result<Value, ServiceError> {
    let row=sqlx::query!("SELECT id,name,business_status,coverage,descriptive_metrics,case_counts,identity_warnings,updated_at FROM public.suppliers WHERE id=$1", id)
        .fetch_optional(pool).await.map_err(db)?.ok_or(ServiceError::NotFound)?;
    Ok(
        json!({"id":id,"name":row.name,
        "businessStatus":row.business_status,"identifiers":[],
        "coverage":row.coverage,"metrics":row.descriptive_metrics,
        "caseCountsByState":row.case_counts,"recentCases":recent_cases(pool,"supplier",id).await?,
        "recentContracts":recent_contracts(pool,"supplier",id).await?,"identityWarnings":row.identity_warnings,
        "freshness":{"asOf":timestamp(row.updated_at)?,"status":"CURRENT"}}),
    )
}

async fn recent_cases(pool: &PgPool, relation: &str, id: Uuid) -> Result<Vec<Value>, ServiceError> {
    let (scalar_key, array_key) = if relation == "agency" {
        ("agencyId", "agencyIds")
    } else {
        ("supplierId", "supplierIds")
    };
    let rows=sqlx::query_as!(CaseCardRow, "SELECT c.slug,c.title,c.public_state,c.summary,c.latest_revision,c.updated_at FROM public.cases c JOIN public.case_revisions r ON r.case_id=c.id AND r.revision=c.latest_revision WHERE r.payload->>$1=$3 OR COALESCE(r.payload->$2,'[]'::jsonb) ? $3 ORDER BY c.updated_at DESC LIMIT 5", scalar_key, array_key, id.to_string())
        .fetch_all(pool).await.map_err(db)?;
    rows.into_iter().map(case_card).collect()
}

async fn recent_contracts(
    pool: &PgPool,
    relation: &str,
    id: Uuid,
) -> Result<Vec<Value>, ServiceError> {
    let rows = if relation == "agency" {
        sqlx::query_as!(ContractSummaryRow, "SELECT c.id,c.contract_number,c.title,c.agency_id,c.supplier_id,c.status,c.signed_at,c.amount,a.name agency_name,s.name supplier_name FROM public.contracts c LEFT JOIN public.agencies a ON a.id=c.agency_id LEFT JOIN public.suppliers s ON s.id=c.supplier_id WHERE c.agency_id=$1 ORDER BY c.updated_at DESC LIMIT 5", id)
            .fetch_all(pool).await.map_err(db)?
    } else {
        sqlx::query_as!(ContractSummaryRow, "SELECT c.id,c.contract_number,c.title,c.agency_id,c.supplier_id,c.status,c.signed_at,c.amount,a.name agency_name,s.name supplier_name FROM public.contracts c LEFT JOIN public.agencies a ON a.id=c.agency_id LEFT JOIN public.suppliers s ON s.id=c.supplier_id WHERE c.supplier_id=$1 ORDER BY c.updated_at DESC LIMIT 5", id)
            .fetch_all(pool).await.map_err(db)?
    };
    rows.into_iter().map(contract_summary).collect()
}

async fn list_related_cases(
    pool: &PgPool,
    query: &Query,
    relation: &str,
    id: Uuid,
) -> Result<Value, ServiceError> {
    let (scalar_key, array_key) = if relation == "agency" {
        ("agencyId", "agencyIds")
    } else {
        ("supplierId", "supplierIds")
    };
    let sort = requested_sort(query, &["updated_desc", "created_asc"], "updated_desc")?;
    let rows = sqlx::query_as!(
        CaseCardRow,
        "SELECT c.slug,c.title,c.public_state,c.summary,c.latest_revision,c.updated_at FROM public.cases c JOIN public.case_revisions r ON r.case_id=c.id AND r.revision=c.latest_revision WHERE r.payload->>$1=$3 OR COALESCE(r.payload->$2,'[]'::jsonb) ? $3 ORDER BY CASE WHEN $4='updated_desc' THEN c.updated_at END DESC,CASE WHEN $4='created_asc' THEN c.published_at END ASC,c.id LIMIT $5 OFFSET $6",
        scalar_key,
        array_key,
        id.to_string(),
        sort,
        query.limit + 1,
        query.offset,
    )
    .fetch_all(pool)
    .await
    .map_err(db)?;
    page(
        rows.into_iter().map(case_card).collect::<Result<_, _>>()?,
        query,
        json!({}),
    )
}

async fn list_contracts(
    pool: &PgPool,
    query: &Query,
    relation: Option<(&str, Uuid)>,
) -> Result<Value, ServiceError> {
    let q = query.first("q").unwrap_or("");
    let agency = relation
        .filter(|value| value.0 == "agency")
        .map(|value| value.1)
        .map_or_else(|| optional_uuid(query, "agencyId"), |value| Ok(Some(value)))?;
    let supplier = relation
        .filter(|value| value.0 == "supplier")
        .map(|value| value.1)
        .map_or_else(
            || optional_uuid(query, "supplierId"),
            |value| Ok(Some(value)),
        )?;
    let statuses = query.many("contractStatus");
    let procurement_methods = query.many("procurementMethod");
    let signed_from = optional_date(query, "signedFrom")?;
    let signed_to = optional_date(query, "signedTo")?;
    let amount_min = optional_decimal(query, "amountMin")?;
    let amount_max = optional_decimal(query, "amountMax")?;
    validate_range(signed_from.as_ref(), signed_to.as_ref())?;
    validate_range(amount_min.as_ref(), amount_max.as_ref())?;
    let sort = if relation.is_some() {
        requested_sort(query, &["updated_desc", "created_asc"], "updated_desc")?
    } else {
        requested_sort(
            query,
            &["signed_desc", "amount_desc", "amount_asc", "title_asc"],
            "signed_desc",
        )?
    };
    let rows = sqlx::query_as!(
        ContractSummaryRow,
        "SELECT c.id,c.contract_number,c.title,c.agency_id,c.supplier_id,c.status,c.signed_at,c.amount,a.name agency_name,s.name supplier_name FROM public.contracts c LEFT JOIN public.agencies a ON a.id=c.agency_id LEFT JOIN public.suppliers s ON s.id=c.supplier_id WHERE ($1='' OR c.title ILIKE '%'||$1||'%' OR c.contract_number ILIKE '%'||$1||'%') AND ($2::uuid IS NULL OR c.agency_id=$2) AND ($3::uuid IS NULL OR c.supplier_id=$3) AND (cardinality($4::text[])=0 OR c.status=ANY($4)) AND (cardinality($5::text[])=0 OR COALESCE(c.detail->>'procurementMethod',c.detail->>'contractMethod')=ANY($5)) AND ($6::date IS NULL OR c.signed_at >= $6) AND ($7::date IS NULL OR c.signed_at <= $7) AND ($8::numeric IS NULL OR (c.amount->>'amount')::numeric >= $8) AND ($9::numeric IS NULL OR (c.amount->>'amount')::numeric <= $9) ORDER BY CASE WHEN $10='updated_desc' THEN c.updated_at END DESC,CASE WHEN $10='created_asc' THEN c.signed_at END ASC NULLS LAST,CASE WHEN $10='signed_desc' THEN c.signed_at END DESC NULLS LAST,CASE WHEN $10='amount_desc' THEN (c.amount->>'amount')::numeric END DESC NULLS LAST,CASE WHEN $10='amount_asc' THEN (c.amount->>'amount')::numeric END ASC NULLS LAST,CASE WHEN $10='title_asc' THEN c.title END ASC,c.id LIMIT $11 OFFSET $12",
        q,
        agency,
        supplier,
        &statuses,
        &procurement_methods,
        signed_from,
        signed_to,
        amount_min,
        amount_max,
        sort,
        query.limit + 1,
        query.offset,
    )
    .fetch_all(pool)
    .await
    .map_err(db)?;
    let applied_filters = if relation.is_some() {
        json!({})
    } else {
        let mut filters = Map::new();
        filters.insert("q".into(), json!(q));
        filters.insert("contractStatus".into(), json!(statuses));
        filters.insert("procurementMethod".into(), json!(procurement_methods));
        if let Some(value) = agency {
            filters.insert("agencyId".into(), json!(value));
        }
        if let Some(value) = supplier {
            filters.insert("supplierId".into(), json!(value));
        }
        for name in ["signedFrom", "signedTo", "amountMin", "amountMax"] {
            if let Some(value) = query.first(name) {
                filters.insert(name.into(), json!(value));
            }
        }
        Value::Object(filters)
    };
    page(
        rows.into_iter()
            .map(contract_summary)
            .collect::<Result<_, _>>()?,
        query,
        applied_filters,
    )
}

async fn get_contract(pool: &PgPool, id: Uuid) -> Result<Value, ServiceError> {
    let row=sqlx::query!("SELECT c.id,c.contract_number,c.title,c.agency_id,c.supplier_id,c.status,c.signed_at,c.amount,c.detail,a.name agency_name,s.name supplier_name FROM public.contracts c LEFT JOIN public.agencies a ON a.id=c.agency_id LEFT JOIN public.suppliers s ON s.id=c.supplier_id WHERE c.id=$1", id)
        .fetch_optional(pool).await.map_err(db)?.ok_or(ServiceError::NotFound)?;
    let mut detail = row.detail;
    let object = detail.as_object_mut().ok_or(ServiceError::Persistence)?;
    object.insert("id".into(), json!(id));
    object.insert(
        "contractNumber".into(),
        json!(row.contract_number.unwrap_or_default()),
    );
    object.insert("title".into(), json!(row.title));
    object.insert(
        "agency".into(),
        entity_ref(row.agency_id, row.agency_name, "AGENCY"),
    );
    if let Some(supplier) = row.supplier_id {
        object.insert(
            "supplier".into(),
            entity_ref(Some(supplier), row.supplier_name, "SUPPLIER"),
        );
    }
    object.insert("status".into(), json!(row.status));
    object.entry("currency").or_insert(json!("KRW"));
    object.entry("lineItems").or_insert(json!([]));
    object.entry("changes").or_insert(json!([]));
    object.entry("sourceDocuments").or_insert(json!([]));
    object.entry("normalizationWarnings").or_insert(json!([]));
    object.entry("relatedCases").or_insert(json!([]));
    Ok(detail)
}

async fn list_contract_changes(
    pool: &PgPool,
    query: &Query,
    id: Uuid,
) -> Result<Value, ServiceError> {
    let detail = sqlx::query_scalar!("SELECT detail FROM public.contracts WHERE id=$1", id)
        .fetch_optional(pool)
        .await
        .map_err(db)?
        .ok_or(ServiceError::NotFound)?;
    let mut all = detail
        .get("changes")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    match requested_sort(query, &["updated_desc", "created_asc"], "updated_desc")? {
        "updated_desc" => {
            all.sort_by(|left, right| contract_change_key(right).cmp(&contract_change_key(left)))
        }
        "created_asc" => {
            all.sort_by(|left, right| contract_change_key(left).cmp(&contract_change_key(right)))
        }
        _ => return Err(ServiceError::InvalidRequest),
    }
    let items = all
        .into_iter()
        .skip(query.offset as usize)
        .take((query.limit + 1) as usize)
        .collect();
    page(items, query, json!({}))
}

fn contract_change_key(value: &Value) -> (&str, i64) {
    (
        value.get("changedAt").and_then(Value::as_str).unwrap_or(""),
        value.get("sequence").and_then(Value::as_i64).unwrap_or(0),
    )
}

async fn download_contracts(pool: &PgPool, query: &Query) -> Result<Value, ServiceError> {
    let format = query.first("format").ok_or(ServiceError::InvalidRequest)?;
    if !matches!(format, "CSV" | "JSONL") {
        return Err(ServiceError::InvalidRequest);
    }
    let agency = optional_uuid(query, "agencyId")?;
    let supplier = optional_uuid(query, "supplierId")?;
    let signed_from = optional_date(query, "signedFrom")?;
    let signed_to = optional_date(query, "signedTo")?;
    validate_range(signed_from.as_ref(), signed_to.as_ref())?;
    let count = sqlx::query_scalar!(
        "SELECT count(*) AS \"count!\" FROM public.contracts c WHERE ($1::uuid IS NULL OR c.agency_id=$1) AND ($2::uuid IS NULL OR c.supplier_id=$2) AND ($3::date IS NULL OR c.signed_at >= $3) AND ($4::date IS NULL OR c.signed_at <= $4)",
        agency,
        supplier,
        signed_from,
        signed_to,
    )
    .fetch_one(pool)
    .await
    .map_err(db)?;
    let digest = Sha256::digest(format!("contracts:{}:{:?}", count, query.values).as_bytes());
    Ok(json!({"id":format!("contracts-{:x}",digest),"status":"READY","version":count}))
}
