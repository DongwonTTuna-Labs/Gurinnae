struct AuditExportContext {
    from: time::OffsetDateTime,
    to: time::OffsetDateTime,
    format: String,
    scope: String,
    object_type: Option<String>,
    object_id: Option<String>,
    watermark: String,
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
    let changed = sqlx::query(
        "UPDATE ops.audit_exports SET status='READY',object_key=$2,content_sha256=$3,          row_count=$4,completed_at=clock_timestamp() WHERE id=$1 AND status='RUNNING'",
    )
    .bind(id)
    .bind(&key)
    .bind(&digest)
    .bind(i64::try_from(rows.len()).map_err(|_| Failure::Terminal("AUDIT_EXPORT_LIMIT", rows.len().to_string()))?)
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
    let row = sqlx::query(
        "UPDATE ops.audit_exports SET status='RUNNING',started_at=COALESCE(started_at,clock_timestamp())          WHERE id=$1 AND status IN ('QUEUED','RUNNING')          RETURNING from_at,to_at,format,scope,object_type,object_id,watermark_policy",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("AUDIT_EXPORT_NOT_QUEUED", id.to_string()))?;
    Ok(AuditExportContext {
        from: row.try_get("from_at").map_err(database)?,
        to: row.try_get("to_at").map_err(database)?,
        format: row.try_get("format").map_err(database)?,
        scope: row.try_get("scope").map_err(database)?,
        object_type: row.try_get("object_type").map_err(database)?,
        object_id: row.try_get("object_id").map_err(database)?,
        watermark: row.try_get("watermark_policy").map_err(database)?,
    })
}

async fn fetch_audit_rows(
    pool: &PgPool,
    context: &AuditExportContext,
) -> Result<Vec<sqlx::postgres::PgRow>, Failure> {
    sqlx::query(
        "SELECT id,occurred_at,actor_type,actor_id,action,object_type,object_id,capability,          outcome::text outcome,reason,request_id,details,event_hash,previous_event_hash          FROM ops.audit_events WHERE occurred_at >= $1 AND occurred_at <= $2            AND ($3='GLOBAL' OR ($3='CASE' AND object_type='case' AND object_id=$5)              OR ($3='OBJECT' AND upper(object_type)=upper($4) AND object_id=$5))          ORDER BY occurred_at,id LIMIT 1000001",
    )
    .bind(context.from)
    .bind(context.to)
    .bind(&context.scope)
    .bind(context.object_type.as_deref())
    .bind(context.object_id.as_deref())
    .fetch_all(pool)
    .await
    .map_err(database)
}

fn render_audit_rows(format: &str, rows: &[sqlx::postgres::PgRow]) -> Result<Vec<u8>, Failure> {
    match format {
        "JSONL" => render_audit_jsonl(rows),
        "CSV" => render_audit_csv(rows),
        _ => Err(Failure::Terminal("AUDIT_FORMAT_INVALID", format.to_owned())),
    }
}

fn render_audit_jsonl(rows: &[sqlx::postgres::PgRow]) -> Result<Vec<u8>, Failure> {
    let mut output = Vec::new();
    for row in rows {
        serde_json::to_writer(&mut output, &audit_row(row)?)
            .map_err(|error| Failure::Terminal("AUDIT_SERIALIZE", error.to_string()))?;
        output.push(b'\n');
    }
    Ok(output)
}

fn render_audit_csv(rows: &[sqlx::postgres::PgRow]) -> Result<Vec<u8>, Failure> {
    let mut output = b"id,occurred_at,actor_type,actor_id,action,object_type,object_id,capability,outcome,reason,request_id,event_hash,previous_event_hash\\n".to_vec();
    for row in rows {
        let fields = [
            row.try_get::<Uuid, _>("id").map_err(database)?.to_string(),
            row.try_get::<time::OffsetDateTime, _>("occurred_at").map_err(database)?.to_string(),
            row.try_get::<String, _>("actor_type").map_err(database)?,
            row.try_get::<Option<String>, _>("actor_id").map_err(database)?.unwrap_or_default(),
            row.try_get::<String, _>("action").map_err(database)?,
            row.try_get::<Option<String>, _>("object_type").map_err(database)?.unwrap_or_default(),
            row.try_get::<Option<String>, _>("object_id").map_err(database)?.unwrap_or_default(),
            row.try_get::<Option<String>, _>("capability").map_err(database)?.unwrap_or_default(),
            row.try_get::<String, _>("outcome").map_err(database)?,
            row.try_get::<Option<String>, _>("reason").map_err(database)?.unwrap_or_default(),
            row.try_get::<Uuid, _>("request_id").map_err(database)?.to_string(),
            row.try_get::<String, _>("event_hash").map_err(database)?.trim().to_owned(),
            row.try_get::<Option<String>, _>("previous_event_hash").map_err(database)?.unwrap_or_default().trim().to_owned(),
        ];
        output.extend_from_slice(fields.iter().map(|field| csv_field(field)).collect::<Vec<_>>().join(",").as_bytes());
        output.push(b'\n');
    }
    Ok(output)
}



