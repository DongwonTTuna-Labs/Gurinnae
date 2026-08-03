struct AuditExportContext {
    from: time::OffsetDateTime,
    to: time::OffsetDateTime,
    format: String,
    scope: String,
    object_type: Option<String>,
    object_id: Option<String>,
    watermark: String,
}

struct AuditExportRow {
    id: Uuid,
    occurred_at: time::OffsetDateTime,
    actor_type: String,
    actor_id: Option<String>,
    action: String,
    object_type: Option<String>,
    object_id: Option<String>,
    capability: Option<String>,
    outcome: Option<String>,
    reason: Option<String>,
    request_id: Uuid,
    details: Value,
    event_hash: String,
    previous_event_hash: Option<String>,
}

async fn export_audit(pool: &PgPool, store: &Store, id: Uuid) -> Result<Value, Failure> {
    let context = load_audit_export(pool, id).await?;
    let rows = fetch_audit_rows(pool, &context).await?;
    if rows.len() > 1_000_000 {
        return Err(Failure::Terminal(
            "AUDIT_EXPORT_LIMIT",
            "more than 1000000 rows".to_owned(),
        ));
    }
    let bytes = render_audit_rows(&context.format, &rows)?;
    if bytes.len() > 200 * 1024 * 1024 {
        return Err(Failure::Terminal("AUDIT_EXPORT_SIZE", bytes.len().to_string()));
    }
    let digest = sha256(&bytes);
    let extension = if context.format == "CSV" { "csv" } else { "jsonl" };
    let key = format!("exports/audit/{id}/{digest}.{extension}");
    put(store, &key, bytes, &digest).await?;
    let row_count = i64::try_from(rows.len())
        .map_err(|_| Failure::Terminal("AUDIT_EXPORT_LIMIT", rows.len().to_string()))?;
    let changed = sqlx::query!(
        "UPDATE ops.audit_exports SET status='READY',object_key=$2,content_sha256=$3,          row_count=$4,completed_at=clock_timestamp() WHERE id=$1 AND status='RUNNING'",
        id,
        &key,
        &digest,
        row_count,
    )
    .execute(pool)
    .await
    .map_err(database)?
    .rows_affected();
    if changed != 1 {
        return Err(Failure::Terminal("AUDIT_EXPORT_FENCE", id.to_string()));
    }
    Ok(json!({
        "auditExportId":id,
        "rowCount":rows.len(),
        "contentSha256":digest,
        "objectKey":key,
        "watermarkPolicy":context.watermark
    }))
}

async fn load_audit_export(pool: &PgPool, id: Uuid) -> Result<AuditExportContext, Failure> {
    let row = sqlx::query!(
        "UPDATE ops.audit_exports SET status='RUNNING',started_at=COALESCE(started_at,clock_timestamp())          WHERE id=$1 AND status IN ('QUEUED','RUNNING')          RETURNING from_at,to_at,format,scope,object_type,object_id,watermark_policy",
        id,
    )
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("AUDIT_EXPORT_NOT_QUEUED", id.to_string()))?;
    Ok(AuditExportContext {
        from: row.from_at,
        to: row.to_at,
        format: row.format,
        scope: row.scope,
        object_type: row.object_type,
        object_id: row.object_id,
        watermark: row.watermark_policy,
    })
}

async fn fetch_audit_rows(
    pool: &PgPool,
    context: &AuditExportContext,
) -> Result<Vec<AuditExportRow>, Failure> {
    sqlx::query_as!(
        AuditExportRow,
        "SELECT id,occurred_at,actor_type,actor_id,action,object_type,object_id,capability,          outcome::text AS \"outcome?\",reason,request_id,details,event_hash,previous_event_hash          FROM ops.audit_events WHERE occurred_at >= $1 AND occurred_at <= $2            AND ($3='GLOBAL' OR ($3='CASE' AND object_type='case' AND object_id=$5)              OR ($3='OBJECT' AND upper(object_type)=upper($4) AND object_id=$5))          ORDER BY occurred_at,id LIMIT 1000001",
        context.from,
        context.to,
        &context.scope,
        context.object_type.as_deref(),
        context.object_id.as_deref(),
    )
    .fetch_all(pool)
    .await
    .map_err(database)
}

