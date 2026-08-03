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
    sqlx::query!(
        "UPDATE ops.source_runs SET status='FAILED',error_detail=$2,completed_at=clock_timestamp() \
         WHERE id=$1 AND status='RUNNING'",
        run_id,
        code,
    )
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    sqlx::query!(
        "INSERT INTO ops.source_incidents(source_id,source_run_id,severity,incident_type,summary,impact,status) \
         VALUES($1,$2,'MAJOR',$3,'Source run terminal failure',$4,'OPEN')",
        source_id,
        run_id,
        code,
        json!({"sourceRunId":run_id,"errorCode":code}),
    )
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    if code == "SOURCE_AUTHORIZATION_FAILED" {
        sqlx::query!(
            "UPDATE ops.source_registry SET enabled=false WHERE source_id=$1",
            source_id,
        )
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

include!("ingest_structured_persistence.rs");

struct KonepsContractFields<'a> {
    external_id: &'a str,
    title: &'a str,
    agency_name: &'a str,
    agency_identifier: Option<&'a str>,
    amount: Option<String>,
    signed_at: Option<String>,
}

async fn normalize_koneps_contract(
    tx: &mut Transaction<'_, Postgres>,
    source_id: &str,
    operation: &ConnectorOperation,
    document_id: Uuid,
    parsed_record_id: Uuid,
    record_index: i32,
    record_locator: &str,
    record: &Value,
    supplier_identifier_hmac_key: &[u8],
) -> Result<(), Failure> {
    let fields = match koneps_contract_fields(record) {
        Ok(fields) => fields,
        Err(code) => {
            return data_quality_incident(tx, source_id, document_id, operation.id, code).await;
        }
    };
    let agency_id = resolve_agency(
        tx,
        fields.agency_name,
        fields.agency_identifier,
        document_id,
    )
    .await?;
    observe_koneps_supplier(
        tx,
        document_id,
        parsed_record_id,
        record_index,
        record,
        supplier_identifier_hmac_key,
    )
    .await?;
    let contract_id = upsert_koneps_contract(
        tx,
        source_id,
        document_id,
        record_locator,
        agency_id,
        &fields,
    )
    .await?;
    persist_koneps_title_provenance(tx, document_id, record_locator, contract_id, fields.title)
        .await
}

fn koneps_contract_fields(record: &Value) -> Result<KonepsContractFields<'_>, &'static str> {
    let external_id =
        first_text(record, &["untyCntrctNo", "cntrctNo"]).ok_or("CONTRACT_ID_MISSING")?;
    let title = first_text(record, &["cntrctNm"]).ok_or("CONTRACT_TITLE_MISSING")?;
    let agency_name =
        first_text(record, &["cntrctInsttNm", "dminsttNm"]).ok_or("AGENCY_NAME_MISSING")?;
    Ok(KonepsContractFields {
        external_id,
        title,
        agency_name,
        agency_identifier: first_text(record, &["cntrctInsttCd", "dminsttCd"]),
        amount: first_text_or_number(record, &["thtmCntrctAmt", "totCntrctAmt", "cntrctAmt"]),
        signed_at: first_text(record, &["cntrctCnclsDate", "cntrctDt"]).and_then(normalize_date),
    })
}

async fn observe_koneps_supplier(
    tx: &mut Transaction<'_, Postgres>,
    document_id: Uuid,
    parsed_record_id: Uuid,
    record_index: i32,
    record: &Value,
    supplier_identifier_hmac_key: &[u8],
) -> Result<(), Failure> {
    let supplier_name = first_text_entry(record, &["corpNm", "cntrctCorpNm"]);
    let supplier_identifier = first_text_entry(record, &["bizno", "corpBizno"]);
    if let Some((_, name)) = supplier_name {
        let identifier = supplier_identifier.map(|(_, raw_value)| {
            supplier_identity::IncomingSupplierIdentifier {
                scheme: gurine_identity_resolution::supplier::StrongIdentifierScheme::KoreanBusinessNumber,
                raw_value,
            }
        });
        supplier_identity::resolve_supplier(
            tx,
            supplier_identifier_hmac_key,
            supplier_identity::IncomingSupplier {
                name,
                identifier,
                source_document_id: document_id,
                parsed_record_id,
                record_index,
            },
        )
        .await?;
    }
    Ok(())
}

