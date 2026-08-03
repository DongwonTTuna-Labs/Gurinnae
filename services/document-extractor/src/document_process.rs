async fn process_claimed(pool: &PgPool, store: &Store, job: &ClaimedJob) -> Result<Value, Failure> {
    if job.job_type != "EVENT_DELIVERY"
        || text(&job.payload, "eventType") != Some("source.document_stored.v1")
    {
        return Err(Failure::Terminal(
            "UNSUPPORTED_JOB_TYPE",
            "document-extractor only accepts source.document_stored.v1".to_owned(),
        ));
    }
    let event_id = uuid(&job.payload, "eventId").ok_or_else(|| {
        Failure::Terminal("INVALID_EVENT", "eventId is missing or invalid".to_owned())
    })?;
    process_document_event(pool, store, job, event_id).await
}

async fn process_document_event(
    pool: &PgPool,
    store: &Store,
    job: &ClaimedJob,
    event_id: Uuid,
) -> Result<Value, Failure> {
    if inbox_processed(pool, event_id).await? {
        return Ok(json!({"deduplicated":true}));
    }
    let document = load_source_document(pool, job).await?;
    if document.status != "FETCHED" {
        if matches!(
            document.status.as_str(),
            "PARSED" | "REJECTED" | "QUARANTINED"
        ) {
            mark_inbox(pool, event_id, "DEDUPLICATED").await?;
            return Ok(json!({"deduplicated":true,"sourceDocumentStatus":document.status}));
        }
        return Err(Failure::Terminal(
            "INVALID_SOURCE_DOCUMENT_STATE",
            document.status,
        ));
    }
    let bytes = get(store, &document.object_key, &document.content_sha256)
        .await
        .map_err(|error| match error {
            ObjectStoreError::DigestMismatch | ObjectStoreError::InvalidKey => {
                Failure::Terminal("SOURCE_OBJECT_INTEGRITY_FAILURE", error.to_string())
            }
            ObjectStoreError::Backend(_) => {
                Failure::Retryable("OBJECT_STORE_UNAVAILABLE", error.to_string())
            }
        })?;
    if i64::try_from(bytes.len()).ok() != Some(document.content_size_bytes) {
        return terminal_document(
            pool,
            event_id,
            &document,
            "QUARANTINED",
            "SOURCE_OBJECT_SIZE_MISMATCH",
            "source object size does not match immutable metadata",
        )
        .await;
    }
    let temp = TempDocument::create(&document, &bytes)
        .await
        .map_err(|error| Failure::Retryable("TEMPFILE_UNAVAILABLE", error.to_string()))?;
    if matches!(
        detect_format(&bytes),
        Some("html" | "png" | "jpeg" | "webp" | "tiff" | "wav" | "webm")
    ) {
        return extract_multimodal_document(pool, store, event_id, &document, temp).await;
    }
    extract_standard_document(pool, store, event_id, &document, temp).await
}

async fn load_source_document(pool: &PgPool, job: &ClaimedJob) -> Result<SourceDocument, Failure> {
    let source_document_id = job
        .payload
        .pointer("/payload/source_document_id")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| {
            Failure::Terminal(
                "INVALID_EVENT_PAYLOAD",
                "source_document_id is missing or invalid".to_owned(),
            )
        })?;
    let row = sqlx::query!(
        "SELECT id,content_type,content_sha256,content_size_bytes,object_key,status::text status \
         FROM raw.source_documents WHERE id=$1",
        source_document_id,
    )
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| {
        Failure::Terminal("SOURCE_DOCUMENT_NOT_FOUND", source_document_id.to_string())
    })?;
    Ok(SourceDocument {
        id: row.id,
        content_type: row.content_type,
        content_sha256: row.content_sha256.trim().to_owned(),
        content_size_bytes: row.content_size_bytes,
        object_key: row.object_key,
        status: required_column(row.status, "\"status\"")?,
    })
}

async fn extract_multimodal_document(
    pool: &PgPool,
    store: &Store,
    event_id: Uuid,
    document: &SourceDocument,
    temp: TempDocument,
) -> Result<Value, Failure> {
    let binding = AssetBinding {
        // SourceDocument is the immutable asset identity at this boundary;
        // a later asset-revision repository can supply a distinct id.
        asset_id: document.id,
        asset_revision: 1,
        content_sha256: document.content_sha256.clone(),
    };
    let result = crate::extract_multimodal_path(&temp.path, binding)
        .await
        .map_err(|error| Failure::Retryable("EXTRACTION_IO_FAILURE", error.to_string()))?;
    drop(temp);
    if result.document_sha256 != document.content_sha256 {
        return terminal_document(
            pool,
            event_id,
            document,
            "QUARANTINED",
            "EXTRACTION_DIGEST_MISMATCH",
            "multimodal parser observed bytes different from immutable source digest",
        )
        .await;
    }
    return persist_multimodal_result(pool, store, event_id, document, &result).await;
}

