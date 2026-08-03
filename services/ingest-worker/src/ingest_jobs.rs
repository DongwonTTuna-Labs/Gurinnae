async fn process_claimed(
    pool: &PgPool,
    store: &Store,
    source_client: &Client,
    source_egress_url: Option<&Url>,
    job: &ClaimedJob,
) -> Result<Value, Failure> {
    if job.job_type == "SOURCE_RUN" {
        return process_source_run(pool, store, source_client, source_egress_url, job).await;
    }
    if job.job_type != "EVENT_DELIVERY"
        || job.payload.get("eventType").and_then(Value::as_str) != Some("source.document_parsed.v1")
    {
        return Err(Failure::Terminal(
            "UNSUPPORTED_JOB_TYPE",
            job.job_type.clone(),
        ));
    }
    let event_id = uuid(&job.payload, "eventId")
        .ok_or_else(|| Failure::Terminal("INVALID_EVENT", "eventId is invalid".to_owned()))?;
    process_parsed_event(pool, store, job, event_id).await
}

async fn process_parsed_event(
    pool: &PgPool,
    store: &Store,
    job: &ClaimedJob,
    event_id: Uuid,
) -> Result<Value, Failure> {
    if inbox_processed(pool, event_id).await? {
        return Ok(json!({"deduplicated":true}));
    }
    let (document_id, output_digest, parser_version) = parsed_event_fields(job)?;
    let row = sqlx::query!(
        "SELECT source_id,status::text status,content_sha256,parser_version,metadata \
         FROM raw.source_documents WHERE id=$1",
        document_id,
    )
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("SOURCE_DOCUMENT_NOT_FOUND", document_id.to_string()))?;
    let source_id = row.source_id;
    let status = row.status.ok_or_else(|| {
        Failure::Retryable(
            "DATABASE_UNAVAILABLE",
            "source document status unexpectedly null".to_owned(),
        )
    })?;
    let source_digest = row.content_sha256.trim().to_owned();
    let persisted_parser = row.parser_version;
    if status != "PARSED" || persisted_parser.as_deref() != Some(parser_version) {
        return Err(Failure::Terminal(
            "SOURCE_DOCUMENT_CONTRACT_MISMATCH",
            format!("status={status} parserVersion={persisted_parser:?}"),
        ));
    }
    let key = format!("parsed/{document_id}/{output_digest}.json");
    let bytes = get(store, &key, output_digest)
        .await
        .map_err(object_store)?;
    let extraction: Value = serde_json::from_slice(&bytes)
        .map_err(|error| Failure::Terminal("PARSED_OBJECT_INVALID", error.to_string()))?;
    validate_extraction(&extraction, &source_digest, parser_version)?;
    let records = flatten_records(&extraction)?;
    let schema_fingerprint = schema_fingerprint(&records)?;
    persist_parsed_records(
        pool,
        event_id,
        document_id,
        &source_id,
        parser_version,
        output_digest,
        &key,
        &records,
        &schema_fingerprint,
    )
    .await?;
    tracing::info!(source_document_id=%document_id,record_count=records.len(),"parsed document ingested");
    Ok(json!({"recordCount":records.len(),"schemaFingerprint":schema_fingerprint}))
}
fn parsed_event_fields(job: &ClaimedJob) -> Result<(Uuid, &str, &str), Failure> {
    let payload = job
        .payload
        .get("payload")
        .and_then(Value::as_object)
        .ok_or_else(|| Failure::Terminal("INVALID_EVENT", "payload is invalid".to_owned()))?;
    let document_id = uuid_object(payload, "source_document_id").ok_or_else(|| {
        Failure::Terminal(
            "INVALID_EVENT_PAYLOAD",
            "source_document_id is invalid".to_owned(),
        )
    })?;
    let output_digest = text_object(payload, "output_digest")
        .filter(|value| is_sha256(value))
        .ok_or_else(|| {
            Failure::Terminal(
                "INVALID_EVENT_PAYLOAD",
                "output_digest is invalid".to_owned(),
            )
        })?;
    let parser_version = text_object(payload, "parser_version")
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            Failure::Terminal(
                "INVALID_EVENT_PAYLOAD",
                "parser_version is invalid".to_owned(),
            )
        })?;
    Ok((document_id, output_digest, parser_version))
}
#[expect(
    clippy::too_many_arguments,
    reason = "parsed-record persistence binds event, document, parser, and object provenance"
)]
async fn persist_parsed_records(
    pool: &PgPool,
    event_id: Uuid,
    document_id: Uuid,
    source_id: &str,
    parser_version: &str,
    output_digest: &str,
    key: &str,
    records: &[Value],
    schema_fingerprint: &str,
) -> Result<(), Failure> {
    let mut tx = pool.begin().await.map_err(database)?;
    for (index, record) in records.iter().enumerate() {
        let bytes = serde_json::to_vec(record)
            .map_err(|error| Failure::Terminal("PARSED_RECORD_INVALID", error.to_string()))?;
        sqlx::query!(
            "INSERT INTO raw.parsed_records(source_document_id,record_type,record_index, \
             parser_version,payload,payload_sha256) VALUES($1,$2,$3,$4,$5,$6) \
             ON CONFLICT(source_document_id,record_type,record_index,parser_version) DO NOTHING",
            document_id,
            record
                .get("recordType")
                .and_then(Value::as_str)
                .unwrap_or("DOCUMENT"),
            i32::try_from(index).map_err(|_| {
                Failure::Terminal("PARSED_RECORD_LIMIT", "too many records".to_owned())
            })?,
            parser_version,
            record,
            sha256(&bytes),
        )
        .execute(&mut *tx)
        .await
        .map_err(database)?;
    }
    let previous = sqlx::query!(
        "SELECT id,metadata->>'parsedSchemaFingerprint' fingerprint \
         FROM raw.source_documents WHERE source_id=$1 AND id<>$2 \
           AND metadata ? 'parsedSchemaFingerprint' ORDER BY retrieved_at DESC LIMIT 1",
        source_id,
        document_id,
    )
    .fetch_optional(&mut *tx)
    .await
    .map_err(database)?;
    if let Some(previous) = previous {
        let before = previous.fingerprint.ok_or_else(|| {
            Failure::Retryable(
                "DATABASE_UNAVAILABLE",
                "parsedSchemaFingerprint unexpectedly null".to_owned(),
            )
        })?;
        if before != schema_fingerprint {
            persist_schema_drift(&mut tx, source_id, document_id, &before, schema_fingerprint)
                .await?;
        }
    }
    sqlx::query!(
        "SELECT raw.record_parsed_source_metadata($1,$2,$3,$4,$5)",
        document_id,
        "document-extractor",
        parser_version,
        "v1",
        json!({
            "parsedSchemaFingerprint":schema_fingerprint,
            "parsedOutputDigest":output_digest,
            "parsedOutputObjectKey":key,
            "parsedRecordCount":records.len(),
        }),
    )
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    update_inbox(&mut tx, event_id).await?;
    tx.commit().await.map_err(database)?;

    Ok(())
}
#[derive(Clone)]
struct ManifestDocument {
    external_id: String,
    revision: String,
    target: String,
    content_type: String,
    published_at: Option<String>,
}

