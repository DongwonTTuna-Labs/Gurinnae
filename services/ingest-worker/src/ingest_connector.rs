fn operation_target(
    operation: &ConnectorOperation,
    base_url: Option<&str>,
    configuration: &Value,
) -> Result<String, Failure> {
    if let Some(value) = configuration
        .pointer(&format!("/operationUrls/{}", operation.id))
        .and_then(Value::as_str)
    {
        return validate_target(value);
    }
    if operation.kind == "manifest" {
        return configuration
            .get("manifestUrl")
            .and_then(Value::as_str)
            .ok_or_else(|| Failure::Terminal("SOURCE_MANIFEST_URL_MISSING", operation.id.into()))
            .and_then(validate_target);
    }
    let base = base_url
        .ok_or_else(|| Failure::Terminal("SOURCE_BASE_URL_MISSING", operation.id.into()))?;
    let base = Url::parse(base)
        .map_err(|_| Failure::Terminal("SOURCE_BASE_URL_INVALID", operation.id.into()))?;
    base.join(operation.remote_path.trim_start_matches('/'))
        .map_err(|_| Failure::Terminal("SOURCE_TARGET_INVALID", operation.id.into()))
        .and_then(|value| validate_target(value.as_str()))
}

fn validate_target(value: &str) -> Result<String, Failure> {
    let url =
        Url::parse(value).map_err(|_| Failure::Terminal("SOURCE_TARGET_INVALID", "URL".into()))?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || url.username() != ""
        || url.password().is_some()
    {
        return Err(Failure::Terminal("SOURCE_TARGET_INVALID", "HTTPS".into()));
    }
    Ok(url.to_string())
}

fn with_operation_parameters(
    target: &str,
    operation: &ConnectorOperation,
    configuration: &Value,
    requested_from: Option<time::Date>,
    requested_to: Option<time::Date>,
) -> Result<String, Failure> {
    let mut url = Url::parse(target)
        .map_err(|_| Failure::Terminal("SOURCE_TARGET_INVALID", operation.id.into()))?;
    {
        let mut pairs = url.query_pairs_mut();
        pairs.append_pair("operationId", operation.id);
        if operation.pagination == "page-number" {
            pairs.append_pair("pageNo", "1");
            pairs.append_pair("numOfRows", "1000");
            pairs.append_pair("type", "json");
        }
        if let Some(value) = requested_from {
            pairs.append_pair("from", &value.to_string());
        }
        if let Some(value) = requested_to {
            pairs.append_pair("to", &value.to_string());
        }
        if let Some(values) = configuration
            .pointer(&format!("/parameters/{}", operation.id))
            .and_then(Value::as_object)
        {
            for (key, value) in values {
                if let Some(value) = value.as_str() {
                    pairs.append_pair(key, value);
                }
            }
        }
    }
    Ok(url.to_string())
}

async fn fetch_source(
    client: &Client,
    gateway: &Url,
    source_id: &str,
    target: &str,
) -> Result<SourceResponse, Failure> {
    let response = client
        .get(gateway.clone())
        .header("x-gurine-egress-caller", "ingest-worker")
        .header("x-gurine-source-id", source_id)
        .header("x-gurine-egress-target", target)
        .send()
        .await
        .map_err(|error| Failure::Retryable("SOURCE_UNAVAILABLE", error.to_string()))?;
    let status = response.status();
    if status == StatusCode::TOO_MANY_REQUESTS || status.is_server_error() {
        return Err(Failure::Retryable("SOURCE_UNAVAILABLE", status.to_string()));
    }
    if status == StatusCode::UNAUTHORIZED || status == StatusCode::FORBIDDEN {
        return Err(Failure::Terminal(
            "SOURCE_AUTHORIZATION_FAILED",
            status.to_string(),
        ));
    }
    if !status.is_success() {
        return Err(Failure::Terminal(
            "SOURCE_REQUEST_REJECTED",
            status.to_string(),
        ));
    }
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("application/octet-stream")
        .split(';')
        .next()
        .unwrap_or("application/octet-stream")
        .to_owned();
    let bytes = response
        .bytes()
        .await
        .map_err(|error| Failure::Retryable("SOURCE_UNAVAILABLE", error.to_string()))?;
    if bytes.len() > 67_108_864 {
        return Err(Failure::Terminal(
            "SOURCE_PAYLOAD_TOO_LARGE",
            bytes.len().to_string(),
        ));
    }
    Ok(SourceResponse {
        bytes: bytes.to_vec(),
        content_type,
        http_status: status.as_u16(),
    })
}

