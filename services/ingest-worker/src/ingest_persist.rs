async fn data_quality_incident(
    tx: &mut Transaction<'_, Postgres>,
    source_id: &str,
    document_id: Uuid,
    operation_id: &str,
    code: &str,
) -> Result<(), Failure> {
    sqlx::query(
        "INSERT INTO ops.source_incidents(source_id,severity,incident_type,summary,impact,status) \
         VALUES($1,'MINOR',$2,'Structured record missing required canonical field',$3,'OPEN')",
    )
    .bind(source_id)
    .bind(code)
    .bind(json!({"sourceDocumentId":document_id,"operationId":operation_id}))
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    Ok(())
}

fn first_text<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a str> {
    keys.iter().find_map(|key| {
        value
            .get(*key)
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
    })
}

fn first_text_or_number(value: &Value, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| match value.get(*key) {
        Some(Value::String(value)) if !value.trim().is_empty() => Some(value.clone()),
        Some(Value::Number(value)) => Some(value.to_string()),
        _ => None,
    })
}

fn normalize_date(value: &str) -> Option<String> {
    let digits = value
        .chars()
        .filter(char::is_ascii_digit)
        .collect::<String>();
    if digits.len() < 8 {
        return None;
    }
    Some(format!(
        "{}-{}-{}",
        &digits[0..4],
        &digits[4..6],
        &digits[6..8]
    ))
}

async fn persist_schema_drift(
    tx: &mut Transaction<'_, Postgres>,
    source_id: &str,
    document_id: Uuid,
    before: &str,
    after: &str,
) -> Result<(), Failure> {
    let drift_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO ops.schema_drifts(id,source_id,detected_at,fingerprint_before, \
         fingerprint_after,sample_document_ids,status,impact) \
         VALUES($1,$2,clock_timestamp(),$3,$4,$5,'OPEN','UNKNOWN')",
    )
    .bind(drift_id)
    .bind(source_id)
    .bind(before)
    .bind(after)
    .bind(json!([document_id]))
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    sqlx::query(
        "SELECT ops.enqueue_outbox('schema_drift',$1,1,'source.schema_drift_detected.v1',$2,clock_timestamp())",
    )
    .bind(drift_id.to_string())
    .bind(json!({"schema_drift_id":drift_id,"source_id":source_id,"fingerprint_before":before,"fingerprint_after":after}))
    .fetch_one(&mut **tx)
    .await
    .map_err(database)?;
    Ok(())
}

fn validate_extraction(
    extraction: &Value,
    source_digest: &str,
    parser_version: &str,
) -> Result<(), Failure> {
    let object = extraction.as_object().ok_or_else(|| {
        Failure::Terminal("PARSED_OBJECT_INVALID", "root must be an object".to_owned())
    })?;
    if text_object(object, "documentSha256") != Some(source_digest)
        || text_object(object, "parserVersion") != Some(parser_version)
        || text_object(object, "status") != Some("EXTRACTED")
        || object.get("pages").and_then(Value::as_array).is_none()
    {
        return Err(Failure::Terminal(
            "PARSED_OBJECT_CONTRACT_MISMATCH",
            "digest, parser version, status, or pages mismatch".to_owned(),
        ));
    }
    Ok(())
}

fn flatten_records(extraction: &Value) -> Result<Vec<Value>, Failure> {
    let pages = extraction
        .get("pages")
        .and_then(Value::as_array)
        .ok_or_else(|| Failure::Terminal("PARSED_OBJECT_INVALID", "pages missing".to_owned()))?;
    let mut records = Vec::new();
    for page in pages {
        let page_index = page.get("index").cloned().unwrap_or_else(|| json!(0));
        for block in page
            .get("blocks")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            records.push(json!({"recordType":"BLOCK","pageIndex":page_index,"block":block}));
        }
        for table in page
            .get("tables")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            let table_id = table.get("id").cloned().unwrap_or(Value::Null);
            for (row_index, row) in table
                .get("rows")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .enumerate()
            {
                records.push(json!({
                    "recordType":"TABLE_ROW","pageIndex":page_index,"tableId":table_id,
                    "rowIndex":row_index,"cells":row,
                }));
            }
        }
    }
    if records.len() > 1_000_000 {
        return Err(Failure::Terminal(
            "PARSED_RECORD_LIMIT",
            format!("{} records exceed limit", records.len()),
        ));
    }
    if records.is_empty() {
        records.push(json!({"recordType":"DOCUMENT","pages":pages.len()}));
    }
    Ok(records)
}