struct SourceResponse {
    bytes: Vec<u8>,
    content_type: String,
    http_status: u16,
}
async fn process_source_run(
    pool: &PgPool,
    store: &Store,
    source_client: &Client,
    source_egress_url: Option<&Url>,
    job: &ClaimedJob,
) -> Result<Value, Failure> {
    let run_id = uuid(&job.payload, "sourceRunId")
        .ok_or_else(|| Failure::Terminal("INVALID_SOURCE_RUN_JOB", "sourceRunId".into()))?;
    let gateway = source_egress_url
        .ok_or_else(|| Failure::Terminal("SOURCE_EGRESS_MISSING", run_id.to_string()))?;
    let row = sqlx::query!(
        "UPDATE ops.source_runs r SET status='RUNNING',started_at=COALESCE(started_at,clock_timestamp()), \
           checkpoint_before=COALESCE(checkpoint_before,(SELECT COALESCE(jsonb_object_agg(c.partition_key,c.cursor_payload),'{}'::jsonb) \
             FROM ops.source_checkpoints c WHERE c.source_id=r.source_id)) \
         FROM ops.source_registry s WHERE r.id=$1 AND r.source_id=s.source_id \
           AND r.status IN ('QUEUED','RUNNING') AND s.enabled AND s.legal_status='APPROVED' \
         RETURNING r.source_id,r.mode,r.requested_from,r.requested_to,s.base_url,s.configuration",
        run_id,
    )
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("SOURCE_RUN_NOT_ALLOWED", run_id.to_string()))?;
    let source_id = row.source_id;
    let mode = row.mode;
    let requested_from = row.requested_from;
    let requested_to = row.requested_to;
    let base_url = row.base_url;
    let configuration = row.configuration;
    let catalog = operations()
        .filter(|operation| operation.connector_id == source_id)
        .collect::<Vec<_>>();
    if catalog.is_empty() {
        mark_source_terminal(pool, run_id, &source_id, "CONNECTOR_NOT_CATALOGED").await?;
        return Err(Failure::Terminal("CONNECTOR_NOT_CATALOGED", source_id));
    }

    let (seen, changed, fingerprints) = collect_source_run(
        pool,
        store,
        source_client,
        gateway,
        run_id,
        source_id.clone(),
        mode.clone(),
        requested_from,
        requested_to,
        base_url.clone(),
        configuration.clone(),
        catalog,
    )
    .await?;
    finish_source_run(
        pool,
        store,
        run_id,
        source_id,
        mode,
        seen,
        changed,
        fingerprints,
    )
    .await
}