fn validate_manifest(bytes: &[u8]) -> Result<Vec<ManifestDocument>, Failure> {
    let value: Value = serde_json::from_slice(bytes)
        .map_err(|error| Failure::Terminal("SOURCE_MANIFEST_INVALID", error.to_string()))?;
    if value.get("manifest_version").and_then(Value::as_str) != Some("1")
        || value.get("publisher").and_then(Value::as_str).is_none()
        || value.get("generated_at").and_then(Value::as_str).is_none()
    {
        return Err(Failure::Terminal(
            "SOURCE_MANIFEST_INVALID",
            "header".into(),
        ));
    }
    let documents = value
        .get("documents")
        .and_then(Value::as_array)
        .ok_or_else(|| Failure::Terminal("SOURCE_MANIFEST_INVALID", "documents".into()))?;
    documents
        .iter()
        .filter(|document| document.get("deleted").and_then(Value::as_bool) != Some(true))
        .map(|document| {
            Ok(ManifestDocument {
                external_id: required_text(document, "external_id")?.to_owned(),
                revision: required_text(document, "revision")?.to_owned(),
                target: validate_target(required_text(document, "url")?)?,
                content_type: required_text(document, "content_type")?.to_owned(),
                published_at: Some(required_text(document, "published_at")?.to_owned()),
            })
        })
        .collect()
}

fn required_text<'a>(value: &'a Value, key: &str) -> Result<&'a str, Failure> {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| Failure::Terminal("SOURCE_MANIFEST_INVALID", key.into()))
}

async fn mark_source_terminal(
    pool: &PgPool,
    run_id: Uuid,
    source_id: &str,
    code: &str,
) -> Result<(), Failure> {
    let mut tx = pool.begin().await.map_err(database)?;
    sqlx::query(
        "UPDATE ops.source_runs SET status='FAILED',error_detail=$2,completed_at=clock_timestamp() \
         WHERE id=$1 AND status='RUNNING'",
    )
    .bind(run_id)
    .bind(code)
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    sqlx::query(
        "INSERT INTO ops.source_incidents(source_id,source_run_id,severity,incident_type,summary,impact,status) \
         VALUES($1,$2,'MAJOR',$3,'Source run terminal failure',$4,'OPEN')",
    )
    .bind(source_id)
    .bind(run_id)
    .bind(code)
    .bind(json!({"sourceRunId":run_id,"errorCode":code}))
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    if code == "SOURCE_AUTHORIZATION_FAILED" {
        sqlx::query("UPDATE ops.source_registry SET enabled=false WHERE source_id=$1")
            .bind(source_id)
            .execute(&mut *tx)
            .await
            .map_err(database)?;
    }
    tx.commit().await.map_err(database)?;
    Ok(())
}

async fn put_object(store: &Store, key: &str, bytes: Vec<u8>, digest: &str) -> Result<(), Failure> {
    let result = match store {
        Store::Filesystem(client) => client.put(key, bytes, digest).await,
        Store::Gateway(client) => client.put(key, bytes, digest).await,
    };
    result.map(|_| ()).map_err(object_store)
}

async fn persist_structured_json(
    tx: &mut Transaction<'_, Postgres>,
    source_id: &str,
    operation: &ConnectorOperation,
    document_id: Uuid,
    bytes: &[u8],
) -> Result<(), Failure> {
    let value: Value = serde_json::from_slice(bytes)
        .map_err(|error| Failure::Terminal("SOURCE_PAYLOAD_MALFORMED", error.to_string()))?;
    let records = structured_records(source_id, operation, &value);
    for (index, record) in records.iter().enumerate() {
        let record_bytes = serde_json::to_vec(record)
            .map_err(|error| Failure::Terminal("SOURCE_PAYLOAD_MALFORMED", error.to_string()))?;
        sqlx::query(
            "INSERT INTO raw.parsed_records(source_document_id,record_type,record_index,parser_version,payload,payload_sha256) \
             VALUES($1,$2,$3,'connector-structured-json-v1',$4,$5) \
             ON CONFLICT(source_document_id,record_type,record_index,parser_version) DO NOTHING",
        )
        .bind(document_id)
        .bind(operation.kind.to_ascii_uppercase())
        .bind(i32::try_from(index).map_err(|_| {
            Failure::Terminal("SOURCE_RECORD_LIMIT", operation.id.to_owned())
        })?)
        .bind(record)
        .bind(sha256(&record_bytes))
        .execute(&mut **tx)
        .await
        .map_err(database)?;
        if source_id == "koneps-contracts" {
            normalize_koneps_contract(tx, source_id, operation, document_id, index, record).await?;
        } else if source_id == "open-dart" {
            normalize_dart_supplier(tx, document_id, record).await?;
        }
    }
    sqlx::query(
        "SELECT raw.mark_connector_source_document_parsed($1,$2,$3,$4,$5)",
    )
    .bind(document_id)
    .bind("connector-structured-json")
    .bind("connector-structured-json-v1")
    .bind("v1")
    .bind(json!({"structuredRecordCount":records.len(),"connectorOperationId":operation.id}))
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    Ok(())
}