fn audit_row(row: &sqlx::postgres::PgRow) -> Result<Value, Failure> {
    Ok(json!({
        "id":row.try_get::<Uuid,_>("id").map_err(database)?,
        "occurredAt":row.try_get::<time::OffsetDateTime,_>("occurred_at").map_err(database)?.to_string(),
        "actorType":row.try_get::<String,_>("actor_type").map_err(database)?,
        "actorId":row.try_get::<Option<String>,_>("actor_id").map_err(database)?,
        "action":row.try_get::<String,_>("action").map_err(database)?,
        "objectType":row.try_get::<Option<String>,_>("object_type").map_err(database)?,
        "objectId":row.try_get::<Option<String>,_>("object_id").map_err(database)?,
        "capability":row.try_get::<Option<String>,_>("capability").map_err(database)?,
        "outcome":row.try_get::<String,_>("outcome").map_err(database)?,
        "reason":row.try_get::<Option<String>,_>("reason").map_err(database)?,
        "requestId":row.try_get::<Uuid,_>("request_id").map_err(database)?,
        "details":row.try_get::<Value,_>("details").map_err(database)?,
        "eventHash":row.try_get::<String,_>("event_hash").map_err(database)?.trim(),
        "previousEventHash":row.try_get::<Option<String>,_>("previous_event_hash").map_err(database)?.map(|value|value.trim().to_owned()),
    }))
}

fn csv_field(value: &str) -> String {
    format!("\"{}\"", value.replace('"', "\"\""))
}

async fn export_dataset(pool: &PgPool, store: &Store, id: Uuid) -> Result<Value, Failure> {
    let row = sqlx::query(
        "UPDATE intake.dataset_export_requests SET status='RUNNING' \
         WHERE id=$1 AND status IN ('QUEUED','RUNNING') \
         RETURNING dataset_id,format,filters,expires_at",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("DATASET_EXPORT_NOT_QUEUED", id.to_string()))?;
    let dataset_id: String = row.try_get("dataset_id").map_err(database)?;
    let format: String = row.try_get("format").map_err(database)?;
    let filters: Value = row.try_get("filters").map_err(database)?;
    let expires_at: time::OffsetDateTime = row.try_get("expires_at").map_err(database)?;
    if expires_at <= time::OffsetDateTime::now_utc() {
        return Err(Failure::Terminal("DATASET_EXPORT_EXPIRED", id.to_string()));
    }
    let dataset: Value = sqlx::query_scalar(
        "SELECT jsonb_build_object('id',id,'title',title,'description',description, \
         'format',format,'coverage',coverage,'license',license,'updatedAt',updated_at) \
         FROM public.datasets WHERE id=$1",
    )
    .bind(&dataset_id)
    .fetch_optional(pool)
    .await
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
        "CSV" => {
            let line = [
                dataset_id.clone(),
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
                serde_json::to_string(&filters)
                    .map_err(|error| Failure::Terminal("DATASET_SERIALIZE", error.to_string()))?,
            ]
            .iter()
            .map(|value| csv_field(value))
            .collect::<Vec<_>>()
            .join(",");
            (
                format!("dataset_id,title,description,filters\n{line}\n").into_bytes(),
                "csv",
            )
        }
        "PARQUET" => (dataset_parquet(&dataset_id, &dataset, &filters)?, "parquet"),
        _ => return Err(Failure::Terminal("DATASET_FORMAT_INVALID", format)),
    };
    let digest = sha256(&bytes);
    let key = format!("exports/datasets/{id}/{digest}.{extension}");
    put(store, &key, bytes, &digest).await?;
    let changed = sqlx::query(
        "UPDATE intake.dataset_export_requests SET status='READY',object_key=$2, \
         completed_at=clock_timestamp() WHERE id=$1 AND status='RUNNING'",
    )
    .bind(id)
    .bind(&key)
    .execute(pool)
    .await
    .map_err(database)?
    .rows_affected();
    if changed != 1 {
        return Err(Failure::Terminal("DATASET_EXPORT_FENCE", id.to_string()));
    }
    Ok(json!({"datasetExportId":id,"contentSha256":digest,"objectKey":key}))
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

