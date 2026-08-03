struct StructuredJsonContext<'a> {
    source_id: &'a str,
    operation: &'a ConnectorOperation,
    document_id: Uuid,
    job_id: Uuid,
    job_fencing_token: i64,
    supplier_identifier_hmac_key: &'a [u8],
}

struct PersistedConnectorRecord {
    id: Uuid,
    index: i32,
}

async fn persist_structured_json(
    tx: &mut Transaction<'_, Postgres>,
    source_id: &str,
    operation: &ConnectorOperation,
    document_id: Uuid,
    bytes: &[u8],
    job_id: Uuid,
    job_fencing_token: i64,
    supplier_identifier_hmac_key: &[u8],
) -> Result<(), Failure> {
    let value: Value = serde_json::from_slice(bytes)
        .map_err(|error| Failure::Terminal("SOURCE_PAYLOAD_MALFORMED", error.to_string()))?;
    let records = structured_records::extract(source_id, operation, &value);
    let record_digests = structured_record_digests(&records)?;
    let parser_run = connector_parser::ensure(tx, document_id, &record_digests).await?;
    let context = StructuredJsonContext {
        source_id,
        operation,
        document_id,
        job_id,
        job_fencing_token,
        supplier_identifier_hmac_key,
    };
    for (index, record) in records.iter().enumerate() {
        let payload_sha256 = record_digests.get(index).ok_or_else(|| {
            Failure::Retryable(
                "PARSER_OUTPUT_CONTRACT_MISMATCH",
                "record digest ordinal missing".to_owned(),
            )
        })?;
        let persisted = persist_connector_record(
            tx,
            &context,
            parser_run.id,
            index,
            record,
            payload_sha256,
        )
        .await?;
        normalize_structured_record(tx, &context, record, &persisted).await?;
    }
    mark_connector_document_parsed(tx, &context, &parser_run, records.len()).await
}

fn structured_record_digests(
    records: &[structured_records::StructuredRecord],
) -> Result<Vec<String>, Failure> {
    records
        .iter()
        .map(|record| {
            serde_json::to_vec(&record.value)
                .map(|bytes| sha256(&bytes))
                .map_err(|error| Failure::Terminal("SOURCE_PAYLOAD_MALFORMED", error.to_string()))
        })
        .collect()
}

async fn persist_connector_record(
    tx: &mut Transaction<'_, Postgres>,
    context: &StructuredJsonContext<'_>,
    parser_run_id: Uuid,
    index: usize,
    record: &structured_records::StructuredRecord,
    payload_sha256: &str,
) -> Result<PersistedConnectorRecord, Failure> {
    let record_index = i32::try_from(index)
        .map_err(|_| Failure::Terminal("SOURCE_RECORD_LIMIT", context.operation.id.to_owned()))?;
    let record_type = context.operation.kind.to_ascii_uppercase();
    sqlx::query!(
        "INSERT INTO raw.parsed_records(source_document_id,record_type,record_index,parser_version,payload,payload_sha256,parser_run_id) \
         VALUES($1,$2,$3,'connector-structured-json-v1',$4,$5,$6) \
         ON CONFLICT(source_document_id,record_type,record_index,parser_version) DO NOTHING",
        context.document_id,
        record_type,
        record_index,
        &record.value,
        payload_sha256,
        parser_run_id,
    )
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    let parsed = sqlx::query!(
        "SELECT id,payload_sha256,parser_run_id FROM raw.parsed_records \
         WHERE source_document_id=$1 AND record_type=$2 AND record_index=$3 \
           AND parser_version='connector-structured-json-v1'",
        context.document_id,
        record_type,
        record_index,
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(database)?;
    if parsed.payload_sha256.trim() != payload_sha256
        || parsed.parser_run_id != Some(parser_run_id)
    {
        return Err(Failure::Terminal(
            "PARSED_RECORD_REPLAY_CONFLICT",
            parsed.id.to_string(),
        ));
    }
    Ok(PersistedConnectorRecord {
        id: parsed.id,
        index: record_index,
    })
}

async fn normalize_structured_record(
    tx: &mut Transaction<'_, Postgres>,
    context: &StructuredJsonContext<'_>,
    record: &structured_records::StructuredRecord,
    persisted: &PersistedConnectorRecord,
) -> Result<(), Failure> {
    if context.source_id == "koneps-contracts" {
        normalize_koneps_contract(
            tx,
            context.source_id,
            context.operation,
            context.document_id,
            persisted.id,
            persisted.index,
            &record.locator,
            &record.value,
            context.supplier_identifier_hmac_key,
        )
        .await?;
    } else if context.source_id == "open-dart" {
        normalize_dart_supplier(
            tx,
            context.document_id,
            persisted.id,
            persisted.index,
            &record.value,
            context.supplier_identifier_hmac_key,
        )
        .await?;
    }
    Ok(())
}

async fn mark_connector_document_parsed(
    tx: &mut Transaction<'_, Postgres>,
    context: &StructuredJsonContext<'_>,
    parser_run: &connector_parser::ConnectorParserRun,
    record_count: usize,
) -> Result<(), Failure> {
    sqlx::query!(
        "SELECT raw.mark_connector_source_document_parsed($1,$2,$3,$4,$5)",
        context.document_id,
        "connector-structured-json",
        "connector-structured-json-v1",
        "v1",
        json!({
            "structuredRecordCount":record_count,
            "connectorOperationId":context.operation.id,
            "producerJobId":context.job_id,
            "jobFencingToken":context.job_fencing_token,
            "parserRunId":parser_run.id,
            "parsedOutputDigest":parser_run.output_digest,
            "extractionReceiptSha256":parser_run.extraction_receipt_sha256,
        }),
    )
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    Ok(())
}