fn structured_records(
    source_id: &str,
    operation: &ConnectorOperation,
    value: &Value,
) -> Vec<Value> {
    let candidate = if source_id.starts_with("koneps-") {
        value
            .pointer("/response/body/items/item")
            .or_else(|| value.pointer("/response/body/items"))
    } else if source_id == "open-dart" {
        value.get("list").or(Some(value))
    } else if operation.kind == "manifest" {
        value.get("documents")
    } else {
        value.get("records").or(Some(value))
    };
    match candidate {
        Some(Value::Array(values)) => values.clone(),
        Some(Value::Object(values)) if !values.is_empty() => vec![Value::Object(values.clone())],
        _ => Vec::new(),
    }
}

async fn normalize_koneps_contract(
    tx: &mut Transaction<'_, Postgres>,
    source_id: &str,
    operation: &ConnectorOperation,
    document_id: Uuid,
    index: usize,
    record: &Value,
) -> Result<(), Failure> {
    let Some(external_id) = first_text(record, &["untyCntrctNo", "cntrctNo"]) else {
        return data_quality_incident(
            tx,
            source_id,
            document_id,
            operation.id,
            "CONTRACT_ID_MISSING",
        )
        .await;
    };
    let Some(title) = first_text(record, &["cntrctNm"]) else {
        return data_quality_incident(
            tx,
            source_id,
            document_id,
            operation.id,
            "CONTRACT_TITLE_MISSING",
        )
        .await;
    };
    let Some(agency_name) = first_text(record, &["cntrctInsttNm", "dminsttNm"]) else {
        return data_quality_incident(
            tx,
            source_id,
            document_id,
            operation.id,
            "AGENCY_NAME_MISSING",
        )
        .await;
    };
    let agency_identifier = first_text(record, &["cntrctInsttCd", "dminsttCd"]);
    let agency_id = resolve_agency(tx, agency_name, agency_identifier, document_id).await?;
    let supplier_name = first_text(record, &["corpNm", "cntrctCorpNm"]);
    let supplier_identifier = first_text(record, &["bizno", "corpBizno"]);
    let supplier_id = match supplier_name {
        Some(name) => Some(resolve_supplier(tx, name, supplier_identifier, document_id).await?),
        None => None,
    };
    let amount = first_text_or_number(record, &["thtmCntrctAmt", "totCntrctAmt", "cntrctAmt"]);
    let signed_at = first_text(record, &["cntrctCnclsDate", "cntrctDt"]).and_then(normalize_date);
    let contract_id: Uuid = sqlx::query_scalar(
        "INSERT INTO core.contracts(source_id,external_contract_id,contract_number,title,agency_id, \
           supplier_id,status,signed_at,original_amount,current_amount,normalization_version, \
           source_document_id,source_record_locator) \
         VALUES($1,$2,$2,$3,$4,$5,'ACTIVE',$6::date,NULLIF($7,'')::numeric,NULLIF($7,'')::numeric, \
           'connector-v1',$8,$9) \
         ON CONFLICT(source_id,external_contract_id) DO UPDATE SET title=EXCLUDED.title, \
           agency_id=EXCLUDED.agency_id,supplier_id=EXCLUDED.supplier_id,signed_at=EXCLUDED.signed_at, \
           current_amount=EXCLUDED.current_amount,source_document_id=EXCLUDED.source_document_id, \
           source_record_locator=EXCLUDED.source_record_locator,version=core.contracts.version+1 \
         RETURNING id",
    )
    .bind(source_id)
    .bind(external_id)
    .bind(title)
    .bind(agency_id)
    .bind(supplier_id)
    .bind(signed_at.as_deref())
    .bind(amount.as_deref().unwrap_or(""))
    .bind(document_id)
    .bind(format!("json-pointer:/response/body/items/item/{index}"))
    .fetch_one(&mut **tx)
    .await
    .map_err(database)?;
    sqlx::query(
        "INSERT INTO core.field_provenance(entity_type,entity_id,field_path,source_document_id, \
           source_locator,raw_value,normalized_value,transformation,parser_version,normalization_version) \
         VALUES('CONTRACT',$1,'title',$2,$3,$4,$5,'alias-list:first-non-empty', \
           'connector-structured-json-v1','connector-v1') ON CONFLICT DO NOTHING",
    )
    .bind(contract_id)
    .bind(document_id)
    .bind(format!("json-pointer:/response/body/items/item/{index}/cntrctNm"))
    .bind(json!(title))
    .bind(json!(title))
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    Ok(())
}