async fn create_signal_task(
    pool: &PgPool,
    payload: &serde_json::Map<String, Value>,
) -> Result<Value, Failure> {
    let signal = object_uuid(payload, "signal_id")?;
    let exists: bool =
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM core.anomaly_signals WHERE id=$1)")
            .bind(signal)
            .fetch_one(pool)
            .await
            .map_err(database)?;
    if !exists {
        return Err(Failure::Terminal("SIGNAL_NOT_FOUND", signal.to_string()));
    }
    sqlx::query(
        "INSERT INTO ops.tasks(task_type,object_type,object_id,title,status,priority) \
         SELECT 'SIGNAL_TRIAGE','SIGNAL',$1,'Triage detected signal','OPEN', \
           CASE severity WHEN 'CRITICAL' THEN 'URGENT' WHEN 'HIGH' THEN 'HIGH' ELSE 'NORMAL' END \
         FROM core.anomaly_signals WHERE id=$1 AND NOT EXISTS( \
           SELECT 1 FROM ops.tasks WHERE task_type='SIGNAL_TRIAGE' AND object_id=$1 AND status<>'DONE')",
    )
    .bind(signal)
    .execute(pool)
    .await
    .map_err(database)?;
    Ok(json!({"signalId":signal,"taskCreated":true}))
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
    let exists: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM ops.schema_drifts WHERE id=$1 AND source_id=$2 AND status='OPEN')",
    )
    .bind(drift)
    .bind(source)
    .fetch_one(pool)
    .await
    .map_err(database)?;
    if !exists {
        return Err(Failure::Terminal(
            "SCHEMA_DRIFT_NOT_OPEN",
            drift.to_string(),
        ));
    }
    let mut tx = pool.begin().await.map_err(database)?;
    sqlx::query("UPDATE ops.source_registry SET enabled=false WHERE source_id=$1")
        .bind(source)
        .execute(&mut *tx)
        .await
        .map_err(database)?;
    sqlx::query(
        "INSERT INTO ops.tasks(task_type,object_type,object_id,title,status,priority,blocker_code) \
         SELECT 'SCHEMA_DRIFT','SCHEMA_DRIFT',$1,'Review source schema drift','OPEN','HIGH', \
           'SOURCE_SCHEMA_DRIFT' WHERE NOT EXISTS(SELECT 1 FROM ops.tasks \
             WHERE task_type='SCHEMA_DRIFT' AND object_id=$1 AND status<>'DONE')",
    )
    .bind(drift)
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    tx.commit().await.map_err(database)?;
    Ok(json!({"schemaDriftId":drift,"sourceId":source,"sourcePaused":true}))
}

async fn reconcile_response(pool: &PgPool, submission: Uuid) -> Result<Value, Failure> {
    let row = sqlx::query(
        "SELECT s.response_request_id,s.answers_encrypted,s.publication_consent,s.submitted_at, \
         s.editorial_response_id,r.case_id,r.party_name \
         FROM intake.response_submissions s JOIN editorial.response_requests r \
           ON r.id=s.response_request_id WHERE s.id=$1 AND s.status='SUBMITTED'",
    )
    .bind(submission)
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("RESPONSE_SUBMISSION_NOT_FOUND", submission.to_string()))?;
    if let Some(existing) = row
        .try_get::<Option<Uuid>, _>("editorial_response_id")
        .map_err(database)?
    {
        return Ok(json!({"submissionId":submission,"responseId":existing,"deduplicated":true}));
    }
    let response_id = Uuid::new_v4();
    let mut tx = pool.begin().await.map_err(database)?;
    sqlx::query(
        "INSERT INTO editorial.responses(id,case_id,response_request_id,party_name,submitted_at, \
         full_text_encrypted,publication_consent,editorial_status) \
         VALUES($1,$2,$3,$4,$5,$6,$7,'PENDING')",
    )
    .bind(response_id)
    .bind(row.try_get::<Uuid, _>("case_id").map_err(database)?)
    .bind(
        row.try_get::<Uuid, _>("response_request_id")
            .map_err(database)?,
    )
    .bind(row.try_get::<String, _>("party_name").map_err(database)?)
    .bind(
        row.try_get::<time::OffsetDateTime, _>("submitted_at")
            .map_err(database)?,
    )
    .bind(
        row.try_get::<Vec<u8>, _>("answers_encrypted")
            .map_err(database)?,
    )
    .bind(
        row.try_get::<Value, _>("publication_consent")
            .map_err(database)?,
    )
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    let changed = sqlx::query(
        "UPDATE intake.response_submissions SET editorial_response_id=$2 \
         WHERE id=$1 AND editorial_response_id IS NULL",
    )
    .bind(submission)
    .bind(response_id)
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