fn render_audit_rows(format: &str, rows: &[AuditExportRow]) -> Result<Vec<u8>, Failure> {
    match format {
        "JSONL" => render_audit_jsonl(rows),
        "CSV" => render_audit_csv(rows),
        _ => Err(Failure::Terminal("AUDIT_FORMAT_INVALID", format.to_owned())),
    }
}

fn render_audit_jsonl(rows: &[AuditExportRow]) -> Result<Vec<u8>, Failure> {
    let mut output = Vec::new();
    for row in rows {
        serde_json::to_writer(&mut output, &audit_row(row)?)
            .map_err(|error| Failure::Terminal("AUDIT_SERIALIZE", error.to_string()))?;
        output.push(b'\n');
    }
    Ok(output)
}

fn render_audit_csv(rows: &[AuditExportRow]) -> Result<Vec<u8>, Failure> {
    let mut output = b"id,occurred_at,actor_type,actor_id,action,object_type,object_id,capability,outcome,reason,request_id,event_hash,previous_event_hash\\n".to_vec();
    for row in rows {
        let outcome = required(row.outcome.as_deref()).map_err(database)?;
        let fields = [
            row.id.to_string(),
            row.occurred_at.to_string(),
            row.actor_type.clone(),
            row.actor_id.clone().unwrap_or_default(),
            row.action.clone(),
            row.object_type.clone().unwrap_or_default(),
            row.object_id.clone().unwrap_or_default(),
            row.capability.clone().unwrap_or_default(),
            outcome.to_owned(),
            row.reason.clone().unwrap_or_default(),
            row.request_id.to_string(),
            row.event_hash.trim().to_owned(),
            row.previous_event_hash
                .as_deref()
                .unwrap_or_default()
                .trim()
                .to_owned(),
        ];
        output.extend_from_slice(fields.iter().map(|field| csv_field(field)).collect::<Vec<_>>().join(",").as_bytes());
        output.push(b'\n');
    }
    Ok(output)
}



fn audit_row(row: &AuditExportRow) -> Result<Value, Failure> {
    let outcome = required(row.outcome.as_deref()).map_err(database)?;
    Ok(json!({
        "id":row.id,
        "occurredAt":row.occurred_at.to_string(),
        "actorType":&row.actor_type,
        "actorId":row.actor_id.as_deref(),
        "action":&row.action,
        "objectType":row.object_type.as_deref(),
        "objectId":row.object_id.as_deref(),
        "capability":row.capability.as_deref(),
        "outcome":outcome,
        "reason":row.reason.as_deref(),
        "requestId":row.request_id,
        "details":&row.details,
        "eventHash":row.event_hash.trim(),
        "previousEventHash":row.previous_event_hash.as_deref().map(str::trim),
    }))
}

fn csv_field(value: &str) -> String {
    format!("\"{}\"", value.replace('"', "\"\""))
}