#[expect(
    clippy::too_many_arguments,
    reason = "source collection carries the pinned connector and checkpoint context"
)]
async fn collect_source_run(
    pool: &PgPool,
    store: &Store,
    source_client: &Client,
    gateway: &Url,
    run_id: Uuid,
    source_id: String,
    mode: String,
    requested_from: Option<time::Date>,
    requested_to: Option<time::Date>,
    base_url: Option<String>,
    configuration: Value,
    catalog: Vec<&'static ConnectorOperation>,
) -> Result<(i64, i64, Vec<Value>), Failure> {
    let mut seen = 0_i64;
    let mut changed = 0_i64;
    let mut fingerprints = Vec::new();
    let mut manifest_documents = Vec::<ManifestDocument>::new();
    for operation in catalog {
        let targets = if operation.kind == "document" && !manifest_documents.is_empty() {
            manifest_documents.clone()
        } else {
            vec![ManifestDocument {
                external_id: operation.id.to_owned(),
                revision: "runtime".to_owned(),
                target: operation_target(operation, base_url.as_deref(), &configuration)?,
                content_type: "application/json".to_owned(),
                published_at: None,
            }]
        };
        for target in targets {
            let result = process_source_target(
                pool,
                store,
                source_client,
                gateway,
                run_id,
                &source_id,
                &mode,
                &configuration,
                requested_from,
                requested_to,
                operation,
                &target,
            )
            .await?;
            seen += 1;
            changed += i64::from(result.changed);
            if let Some(documents) = result.manifest_documents {
                manifest_documents = documents;
            }
            fingerprints.push(json!({"operationId":operation.id,"sha256":result.digest}));
        }
    }
    Ok((seen, changed, fingerprints))
}
struct SourceTargetResult {
    digest: String,
    changed: bool,
    manifest_documents: Option<Vec<ManifestDocument>>,
}

