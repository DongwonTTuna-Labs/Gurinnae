async fn terminal_document(
    pool: &PgPool,
    event_id: Uuid,
    document: &SourceDocument,
    status: &str,
    code: &str,
    detail: &str,
) -> Result<Value, Failure> {
    let result = ExtractionResult {
        document_sha256: document.content_sha256.clone(),
        media_type: document.content_type.clone(),
        parser_id: "document-extractor".to_owned(),
        parser_version: "integrity-v1".to_owned(),
        status: ExtractionStatus::Rejected,
        pages: Vec::new(),
        warnings: Vec::new(),
        rejection_code: Some(code.to_owned()),
    };
    let value = persist_terminal(pool, event_id, document, &result, status, code).await?;
    tracing::warn!(source_document_id=%document.id,error_code=code,error_detail=detail,"document rejected");
    Ok(value)
}

async fn inbox_processed(pool: &PgPool, event_id: Uuid) -> Result<bool, Failure> {
    sqlx::query_scalar(
        "SELECT processed_at IS NOT NULL FROM ops.inbox WHERE consumer='document-extractor' AND event_id=$1",
    )
    .bind(event_id)
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("INBOX_RECORD_MISSING", event_id.to_string()))
}

async fn mark_inbox(pool: &PgPool, event_id: Uuid, result: &str) -> Result<(), Failure> {
    let changed = sqlx::query(
        "UPDATE ops.inbox SET processed_at=COALESCE(processed_at,clock_timestamp()),result=$2 \
         WHERE consumer='document-extractor' AND event_id=$1",
    )
    .bind(event_id)
    .bind(result)
    .execute(pool)
    .await
    .map_err(database)?
    .rows_affected();
    if changed == 1 {
        Ok(())
    } else {
        Err(Failure::Terminal(
            "INBOX_RECORD_MISSING",
            event_id.to_string(),
        ))
    }
}

async fn update_inbox(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    event_id: Uuid,
    result: &str,
) -> Result<(), Failure> {
    let changed = sqlx::query(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result=$2 \
         WHERE consumer='document-extractor' AND event_id=$1 AND processed_at IS NULL",
    )
    .bind(event_id)
    .bind(result)
    .execute(&mut **tx)
    .await
    .map_err(database)?
    .rows_affected();
    if changed == 1 {
        Ok(())
    } else {
        Err(Failure::Terminal(
            "STALE_INBOX_RECORD",
            event_id.to_string(),
        ))
    }
}

fn prompt_injection_flags(result: &ExtractionResult) -> Value {
    let suspicious = result.pages.iter().any(|page| {
        page.blocks.iter().any(|block| {
            let value = block.text.to_ascii_lowercase();
            [
                "ignore previous instructions",
                "ignore all previous instructions",
                "system prompt",
                "developer message",
                "do not trust the user",
                "이전 지시를 무시",
                "시스템 프롬프트",
            ]
            .iter()
            .any(|needle| value.contains(needle))
        })
    });
    if suspicious {
        json!(["prompt_injection_detected"])
    } else {
        json!([])
    }
}

struct TempDocument {
    path: PathBuf,
}

impl TempDocument {
    async fn create(document: &SourceDocument, bytes: &[u8]) -> Result<Self, std::io::Error> {
        let directory = std::env::temp_dir().join("gurine-document-extractor");
        tokio::fs::create_dir_all(&directory).await?;
        let extension = extension(&document.content_type, &document.object_key);
        let path = directory.join(format!("{}.{extension}", Uuid::new_v4()));
        tokio::fs::write(&path, bytes).await?;
        Ok(Self { path })
    }
}

impl Drop for TempDocument {
    fn drop(&mut self) {
        if let Err(error) = std::fs::remove_file(&self.path)
            && error.kind() != std::io::ErrorKind::NotFound
        {
            tracing::warn!(path=%self.path.display(),%error,"temporary document cleanup failed");
        }
    }
}

fn extension(content_type: &str, object_key: &str) -> &'static str {
    match content_type
        .split(';')
        .next()
        .unwrap_or(content_type)
        .trim()
    {
        "text/csv" => "csv",
        "application/xml" | "text/xml" => "xml",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => "xlsx",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => "docx",
        "application/hwp+zip" => "hwpx",
        "application/pdf" => "pdf",
        "application/x-hwp" => "hwp",
        _ if Path::new(object_key)
            .extension()
            .and_then(|value| value.to_str())
            == Some("pdf") =>
        {
            "pdf"
        }
        _ => "bin",
    }
}

async fn get(store: &Store, key: &str, digest: &str) -> Result<Vec<u8>, ObjectStoreError> {
    match store {
        Store::Filesystem(client) => client.get(key, Some(digest)).await,
        Store::Gateway(client) => client.get(key, Some(digest)).await,
    }
}

async fn put(
    store: &Store,
    key: &str,
    bytes: Vec<u8>,
    digest: &str,
) -> Result<(), ObjectStoreError> {
    match store {
        Store::Filesystem(client) => client.put(key, bytes, digest).await.map(|_| ()),
        Store::Gateway(client) => client.put(key, bytes, digest).await.map(|_| ()),
    }
}

fn text<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

fn uuid(value: &Value, key: &str) -> Option<Uuid> {
    text(value, key).and_then(|value| Uuid::parse_str(value).ok())
}

fn database(error: sqlx::Error) -> Failure {
    Failure::Retryable("DATABASE_UNAVAILABLE", error.to_string())
}

fn map_job_error(error: JobError) -> WorkerError {
    match error {
        error @ (JobError::Database(_) | JobError::StaleFence) => WorkerError::Database(error),
        JobError::InvalidConfiguration => WorkerError::Initialization,
    }
}