async fn extract_standard_document(
    pool: &PgPool,
    store: &Store,
    event_id: Uuid,
    document: &SourceDocument,
    temp: TempDocument,
) -> Result<Value, Failure> {
    let result = crate::extract_path(&temp.path)
        .await
        .map_err(|error| Failure::Retryable("EXTRACTION_IO_FAILURE", error.to_string()))?;
    drop(temp);
    if result.document_sha256 != document.content_sha256 {
        return terminal_document(
            pool,
            event_id,
            document,
            "QUARANTINED",
            "EXTRACTION_DIGEST_MISMATCH",
            "parser observed bytes different from immutable source digest",
        )
        .await;
    }
    match result.status {
        ExtractionStatus::Extracted => {
            persist_success(pool, store, event_id, document, &result).await
        }
        ExtractionStatus::Rejected => {
            let code = result
                .rejection_code
                .as_deref()
                .unwrap_or("DOCUMENT_REJECTED");
            let status = if code.contains("HWP_UNSUPPORTED")
                || code.contains("ZIP_")
                || code.contains("EXTERNAL_RELATIONSHIP")
                || code.contains("ENCRYPTED_DOCUMENT")
            {
                "QUARANTINED"
            } else {
                "REJECTED"
            };
            persist_terminal(pool, event_id, document, &result, status, code).await
        }
        ExtractionStatus::Failed | ExtractionStatus::OcrRequired => Err(Failure::Retryable(
            "PARSER_RUNTIME_FAILURE",
            result
                .rejection_code
                .clone()
                .unwrap_or_else(|| "parser did not produce a terminal extraction".to_owned()),
        )),
    }
}