#[expect(
    clippy::too_many_arguments,
    reason = "target processing receives the immutable source-run and connector context"
)]
async fn process_source_target(
    pool: &PgPool,
    store: &Store,
    source_client: &Client,
    gateway: &Url,
    run_id: Uuid,
    source_id: &str,
    mode: &str,
    configuration: &Value,
    requested_from: Option<time::Date>,
    requested_to: Option<time::Date>,
    operation: &'static ConnectorOperation,
    target: &ManifestDocument,
) -> Result<SourceTargetResult, Failure> {
    let target_url = with_operation_parameters(
        &target.target,
        operation,
        configuration,
        requested_from,
        requested_to,
    )?;
    let response = match fetch_source(source_client, gateway, source_id, &target_url).await {
        Ok(response) => response,
        Err(Failure::Terminal(code, detail)) => {
            mark_source_terminal(pool, run_id, source_id, code).await?;
            return Err(Failure::Terminal(code, detail));
        }
        Err(error @ Failure::Retryable(_, _)) => return Err(error),
    };
    let digest = sha256(&response.bytes);
    let manifest_documents =
        validate_source_payload(source_id, operation.kind, operation.id, &response)?;
    let object_key = format!("raw/{source_id}/{run_id}/{}/{digest}", operation.id);
    put_object(store, &object_key, response.bytes.clone(), &digest).await?;
    let changed = persist_source_target(
        pool,
        run_id,
        source_id,
        mode,
        operation,
        target,
        &target_url,
        &response,
        &digest,
        &object_key,
    )
    .await?;
    Ok(SourceTargetResult {
        digest,
        changed,
        manifest_documents,
    })
}

fn validate_source_payload(
    source_id: &str,
    operation_kind: &str,
    operation_id: &str,
    response: &SourceResponse,
) -> Result<Option<Vec<ManifestDocument>>, Failure> {
    if operation_kind == "manifest" {
        return Ok(Some(validate_manifest(&response.bytes)?));
    }
    if source_id.starts_with("koneps-") {
        let value: Value = serde_json::from_slice(&response.bytes)
            .map_err(|error| Failure::Terminal("SOURCE_PAYLOAD_MALFORMED", error.to_string()))?;
        gurine_source_connectors::data_go_kr::decode(value)
            .map_err(|error| Failure::Terminal("SOURCE_PAYLOAD_REJECTED", error.to_string()))?;
    } else if source_id == "open-dart" && operation_kind != "snapshot-zip-xml" {
        let value: Value = serde_json::from_slice(&response.bytes)
            .map_err(|error| Failure::Terminal("SOURCE_PAYLOAD_MALFORMED", error.to_string()))?;
        if value.get("status").and_then(Value::as_str) != Some("000") {
            return Err(Failure::Terminal(
                "SOURCE_PAYLOAD_REJECTED",
                operation_id.to_owned(),
            ));
        }
    }
    Ok(None)
}

#[expect(
    clippy::too_many_arguments,
    reason = "target persistence binds source, response, parser, and object-store provenance"
)]
async fn persist_source_target(
    pool: &PgPool,
    run_id: Uuid,
    source_id: &str,
    mode: &str,
    operation: &'static ConnectorOperation,
    target: &ManifestDocument,
    target_url: &str,
    response: &SourceResponse,
    digest: &str,
    object_key: &str,
) -> Result<bool, Failure> {
    let mut tx = pool.begin().await.map_err(database)?;
    let fetch_id = persist_source_fetch(
        &mut tx, run_id, source_id, target_url, operation, response, digest, object_key,
    )
    .await?;
    let inserted = if mode == "DRY_RUN" {
        None
    } else {
        let document_id: Uuid = sqlx::query_scalar!(
            "SELECT (raw.insert_source_document_revision($1,$2,$3,$4,$5,clock_timestamp(),$6::timestamptz,$7,$8,$9,$10,$11::core.source_document_status,$12,$13,$14,$15,$16,$17)).id",
            source_id,
            format!("{}:{}", operation.id, target.external_id),
            &target.revision,
            target_url,
            fetch_id,
            target.published_at.as_deref() as _,
            if response.content_type.is_empty() {
                target.content_type.as_str()
            } else {
                response.content_type.as_str()
            },
            digest,
            i64::try_from(response.bytes.len()).unwrap_or(i64::MAX),
            object_key,
            "FETCHED" as _,
            Option::<&str>::None,
            Option::<&str>::None,
            Option::<&str>::None,
            json!([]),
            Option::<&str>::None,
            json!({"connectorOperationId":operation.id,"sourceRunId":run_id}),
        )
        .fetch_one(&mut *tx)
        .await
        .map_err(database)?
        .ok_or_else(|| {
            Failure::Retryable(
                "DATABASE_UNAVAILABLE",
                "insert_source_document_revision unexpectedly returned null".to_owned(),
            )
        })?;
        Some(document_id)
    };
    if let Some(document_id) = inserted {
        if response.content_type == "application/json" {
            persist_structured_json(&mut tx, source_id, operation, document_id, &response.bytes)
                .await?;
        }
        sqlx::query!(
            "SELECT ops.enqueue_outbox('source_document',$1,1,'source.document_stored.v1',$2,clock_timestamp())",
            document_id.to_string(),
            json!({"content_sha256":digest,"source_document_id":document_id,"source_id":source_id}),
        )
        .fetch_one(&mut *tx)
        .await
        .map_err(database)?;
    }
    sqlx::query!(
        "INSERT INTO ops.source_checkpoints(source_id,partition_key,cursor_payload,remote_high_watermark,last_success_at)          VALUES($1,$2,$3,$4,clock_timestamp())          ON CONFLICT(source_id,partition_key) DO UPDATE SET cursor_payload=EXCLUDED.cursor_payload,            remote_high_watermark=EXCLUDED.remote_high_watermark,last_success_at=EXCLUDED.last_success_at,            version=ops.source_checkpoints.version+1,updated_at=clock_timestamp()",
        source_id,
        operation.id,
        json!({"operationId":operation.id,"digest":digest,"sourceRunId":run_id}),
        digest,
    )
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    tx.commit().await.map_err(database)?;
    Ok(inserted.is_some())
}