async fn upsert_koneps_contract(
    tx: &mut Transaction<'_, Postgres>,
    source_id: &str,
    document_id: Uuid,
    record_locator: &str,
    agency_id: Uuid,
    fields: &KonepsContractFields<'_>,
) -> Result<Uuid, Failure> {
    let supplier_id: Option<Uuid> = None;
    sqlx::query_scalar!(
        "INSERT INTO core.contracts(source_id,external_contract_id,contract_number,title,agency_id, \
           supplier_id,status,signed_at,original_amount,current_amount,normalization_version, \
           source_document_id,source_record_locator) \
         VALUES($1,$2,$2,$3,$4,$5,'ACTIVE',$6::date,NULLIF($7,'')::numeric,NULLIF($7,'')::numeric, \
           'connector-v1',$8,$9) \
         ON CONFLICT(source_id,external_contract_id) DO UPDATE SET title=EXCLUDED.title, \
           agency_id=EXCLUDED.agency_id,signed_at=EXCLUDED.signed_at, \
           current_amount=EXCLUDED.current_amount,source_document_id=EXCLUDED.source_document_id, \
           source_record_locator=EXCLUDED.source_record_locator,version=core.contracts.version+1 \
         RETURNING id",
        source_id,
        fields.external_id,
        fields.title,
        agency_id,
        supplier_id,
        fields.signed_at.as_deref() as _,
        fields.amount.as_deref().unwrap_or(""),
        document_id,
        format!("json-pointer:{record_locator}"),
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(database)
}

async fn persist_koneps_title_provenance(
    tx: &mut Transaction<'_, Postgres>,
    document_id: Uuid,
    record_locator: &str,
    contract_id: Uuid,
    title: &str,
) -> Result<(), Failure> {
    sqlx::query!(
        "INSERT INTO core.field_provenance(entity_type,entity_id,field_path,source_document_id, \
           source_locator,raw_value,normalized_value,transformation,parser_version,normalization_version) \
         VALUES('CONTRACT',$1,'title',$2,$3,$4,$5,'alias-list:first-non-empty', \
           'connector-structured-json-v1','connector-v1') ON CONFLICT DO NOTHING",
        contract_id,
        document_id,
        format!("json-pointer:{record_locator}/cntrctNm"),
        json!(title),
        json!(title),
    )
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    Ok(())
}

async fn normalize_dart_supplier(
    tx: &mut Transaction<'_, Postgres>,
    document_id: Uuid,
    parsed_record_id: Uuid,
    record_index: i32,
    record: &Value,
    supplier_identifier_hmac_key: &[u8],
) -> Result<(), Failure> {
    let Some((_, corp_code)) = first_text_entry(record, &["corp_code"]) else {
        return Ok(());
    };
    let Some((_, name)) = first_text_entry(record, &["corp_name"]) else {
        return Ok(());
    };
    let _ = supplier_identity::resolve_supplier(
        tx,
        supplier_identifier_hmac_key,
        supplier_identity::IncomingSupplier {
            name,
            identifier: Some(supplier_identity::IncomingSupplierIdentifier {
                scheme:
                    gurine_identity_resolution::supplier::StrongIdentifierScheme::OpenDartCorpCode,
                raw_value: corp_code,
            }),
            source_document_id: document_id,
            parsed_record_id,
            record_index,
        },
    )
    .await?;
    Ok(())
}

async fn resolve_agency(
    tx: &mut Transaction<'_, Postgres>,
    name: &str,
    identifier: Option<&str>,
    document_id: Uuid,
) -> Result<Uuid, Failure> {
    if let Some(identifier) = identifier
        && let Some(id) = sqlx::query_scalar!(
            "SELECT agency_id FROM core.agency_identifiers WHERE scheme='KONEPS' AND value=$1",
            identifier,
        )
        .fetch_optional(&mut **tx)
        .await
        .map_err(database)?
    {
        return Ok(id);
    }
    if let Some(id) = sqlx::query_scalar!(
        "SELECT id FROM core.agencies WHERE canonical_name=$1 ORDER BY created_at LIMIT 1",
        name,
    )
    .fetch_optional(&mut **tx)
    .await
    .map_err(database)?
    {
        return Ok(id);
    }
    let id = Uuid::new_v4();
    sqlx::query!(
        "INSERT INTO core.agencies(id,canonical_name,agency_type,jurisdiction,identity_confidence,identity_status) \
         VALUES($1,$2,'PUBLIC_AGENCY','KR',1,'VERIFIED')",
        id,
        name,
    )
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    if let Some(identifier) = identifier {
        sqlx::query!(
            "INSERT INTO core.agency_identifiers(agency_id,scheme,value,source_document_id) \
             VALUES($1,'KONEPS',$2,$3) ON CONFLICT DO NOTHING",
            id,
            identifier,
            document_id,
        )
        .execute(&mut **tx)
        .await
        .map_err(database)?;
    }
    Ok(id)
}

fn first_text_entry<'a, 'b>(value: &'a Value, keys: &'b [&'b str]) -> Option<(&'b str, &'a str)> {
    keys.iter().find_map(|key| {
        value
            .get(*key)
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .map(|value| (*key, value))
    })
}