fn schema_fingerprint(records: &[Value]) -> Result<String, Failure> {
    let mut shapes = BTreeMap::<String, Value>::new();
    for record in records {
        let record_type = record
            .get("recordType")
            .and_then(Value::as_str)
            .unwrap_or("UNKNOWN")
            .to_owned();
        shapes.insert(record_type, shape(record));
    }
    serde_json::to_vec(&shapes)
        .map(|bytes| sha256(&bytes))
        .map_err(|error| Failure::Terminal("SCHEMA_FINGERPRINT_FAILED", error.to_string()))
}

fn shape(value: &Value) -> Value {
    match value {
        Value::Null => json!("null"),
        Value::Bool(_) => json!("boolean"),
        Value::Number(_) => json!("number"),
        Value::String(_) => json!("string"),
        Value::Array(values) => {
            let mut variants = values
                .iter()
                .map(shape)
                .map(|value| serde_json::to_string(&value).unwrap_or_default())
                .collect::<Vec<_>>();
            variants.sort();
            variants.dedup();
            json!({"array":variants})
        }
        Value::Object(values) => Value::Object(
            values
                .iter()
                .map(|(key, value)| (key.clone(), shape(value)))
                .collect(),
        ),
    }
}

async fn inbox_processed(pool: &PgPool, event_id: Uuid) -> Result<bool, Failure> {
    sqlx::query_scalar(
        "SELECT processed_at IS NOT NULL FROM ops.inbox WHERE consumer='ingest-worker' AND event_id=$1",
    )
    .bind(event_id)
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("INBOX_RECORD_MISSING", event_id.to_string()))
}

async fn update_inbox(tx: &mut Transaction<'_, Postgres>, event_id: Uuid) -> Result<(), Failure> {
    let changed = sqlx::query(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' \
         WHERE consumer='ingest-worker' AND event_id=$1 AND processed_at IS NULL",
    )
    .bind(event_id)
    .execute(&mut **tx)
    .await
    .map_err(database)?
    .rows_affected();
    if changed == 1 {
        Ok(())
    } else {
        Err(Failure::Terminal("STALE_INBOX", event_id.to_string()))
    }
}

async fn get(store: &Store, key: &str, digest: &str) -> Result<Vec<u8>, ObjectStoreError> {
    match store {
        Store::Filesystem(client) => client.get(key, Some(digest)).await,
        Store::Gateway(client) => client.get(key, Some(digest)).await,
    }
}

fn text_object<'a>(object: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    object.get(key).and_then(Value::as_str)
}

fn uuid_object(object: &Map<String, Value>, key: &str) -> Option<Uuid> {
    text_object(object, key).and_then(|value| Uuid::parse_str(value).ok())
}

fn uuid(value: &Value, key: &str) -> Option<Uuid> {
    value
        .get(key)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
}

fn is_sha256(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn sha256(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn database(error: sqlx::Error) -> Failure {
    Failure::Retryable("DATABASE_UNAVAILABLE", error.to_string())
}

fn object_store(error: ObjectStoreError) -> Failure {
    match error {
        ObjectStoreError::DigestMismatch | ObjectStoreError::InvalidKey => {
            Failure::Terminal("PARSED_OBJECT_INTEGRITY_FAILURE", error.to_string())
        }
        ObjectStoreError::Backend(_) => {
            Failure::Retryable("OBJECT_STORE_UNAVAILABLE", error.to_string())
        }
    }
}

