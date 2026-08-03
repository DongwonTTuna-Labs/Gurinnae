struct SourceTargetPersistence<'a> {
    run_id: Uuid,
    source_id: &'a str,
    mode: &'a str,
    operation: &'static ConnectorOperation,
    target: &'a ManifestDocument,
    target_url: &'a str,
    response: &'a SourceResponse,
    digest: &'a str,
    object_key: &'a str,
    job_id: Uuid,
    job_fencing_token: i64,
    supplier_identifier_hmac_key: &'a [u8],
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
    job_id: Uuid,
    job_fencing_token: i64,
    supplier_identifier_hmac_key: &[u8],
) -> Result<bool, Failure> {
    let context = SourceTargetPersistence {
        run_id,
        source_id,
        mode,
        operation,
        target,
        target_url,
        response,
        digest,
        object_key,
        job_id,
        job_fencing_token,
        supplier_identifier_hmac_key,
    };
    let mut tx = pool.begin().await.map_err(database)?;
    let fetch_id = persist_source_fetch(
        &mut tx,
        context.run_id,
        context.source_id,
        context.target_url,
        context.operation,
        context.response,
        context.digest,
        context.object_key,
    )
    .await?;
    let inserted = insert_source_document_revision(&mut tx, &context, fetch_id).await?;
    if let Some(document_id) = inserted {
        persist_stored_source_document(&mut tx, &context, document_id).await?;
    }
    persist_source_checkpoint(&mut tx, &context).await?;
    tx.commit().await.map_err(database)?;
    Ok(inserted.is_some())
}

async fn insert_source_document_revision(
    tx: &mut Transaction<'_, Postgres>,
    context: &SourceTargetPersistence<'_>,
    fetch_id: Uuid,
) -> Result<Option<Uuid>, Failure> {
    if context.mode == "DRY_RUN" {
        return Ok(None);
    }
    let document_id = sqlx::query_scalar!(
        "SELECT (raw.insert_source_document_revision($1,$2,$3,$4,$5,clock_timestamp(),$6::timestamptz,$7,$8,$9,$10,$11::core.source_document_status,$12,$13,$14,$15,$16,$17)).id",
        context.source_id,
        format!("{}:{}", context.operation.id, context.target.external_id),
        &context.target.revision,
        context.target_url,
        fetch_id,
        context.target.published_at.as_deref() as _,
        if context.response.content_type.is_empty() {
            context.target.content_type.as_str()
        } else {
            context.response.content_type.as_str()
        },
        context.digest,
        i64::try_from(context.response.bytes.len()).unwrap_or(i64::MAX),
        context.object_key,
        "FETCHED" as _,
        Option::<&str>::None,
        Option::<&str>::None,
        Option::<&str>::None,
        json!([]),
        Option::<&str>::None,
        json!({"connectorOperationId":context.operation.id,"sourceRunId":context.run_id}),
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(database)?
    .ok_or_else(|| {
        Failure::Retryable(
            "DATABASE_UNAVAILABLE",
            "insert_source_document_revision unexpectedly returned null".to_owned(),
        )
    })?;
    Ok(Some(document_id))
}

async fn persist_stored_source_document(
    tx: &mut Transaction<'_, Postgres>,
    context: &SourceTargetPersistence<'_>,
    document_id: Uuid,
) -> Result<(), Failure> {
    if context.response.content_type == "application/json" {
        persist_structured_json(
            tx,
            context.source_id,
            context.operation,
            document_id,
            &context.response.bytes,
            context.job_id,
            context.job_fencing_token,
            context.supplier_identifier_hmac_key,
        )
        .await?;
    }
    sqlx::query!(
        "SELECT ops.enqueue_outbox('source_document',$1,1,'source.document_stored.v1',$2,clock_timestamp())",
        document_id.to_string(),
        json!({
            "content_sha256":context.digest,
            "source_document_id":document_id,
            "source_id":context.source_id,
        }),
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(database)?;
    Ok(())
}

async fn persist_source_checkpoint(
    tx: &mut Transaction<'_, Postgres>,
    context: &SourceTargetPersistence<'_>,
) -> Result<(), Failure> {
    sqlx::query!(
        "INSERT INTO ops.source_checkpoints(source_id,partition_key,cursor_payload,remote_high_watermark,last_success_at)          VALUES($1,$2,$3,$4,clock_timestamp())          ON CONFLICT(source_id,partition_key) DO UPDATE SET cursor_payload=EXCLUDED.cursor_payload,            remote_high_watermark=EXCLUDED.remote_high_watermark,last_success_at=EXCLUDED.last_success_at,            version=ops.source_checkpoints.version+1,updated_at=clock_timestamp()",
        context.source_id,
        context.operation.id,
        json!({
            "operationId":context.operation.id,
            "digest":context.digest,
            "sourceRunId":context.run_id,
        }),
        context.digest,
    )
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    Ok(())
}
