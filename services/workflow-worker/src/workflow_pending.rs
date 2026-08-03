async fn process_pending_scan(
    pool: &PgPool,
    store: &Store,
    scanner: &ClamAvScanner,
) -> Result<bool, WorkerError> {
    let mut transaction = pool.begin().await.map_err(|_| WorkerError::Database)?;
    let Some((kind, row)) = pending_attachment(&mut transaction).await? else {
        transaction
            .rollback()
            .await
            .map_err(|_| WorkerError::Database)?;
        return Ok(false);
    };
    let id = row.id;
    let locked = sqlx::query_scalar!(
        "SELECT pg_try_advisory_xact_lock(hashtextextended($1,0))",
        format!("attachment-scan:{id}"),
    )
    .fetch_one(&mut *transaction)
    .await
    .map_err(|_| WorkerError::Database)?
    .ok_or(WorkerError::Database)?;
    if !locked {
        transaction
            .rollback()
            .await
            .map_err(|_| WorkerError::Database)?;
        return Ok(false);
    }
    let key = row.object_key;
    let size = row.size_bytes;
    let digest = row.sha256.ok_or(WorkerError::Database)?;
    let bytes = get(store, &key, digest.trim())
        .await
        .map_err(|error| match error {
            ObjectStoreError::Backend(_) => WorkerError::Dependency,
            ObjectStoreError::DigestMismatch | ObjectStoreError::InvalidKey => {
                WorkerError::Database
            }
        })?;
    if i64::try_from(bytes.len()).ok() != Some(size) {
        return Err(WorkerError::Database);
    }
    let status = match scanner.scan(&bytes).await {
        Ok(ScanResult::Clean) => "CLEAN",
        Ok(ScanResult::Infected) => "INFECTED",
        Err(_) => return Err(WorkerError::Dependency),
    };
    let event_id = sqlx::query_scalar!(
        "SELECT ops.enqueue_outbox('attachment',$1,1,'attachment.scan_completed.v1',$2,clock_timestamp())",
        id.to_string(),
        json!({"attachment_id":id,"attachment_kind":kind,"scan_status":status,
            "sha256":digest.trim()}),
    )
    .fetch_one(&mut *transaction)
    .await
    .map_err(|_| WorkerError::Database)?
    .ok_or(WorkerError::Database)?;
    transaction
        .commit()
        .await
        .map_err(|_| WorkerError::Database)?;
    tracing::info!(attachment_id=%id, attachment_kind=%kind, scan_status=status, %event_id, "pending attachment scan completed");
    Ok(true)
}

struct PendingAttachmentRow {
    id: Uuid,
    object_key: String,
    size_bytes: i64,
    sha256: Option<String>,
}

async fn pending_attachment(
    transaction: &mut sqlx::Transaction<'_, sqlx::Postgres>,
) -> Result<Option<(&'static str, PendingAttachmentRow)>, WorkerError> {
    let correction = sqlx::query_as!(PendingAttachmentRow, "SELECT id,object_key,size_bytes,sha256::text AS \"sha256?\" \
                 FROM intake.correction_draft_attachments WHERE upload_status='FINALIZED' AND scan_status='PENDING' \
                 ORDER BY created_at,id LIMIT 1")
        .fetch_optional(&mut **transaction)
        .await
        .map_err(|_| WorkerError::Database)?;
    if let Some(row) = correction {
        return Ok(Some(("CORRECTION", row)));
    }
    let response = sqlx::query_as!(PendingAttachmentRow, "SELECT id,object_key,size_bytes,sha256::text AS \"sha256?\" \
                 FROM intake.response_attachments WHERE upload_status='FINALIZED' AND scan_status='PENDING' \
                 ORDER BY created_at,id LIMIT 1")
        .fetch_optional(&mut **transaction)
        .await
        .map_err(|_| WorkerError::Database)?;
    Ok(response.map(|row| ("RESPONSE", row)))
}

async fn get(store: &Store, key: &str, expected_sha256: &str) -> Result<Vec<u8>, ObjectStoreError> {
    match store {
        Store::Filesystem(client) => client.get(key, Some(expected_sha256)).await,
        Store::Gateway(client) => client.get(key, Some(expected_sha256)).await,
    }
}

async fn put(
    store: &Store,
    key: &str,
    bytes: Vec<u8>,
    expected_sha256: &str,
) -> Result<(), Failure> {
    let result = match store {
        Store::Filesystem(client) => client.put(key, bytes, expected_sha256).await,
        Store::Gateway(client) => client.put(key, bytes, expected_sha256).await,
    };
    match result {
        Ok(_) => Ok(()),
        Err(ObjectStoreError::InvalidKey | ObjectStoreError::DigestMismatch) => {
            Err(Failure::Terminal("OBJECT_STORE_CONTRACT", key.to_owned()))
        }
        Err(ObjectStoreError::Backend(error)) => Err(Failure::Retryable(
            "OBJECT_STORE_UNAVAILABLE",
            error.to_string(),
        )),
    }
}

fn value_uuid(value: &Value, key: &str) -> Result<Uuid, Failure> {
    value
        .get(key)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| Failure::Terminal("INVALID_EVENT", format!("{key} is invalid")))
}

fn object_uuid(value: &serde_json::Map<String, Value>, key: &str) -> Result<Uuid, Failure> {
    value
        .get(key)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| Failure::Terminal("INVALID_EVENT_PAYLOAD", format!("{key} is invalid")))
}

fn is_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
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

#[cfg(test)]
mod tests {
    use arrow_array::StringArray;
    use bytes::Bytes;
    use parquet::arrow::arrow_reader::ParquetRecordBatchReaderBuilder;
    use serde_json::json;

    use super::dataset_parquet;

    #[test]
    fn dataset_parquet_round_trips_with_apache_reader() {
        let bytes = dataset_parquet(
            "dataset-1",
            &json!({"title":"Dataset","description":"Description"}),
            &json!({"year":2026}),
        )
        .expect("parquet export");
        assert_eq!(&bytes[..4], b"PAR1");
        assert_eq!(&bytes[bytes.len() - 4..], b"PAR1");
        let mut reader = ParquetRecordBatchReaderBuilder::try_new(Bytes::from(bytes))
            .expect("parquet metadata")
            .build()
            .expect("parquet reader");
        let batch = reader.next().expect("one batch").expect("valid batch");
        assert_eq!(batch.num_rows(), 1);
        assert!(reader.next().is_none());
        let ids = batch
            .column(0)
            .as_any()
            .downcast_ref::<StringArray>()
            .expect("dataset_id string column");
        assert_eq!(ids.value(0), "dataset-1");
    }
}