async fn persist_success(
    pool: &PgPool,
    store: &Store,
    event_id: Uuid,
    document: &SourceDocument,
    result: &ExtractionResult,
) -> Result<Value, Failure> {
    ensure_parser_active(pool, result).await?;
    let output = serde_json::to_vec(result)
        .map_err(|error| Failure::Terminal("EXTRACTION_SERIALIZATION_FAILED", error.to_string()))?;
    let output_digest = sha256_hex(&output);
    let output_key = format!("parsed/{}/{output_digest}.json", document.id);
    put(store, &output_key, output, &output_digest)
        .await
        .map_err(|error| match error {
            ObjectStoreError::DigestMismatch | ObjectStoreError::InvalidKey => {
                Failure::Terminal("PARSED_OBJECT_INTEGRITY_FAILURE", error.to_string())
            }
            ObjectStoreError::Backend(_) => {
                Failure::Retryable("OBJECT_STORE_UNAVAILABLE", error.to_string())
            }
        })?;
    let count = result
        .pages
        .iter()
        .map(|page| page.blocks.len() + page.tables.len())
        .sum::<usize>();
    let flags = prompt_injection_flags(result);
    let mut tx = pool.begin().await.map_err(database)?;
    sqlx::query!(
        "INSERT INTO core.parser_runs(source_document_id,parser_name,parser_version,status, \
         output_record_count,output_digest,started_at,completed_at) \
         VALUES($1,$2,$3,'SUCCEEDED',$4,$5,clock_timestamp(),clock_timestamp())",
        document.id,
        &result.parser_id,
        &result.parser_version,
        i32::try_from(count).map_err(|_| {
            Failure::Terminal(
                "OUTPUT_LIMIT_EXCEEDED",
                "record count exceeds i32".to_owned(),
            )
        })?,
        &output_digest,
    )
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    let changed = sqlx::query!(
        "UPDATE raw.source_documents SET status='PARSED',parser_name=$2,parser_version=$3, \
         schema_version='extraction-result-v1',prompt_injection_flags=$4,quarantine_reason=NULL \
         WHERE id=$1 AND status='FETCHED'",
        document.id,
        &result.parser_id,
        &result.parser_version,
        &flags,
    )
    .execute(&mut *tx)
    .await
    .map_err(database)?
    .rows_affected();
    if changed != 1 {
        return Err(Failure::Terminal(
            "STALE_SOURCE_DOCUMENT",
            document.id.to_string(),
        ));
    }
    sqlx::query!(
        "SELECT ops.enqueue_outbox('source_document',$1,1,'source.document_parsed.v1',$2,clock_timestamp())",
        document.id.to_string(),
        json!({
            "output_digest":output_digest,
            "parser_version":result.parser_version,
            "source_document_id":document.id,
        }),
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(database)?;
    update_inbox(&mut tx, event_id, "SUCCEEDED").await?;
    tx.commit().await.map_err(database)?;
    tracing::info!(source_document_id=%document.id,output_digest,"document extracted");
    Ok(json!({"outputDigest":output_digest,"outputKey":output_key,"recordCount":count}))
}

async fn persist_multimodal_result(
    pool: &PgPool,
    store: &Store,
    event_id: Uuid,
    document: &SourceDocument,
    result: &crate::multimodal::MultimodalExtractionResult,
) -> Result<Value, Failure> {
    ensure_multimodal_parser_active(pool, result).await?;
    let (output_key, output_digest) = write_multimodal_output(store, document, result).await?;
    let count = multimodal_record_count(result);
    let source_status = multimodal_source_status(result);
    let parser_status = multimodal_parser_status(result);
    let mut tx = pool.begin().await.map_err(database)?;
    insert_multimodal_parser_run(
        &mut tx,
        document,
        result,
        parser_status,
        count,
        &output_digest,
    )
    .await?;
    update_multimodal_source(&mut tx, document, result, source_status).await?;
    enqueue_multimodal_event(&mut tx, document, result, &output_digest).await?;
    update_inbox(&mut tx, event_id, source_status).await?;
    tx.commit().await.map_err(database)?;
    Ok(json!({
        "outputDigest": output_digest,
        "outputKey": output_key,
        "recordCount": count,
        "sourceDocumentStatus": source_status,
    }))
}

async fn ensure_multimodal_parser_active(
    pool: &PgPool,
    result: &crate::multimodal::MultimodalExtractionResult,
) -> Result<(), Failure> {
    let active = sqlx::query_scalar!(
        "SELECT EXISTS(SELECT 1 FROM core.parser_versions WHERE parser_name=$1 AND version=$2 \
         AND status='ACTIVE' AND btrim(implementation_digest::text)=$3 \
         AND supported_media_types ? $4)",
        &result.parser_id,
        &result.parser_version,
        PARSER_IMPLEMENTATION_DIGEST,
        &result.media_type,
    )
    .fetch_one(pool)
    .await
    .map_err(database)?;
    let active = required_column(active, "0")?;
    if active {
        Ok(())
    } else {
        Err(Failure::Terminal(
            "PARSER_REGISTRY_MISMATCH",
            format!(
                "{}:{}:{}",
                result.parser_id, result.parser_version, result.media_type
            ),
        ))
    }
}

async fn write_multimodal_output(
    store: &Store,
    document: &SourceDocument,
    result: &crate::multimodal::MultimodalExtractionResult,
) -> Result<(String, String), Failure> {
    let output = serde_json::to_vec(result)
        .map_err(|error| Failure::Terminal("EXTRACTION_SERIALIZATION_FAILED", error.to_string()))?;
    let output_digest = sha256_hex(&output);
    let output_key = format!("parsed/{}/{output_digest}.json", document.id);
    put(store, &output_key, output, &output_digest)
        .await
        .map_err(|error| match error {
            ObjectStoreError::DigestMismatch | ObjectStoreError::InvalidKey => {
                Failure::Terminal("PARSED_OBJECT_INTEGRITY_FAILURE", error.to_string())
            }
            ObjectStoreError::Backend(_) => {
                Failure::Retryable("OBJECT_STORE_UNAVAILABLE", error.to_string())
            }
        })?;
    Ok((output_key, output_digest))
}

fn multimodal_record_count(result: &crate::multimodal::MultimodalExtractionResult) -> usize {
    result
        .segments
        .len()
        .saturating_add(result.shots.len())
        .saturating_add(result.tables.len())
        .saturating_add(result.links.len())
}

fn multimodal_parser_status(
    result: &crate::multimodal::MultimodalExtractionResult,
) -> &'static str {
    match result.status {
        MultimodalStatus::Extracted => "SUCCEEDED",
        MultimodalStatus::Rejected | MultimodalStatus::Failed => "FAILED",
    }
}

fn multimodal_source_status(
    result: &crate::multimodal::MultimodalExtractionResult,
) -> &'static str {
    match result.status {
        MultimodalStatus::Extracted => "PARSED",
        MultimodalStatus::Rejected | MultimodalStatus::Failed => "REJECTED",
    }
}