async fn export_dataset(pool: &PgPool, store: &Store, id: Uuid) -> Result<Value, Failure> {
    let row = sqlx::query!(
        "UPDATE intake.dataset_export_requests SET status='RUNNING' \
         WHERE id=$1 AND status IN ('QUEUED','RUNNING') \
         RETURNING dataset_id,format,filters,expires_at",
        id,
    )
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("DATASET_EXPORT_NOT_QUEUED", id.to_string()))?;
    let dataset_id = row.dataset_id;
    let format = row.format;
    let filters = row.filters;
    let expires_at = row.expires_at;
    if expires_at <= time::OffsetDateTime::now_utc() {
        return Err(Failure::Terminal("DATASET_EXPORT_EXPIRED", id.to_string()));
    }
    let dataset = sqlx::query_scalar!(
        "SELECT jsonb_build_object('id',id,'title',title,'description',description, \
         'format',format,'coverage',coverage,'license',license,'updatedAt',updated_at) \
         FROM public.datasets WHERE id=$1",
        &dataset_id,
    )
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .map(required)
    .transpose()
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("DATASET_NOT_FOUND", dataset_id.clone()))?;
    let envelope = json!({"dataset":dataset,"filters":filters,"exportedAt":time::OffsetDateTime::now_utc().to_string()});
    let (bytes, extension) = match format.as_str() {
        "JSONL" => {
            let mut bytes = serde_json::to_vec(&envelope)
                .map_err(|error| Failure::Terminal("DATASET_SERIALIZE", error.to_string()))?;
            bytes.push(b'\n');
            (bytes, "jsonl")
        }
        "CSV" => (dataset_csv(&dataset_id, &dataset, &filters)?, "csv"),
        "PARQUET" => (dataset_parquet(&dataset_id, &dataset, &filters)?, "parquet"),
        _ => return Err(Failure::Terminal("DATASET_FORMAT_INVALID", format)),
    };
    let digest = sha256(&bytes);
    let key = format!("exports/datasets/{id}/{digest}.{extension}");
    put(store, &key, bytes, &digest).await?;
    let changed = sqlx::query!(
        "UPDATE intake.dataset_export_requests SET status='READY',object_key=$2, \
         completed_at=clock_timestamp() WHERE id=$1 AND status='RUNNING'",
        id,
        &key,
    )
    .execute(pool)
    .await
    .map_err(database)?
    .rows_affected();
    if changed != 1 {
        return Err(Failure::Terminal("DATASET_EXPORT_FENCE", id.to_string()));
    }
    Ok(json!({"datasetExportId":id,"contentSha256":digest,"objectKey":key}))
}

fn dataset_csv(dataset_id: &str, dataset: &Value, filters: &Value) -> Result<Vec<u8>, Failure> {
    let line = [
        dataset_id.to_owned(),
        dataset
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
        dataset
            .get("description")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
        serde_json::to_string(filters)
            .map_err(|error| Failure::Terminal("DATASET_SERIALIZE", error.to_string()))?,
    ]
    .iter()
    .map(|value| csv_field(value))
    .collect::<Vec<_>>()
    .join(",");
    Ok(format!("dataset_id,title,description,filters\n{line}\n").into_bytes())
}

fn dataset_parquet(dataset_id: &str, dataset: &Value, filters: &Value) -> Result<Vec<u8>, Failure> {
    let title = dataset
        .get("title")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let description = dataset
        .get("description")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let filters = serde_json::to_string(filters)
        .map_err(|error| Failure::Terminal("DATASET_SERIALIZE", error.to_string()))?;
    let exported_at = time::OffsetDateTime::now_utc().to_string();
    let schema = Arc::new(Schema::new(vec![
        Field::new("dataset_id", DataType::Utf8, false),
        Field::new("title", DataType::Utf8, false),
        Field::new("description", DataType::Utf8, false),
        Field::new("filters_json", DataType::Utf8, false),
        Field::new("exported_at", DataType::Utf8, false),
    ]));
    let columns: Vec<ArrayRef> = vec![
        Arc::new(StringArray::from(vec![dataset_id])),
        Arc::new(StringArray::from(vec![title])),
        Arc::new(StringArray::from(vec![description])),
        Arc::new(StringArray::from(vec![filters.as_str()])),
        Arc::new(StringArray::from(vec![exported_at.as_str()])),
    ];
    let batch = RecordBatch::try_new(schema.clone(), columns)
        .map_err(|error| Failure::Terminal("DATASET_SERIALIZE", error.to_string()))?;
    let mut writer = ArrowWriter::try_new(Vec::new(), schema, None)
        .map_err(|error| Failure::Terminal("DATASET_SERIALIZE", error.to_string()))?;
    writer
        .write(&batch)
        .map_err(|error| Failure::Terminal("DATASET_SERIALIZE", error.to_string()))?;
    writer
        .into_inner()
        .map_err(|error| Failure::Terminal("DATASET_SERIALIZE", error.to_string()))
}