async fn normalize_dart_supplier(
    tx: &mut Transaction<'_, Postgres>,
    document_id: Uuid,
    record: &Value,
) -> Result<(), Failure> {
    let Some(corp_code) = first_text(record, &["corp_code"]) else {
        return Ok(());
    };
    let Some(name) = first_text(record, &["corp_name"]) else {
        return Ok(());
    };
    let _ = resolve_supplier(tx, name, Some(corp_code), document_id).await?;
    Ok(())
}

async fn resolve_agency(
    tx: &mut Transaction<'_, Postgres>,
    name: &str,
    identifier: Option<&str>,
    document_id: Uuid,
) -> Result<Uuid, Failure> {
    if let Some(identifier) = identifier
        && let Some(id) = sqlx::query_scalar::<_, Uuid>(
            "SELECT agency_id FROM core.agency_identifiers WHERE scheme='KONEPS' AND value=$1",
        )
        .bind(identifier)
        .fetch_optional(&mut **tx)
        .await
        .map_err(database)?
    {
        return Ok(id);
    }
    if let Some(id) = sqlx::query_scalar::<_, Uuid>(
        "SELECT id FROM core.agencies WHERE canonical_name=$1 ORDER BY created_at LIMIT 1",
    )
    .bind(name)
    .fetch_optional(&mut **tx)
    .await
    .map_err(database)?
    {
        return Ok(id);
    }
    let id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO core.agencies(id,canonical_name,agency_type,jurisdiction,identity_confidence,identity_status) \
         VALUES($1,$2,'PUBLIC_AGENCY','KR',1,'VERIFIED')",
    )
    .bind(id)
    .bind(name)
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    if let Some(identifier) = identifier {
        sqlx::query(
            "INSERT INTO core.agency_identifiers(agency_id,scheme,value,source_document_id) \
             VALUES($1,'KONEPS',$2,$3) ON CONFLICT DO NOTHING",
        )
        .bind(id)
        .bind(identifier)
        .bind(document_id)
        .execute(&mut **tx)
        .await
        .map_err(database)?;
    }
    Ok(id)
}

async fn resolve_supplier(
    tx: &mut Transaction<'_, Postgres>,
    name: &str,
    identifier: Option<&str>,
    document_id: Uuid,
) -> Result<Uuid, Failure> {
    let identifier_hash = identifier.map(|value| sha256(value.as_bytes()));
    if let Some(hash) = &identifier_hash
        && let Some(id) = sqlx::query_scalar::<_, Uuid>(
            "SELECT supplier_id FROM core.supplier_identifiers WHERE scheme IN ('BUSINESS_NUMBER','DART_CORP_CODE') AND value_hash=$1",
        )
        .bind(hash)
        .fetch_optional(&mut **tx)
        .await
        .map_err(database)?
    {
        return Ok(id);
    }
    if let Some(id) = sqlx::query_scalar::<_, Uuid>(
        "SELECT id FROM core.suppliers WHERE canonical_name=$1 ORDER BY created_at LIMIT 1",
    )
    .bind(name)
    .fetch_optional(&mut **tx)
    .await
    .map_err(database)?
    {
        return Ok(id);
    }
    let id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO core.suppliers(id,canonical_name,identity_confidence,identity_status) \
         VALUES($1,$2,0.9,'VERIFIED')",
    )
    .bind(id)
    .bind(name)
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    if let (Some(identifier), Some(hash)) = (identifier, identifier_hash) {
        let scheme = if identifier.len() == 8 {
            "DART_CORP_CODE"
        } else {
            "BUSINESS_NUMBER"
        };
        let display = if identifier.len() > 4 {
            format!("***{}", &identifier[identifier.len() - 4..])
        } else {
            "***".to_owned()
        };
        sqlx::query(
            "INSERT INTO core.supplier_identifiers(supplier_id,scheme,value_hash,display_value, \
               source_document_id,verification_status) VALUES($1,$2,$3,$4,$5,'VERIFIED') \
             ON CONFLICT DO NOTHING",
        )
        .bind(id)
        .bind(scheme)
        .bind(hash)
        .bind(display)
        .bind(document_id)
        .execute(&mut **tx)
        .await
        .map_err(database)?;
    }
    Ok(id)
}
