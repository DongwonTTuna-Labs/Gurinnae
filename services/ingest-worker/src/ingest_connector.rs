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
    let mut base = Url::parse(base)
        .map_err(|_| Failure::Terminal("SOURCE_BASE_URL_INVALID", operation.id.into()))?;
    if base.query().is_some() || base.fragment().is_some() {
        return Err(Failure::Terminal(
            "SOURCE_BASE_URL_INVALID",
            operation.id.into(),
        ));
    }
    if !base.path().ends_with('/') {
        let directory_path = format!("{}/", base.path());
        base.set_path(&directory_path);
    }
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

fn validate_manifest(source_id: &str, bytes: &[u8]) -> Result<Vec<ManifestDocument>, Failure> {
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
            let _title = required_text(document, "title")?;
            let content_type = required_text(document, "content_type")?;
            if !manifest_content_type_allowed(source_id, content_type) {
                return Err(Failure::Terminal(
                    "SOURCE_MANIFEST_INVALID",
                    "content_type".to_owned(),
                ));
            }
            let declared_sha256 = required_text(document, "sha256")?;
            if !is_sha256(declared_sha256) {
                return Err(Failure::Terminal(
                    "SOURCE_MANIFEST_INVALID",
                    "sha256".to_owned(),
                ));
            }
            Ok(ManifestDocument {
                external_id: required_text(document, "external_id")?.to_owned(),
                revision: required_text(document, "revision")?.to_owned(),
                target: validate_target(required_text(document, "url")?)?,
                content_type: content_type.to_owned(),
                sha256: Some(declared_sha256.to_owned()),
                published_at: Some(required_text(document, "published_at")?.to_owned()),
            })
        })
        .collect()
}

fn manifest_content_type_allowed(source_id: &str, content_type: &str) -> bool {
    if source_id == "pps-sanctions" {
        return matches!(content_type, "text/csv" | "application/csv");
    }
    matches!(
        content_type,
        "application/pdf" | "text/csv" | "application/csv"
    )
}

fn validate_declared_document_response(
    operation_kind: &str,
    target: &ManifestDocument,
    response: &SourceResponse,
    actual_sha256: &str,
) -> Result<(), Failure> {
    if operation_kind != "document" {
        return Ok(());
    }
    let declared_sha256 = target
        .sha256
        .as_deref()
        .ok_or_else(|| Failure::Terminal("SOURCE_MANIFEST_INVALID", "sha256".to_owned()))?;
    if declared_sha256 != actual_sha256 {
        return Err(Failure::Terminal(
            "SOURCE_DOCUMENT_DIGEST_MISMATCH",
            target.external_id.clone(),
        ));
    }
    if target.content_type != response.content_type {
        return Err(Failure::Terminal(
            "SOURCE_DOCUMENT_CONTENT_TYPE_MISMATCH",
            target.external_id.clone(),
        ));
    }
    Ok(())
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

#[expect(
    clippy::too_many_arguments,
    reason = "contract normalization binds the complete parsed-record provenance and supplier identity material"
)]
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
    supplier_identity::resolve_supplier(
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

#[cfg(test)]
mod manifest_integrity_tests {
    use super::{
        Failure, ManifestDocument, SourceResponse, validate_declared_document_response,
        validate_manifest,
    };

    #[test]
    fn manifest_requires_declared_sha256_and_closed_content_type() {
        let missing_sha = br#"{
          "manifest_version":"1","publisher":"fixture","generated_at":"2026-08-01T00:00:00Z",
          "documents":[{"external_id":"s-1","title":"fixture","url":"https://fixture.invalid/s.csv",
            "published_at":"2026-08-01T00:00:00Z","content_type":"text/csv","revision":"1"}]
        }"#;
        assert!(matches!(
            validate_manifest("pps-sanctions", missing_sha),
            Err(Failure::Terminal("SOURCE_MANIFEST_INVALID", _))
        ));

        let wrong_type = br#"{
          "manifest_version":"1","publisher":"fixture","generated_at":"2026-08-01T00:00:00Z",
          "documents":[{"external_id":"s-1","title":"fixture","url":"https://fixture.invalid/s.json",
            "published_at":"2026-08-01T00:00:00Z","content_type":"application/json","revision":"1",
            "sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]
        }"#;
        assert!(matches!(
            validate_manifest("pps-sanctions", wrong_type),
            Err(Failure::Terminal("SOURCE_MANIFEST_INVALID", _))
        ));
    }

    #[test]
    fn downloaded_document_must_match_declared_digest_and_content_type() {
        let target = ManifestDocument {
            external_id: "s-1".to_owned(),
            revision: "1".to_owned(),
            target: "https://fixture.invalid/s.csv".to_owned(),
            content_type: "text/csv".to_owned(),
            sha256: Some(
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".to_owned(),
            ),
            published_at: None,
        };
        let response = SourceResponse {
            bytes: b"fixture".to_vec(),
            content_type: "text/csv".to_owned(),
            http_status: 200,
        };
        assert!(matches!(
            validate_declared_document_response(
                "document",
                &target,
                &response,
                "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            ),
            Err(Failure::Terminal("SOURCE_DOCUMENT_DIGEST_MISMATCH", _))
        ));
    }
}