async fn reconcile_schema_drift(
    pool: &PgPool,
    payload: &serde_json::Map<String, Value>,
) -> Result<Value, Failure> {
    let drift = object_uuid(payload, "schema_drift_id")?;
    let source = payload
        .get("source_id")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| Failure::Terminal("INVALID_SCHEMA_DRIFT", "source_id".to_owned()))?;
    let exists = sqlx::query_scalar!(
        "SELECT EXISTS(SELECT 1 FROM ops.schema_drifts WHERE id=$1 AND source_id=$2 AND status='OPEN')",
        drift,
        source,
    )
    .fetch_one(pool)
    .await
    .map_err(database)?;
    let exists = required(exists).map_err(database)?;
    if !exists {
        return Err(Failure::Terminal(
            "SCHEMA_DRIFT_NOT_OPEN",
            drift.to_string(),
        ));
    }
    let mut tx = pool.begin().await.map_err(database)?;
    sqlx::query!(
        "UPDATE ops.source_registry SET enabled=false WHERE source_id=$1",
        source,
    )
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    sqlx::query!(
        "INSERT INTO ops.tasks(task_type,object_type,object_id,title,status,priority,blocker_code) \
         SELECT 'SCHEMA_DRIFT','SCHEMA_DRIFT',$1,'Review source schema drift','OPEN','HIGH', \
           'SOURCE_SCHEMA_DRIFT' WHERE NOT EXISTS(SELECT 1 FROM ops.tasks \
             WHERE task_type='SCHEMA_DRIFT' AND object_id=$1 AND status<>'DONE')",
        drift,
    )
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    tx.commit().await.map_err(database)?;
    Ok(json!({"schemaDriftId":drift,"sourceId":source,"sourcePaused":true}))
}

async fn reconcile_response(pool: &PgPool, submission: Uuid) -> Result<Value, Failure> {
    let row = sqlx::query!(
        "SELECT s.response_request_id,s.answers_encrypted,s.publication_consent,s.submitted_at, \
         s.editorial_response_id,r.case_id,r.party_name \
         FROM intake.response_submissions s JOIN editorial.response_requests r \
           ON r.id=s.response_request_id WHERE s.id=$1 AND s.status='SUBMITTED'",
        submission,
    )
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("RESPONSE_SUBMISSION_NOT_FOUND", submission.to_string()))?;
    if let Some(existing) = row.editorial_response_id {
        return Ok(json!({"submissionId":submission,"responseId":existing,"deduplicated":true}));
    }
    let response_id = Uuid::new_v4();
    let mut tx = pool.begin().await.map_err(database)?;
    sqlx::query!(
        "INSERT INTO editorial.responses(id,case_id,response_request_id,party_name,submitted_at, \
         full_text_encrypted,publication_consent,editorial_status) \
         VALUES($1,$2,$3,$4,$5,$6,$7,'PENDING')",
        response_id,
        row.case_id,
        row.response_request_id,
        row.party_name,
        row.submitted_at,
        row.answers_encrypted,
        row.publication_consent,
    )
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    let changed = sqlx::query!(
        "UPDATE intake.response_submissions SET editorial_response_id=$2 \
         WHERE id=$1 AND editorial_response_id IS NULL",
        submission,
        response_id,
    )
    .execute(&mut *tx)
    .await
    .map_err(database)?
    .rows_affected();
    if changed != 1 {
        return Err(Failure::Terminal(
            "RESPONSE_SUBMISSION_FENCE",
            submission.to_string(),
        ));
    }
    tx.commit().await.map_err(database)?;
    Ok(json!({"submissionId":submission,"responseId":response_id}))
}