async fn insert_multimodal_parser_run(
    tx: &mut sqlx::PgConnection,
    document: &SourceDocument,
    result: &crate::multimodal::MultimodalExtractionResult,
    parser_status: &str,
    count: usize,
    output_digest: &str,
) -> Result<(), Failure> {
    sqlx::query!(
        "INSERT INTO core.parser_runs(source_document_id,parser_name,parser_version,status,output_record_count,output_digest,error_code,started_at,completed_at) VALUES($1,$2,$3,$4,$5,$6,$7,clock_timestamp(),clock_timestamp())",
        document.id,
        &result.parser_id,
        &result.parser_version,
        parser_status,
        i32::try_from(count).map_err(|_| Failure::Terminal(
            "OUTPUT_LIMIT_EXCEEDED",
            "record count exceeds i32".to_owned()
        ))?,
        output_digest,
        result.rejection_code.as_deref(),
    )
    .execute(tx)
    .await
    .map_err(database)?;
    Ok(())
}

async fn update_multimodal_source(
    tx: &mut sqlx::PgConnection,
    document: &SourceDocument,
    result: &crate::multimodal::MultimodalExtractionResult,
    source_status: &str,
) -> Result<(), Failure> {
    let changed = sqlx::query!(
        "UPDATE raw.source_documents SET status=$2::core.source_document_status,parser_name=$3,parser_version=$4,schema_version='multimodal-extraction-result.v2',prompt_injection_flags='[]'::jsonb,quarantine_reason=$5 WHERE id=$1 AND status='FETCHED'",
        document.id,
        source_status as _,
        &result.parser_id,
        &result.parser_version,
        result.rejection_code.as_deref(),
    )
    .execute(tx)
    .await
    .map_err(database)?
    .rows_affected();
    if changed == 1 {
        Ok(())
    } else {
        Err(Failure::Terminal(
            "STALE_SOURCE_DOCUMENT",
            document.id.to_string(),
        ))
    }
}

async fn enqueue_multimodal_event(
    tx: &mut sqlx::PgConnection,
    document: &SourceDocument,
    result: &crate::multimodal::MultimodalExtractionResult,
    output_digest: &str,
) -> Result<(), Failure> {
    sqlx::query!(
        "SELECT ops.enqueue_outbox('source_document',$1,1,'source.document_parsed.v1',$2,clock_timestamp())",
        document.id.to_string(),
        json!({"output_digest":output_digest,"extraction_digest":result.extraction_sha256,"parser_version":result.parser_version,"source_document_id":document.id}),
    )
    .fetch_one(tx)
    .await
    .map_err(database)?;
    Ok(())
}

async fn persist_terminal(
    pool: &PgPool,
    event_id: Uuid,
    document: &SourceDocument,
    result: &ExtractionResult,
    status: &str,
    code: &str,
) -> Result<Value, Failure> {
    ensure_parser_active(pool, result).await?;
    let parser_status = if status == "QUARANTINED" {
        "QUARANTINED"
    } else {
        "FAILED"
    };
    let mut tx = pool.begin().await.map_err(database)?;
    sqlx::query!(
        "INSERT INTO core.parser_runs(source_document_id,parser_name,parser_version,status, \
         output_record_count,error_code,started_at,completed_at) \
         VALUES($1,$2,$3,$4,0,$5,clock_timestamp(),clock_timestamp())",
        document.id,
        &result.parser_id,
        &result.parser_version,
        parser_status,
        code,
    )
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    let changed = sqlx::query!(
        "UPDATE raw.source_documents SET status=$2::core.source_document_status,parser_name=$3, \
         parser_version=$4,quarantine_reason=$5 WHERE id=$1 AND status='FETCHED'",
        document.id,
        status as _,
        &result.parser_id,
        &result.parser_version,
        code,
    )
    .execute(&mut *tx)
    .await
    .map_err(database)?
    .rows_affected();
    if changed != 1 {
        return Err(Failure::Terminal(
            "STALE_SOURCE_DOCUMENT",
            document.id.to_string(),
        ));
    }
    update_inbox(&mut tx, event_id, status).await?;
    tx.commit().await.map_err(database)?;
    Ok(json!({"sourceDocumentStatus":status,"rejectionCode":code}))
}

async fn ensure_parser_active(pool: &PgPool, result: &ExtractionResult) -> Result<(), Failure> {
    let active = sqlx::query_scalar!(
        "SELECT EXISTS(SELECT 1 FROM core.parser_versions \
         WHERE parser_name=$1 AND version=$2 AND status='ACTIVE' \
           AND btrim(implementation_digest::text)=$3 \
           AND supported_media_types ? $4)",
        &result.parser_id,
        &result.parser_version,
        PARSER_IMPLEMENTATION_DIGEST,
        &result.media_type,
    )
    .fetch_one(pool)
    .await
    .map_err(database)?;
    let active = required_column(active, "0")?;
    if active {
        Ok(())
    } else {
        Err(Failure::Terminal(
            "PARSER_REGISTRY_MISMATCH",
            format!(
                "{}:{}:{}",
                result.parser_id, result.parser_version, result.media_type
            ),
        ))
    }
}