#[expect(
    clippy::too_many_arguments,
    reason = "source-run completion persists checkpoint, counts, and fingerprint evidence"
)]
async fn finish_source_run(
    pool: &PgPool,
    store: &Store,
    run_id: Uuid,
    source_id: String,
    mode: String,
    seen: i64,
    changed: i64,
    fingerprints: Vec<Value>,
) -> Result<Value, Failure> {
    let report = json!({
        "sourceRunId":run_id,"sourceId":source_id,"mode":mode,
        "recordsSeen":seen,"recordsChanged":changed,"responseFingerprints":fingerprints
    });
    let report_bytes = serde_json::to_vec(&report)
        .map_err(|error| Failure::Terminal("SOURCE_REPORT_INVALID", error.to_string()))?;
    let report_digest = sha256(&report_bytes);
    let report_key = format!("reports/source-runs/{run_id}/{report_digest}.json");
    put_object(store, &report_key, report_bytes, &report_digest).await?;
    let mut tx = pool.begin().await.map_err(database)?;
    let checkpoint_after: Value = sqlx::query_scalar!(
        "SELECT COALESCE(jsonb_object_agg(partition_key,cursor_payload),'{}'::jsonb) \
         FROM ops.source_checkpoints WHERE source_id=$1",
        &source_id,
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(database)?
    .ok_or_else(|| {
        Failure::Retryable(
            "DATABASE_UNAVAILABLE",
            "source checkpoint aggregate unexpectedly null".to_owned(),
        )
    })?;
    sqlx::query!(
        "UPDATE ops.source_runs SET status='SUCCEEDED',records_seen=$2,records_changed=$3, \
           checkpoint_after=$4,report_object_key=$5,completed_at=clock_timestamp(),error_detail=NULL \
         WHERE id=$1 AND status='RUNNING'",
        run_id,
        seen,
        changed,
        checkpoint_after,
        &report_key,
    )
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    sqlx::query(
        "UPDATE ops.source_registry SET configuration=configuration || jsonb_build_object( \
           'activationReceipt',jsonb_build_object('passedAt',clock_timestamp(), \
             'sourceRunId',$2,'responseFingerprints',$3::jsonb)),updated_at=clock_timestamp() \
         WHERE source_id=$1",
    )
    .bind(&source_id)
    .bind(run_id)
    .bind(json!(fingerprints))
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    tx.commit().await.map_err(database)?;
    Ok(
        json!({"sourceRunId":run_id,"recordsSeen":seen,"recordsChanged":changed,"reportObjectKey":report_key}),
    )
}
