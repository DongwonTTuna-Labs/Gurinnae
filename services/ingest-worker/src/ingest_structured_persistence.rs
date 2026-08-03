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
    parser_run_id: Uuid,
    payload_sha256: String,
}

#[expect(
    clippy::too_many_arguments,
    reason = "structured persistence binds source provenance, job fencing, and supplier identity material"
)]
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
        let persisted =
            persist_connector_record(tx, &context, parser_run.id, index, record, payload_sha256)
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
    if parsed.payload_sha256.trim() != payload_sha256 || parsed.parser_run_id != Some(parser_run_id)
    {
        return Err(Failure::Terminal(
            "PARSED_RECORD_REPLAY_CONFLICT",
            parsed.id.to_string(),
        ));
    }
    Ok(PersistedConnectorRecord {
        id: parsed.id,
        index: record_index,
        parser_run_id,
        payload_sha256: payload_sha256.to_owned(),
    })
}

async fn normalize_structured_record(
    tx: &mut Transaction<'_, Postgres>,
    context: &StructuredJsonContext<'_>,
    record: &structured_records::StructuredRecord,
    persisted: &PersistedConnectorRecord,
) -> Result<(), Failure> {
    match context.source_id {
        "koneps-contracts" => {
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
            .await?
        }
        "koneps-bid-results" => normalize_koneps_bid_result_metadata(tx, context, record).await?,
        "open-dart" => normalize_open_dart_record(tx, context, record, persisted).await?,
        _ => {}
    }
    Ok(())
}

async fn normalize_koneps_bid_result_metadata(
    tx: &mut Transaction<'_, Postgres>,
    context: &StructuredJsonContext<'_>,
    record: &structured_records::StructuredRecord,
) -> Result<(), Failure> {
    if gurine_source_connectors::koneps_bid_results::normalize_metadata(
        context.operation.id,
        &record.value,
        context.supplier_identifier_hmac_key,
    )
    .is_err()
    {
        data_quality_incident(
            tx,
            context.source_id,
            context.document_id,
            context.operation.id,
            "KONEPS_BID_RESULT_METADATA_INVALID",
        )
        .await?;
    }
    Ok(())
}

async fn normalize_open_dart_record(
    tx: &mut Transaction<'_, Postgres>,
    context: &StructuredJsonContext<'_>,
    record: &structured_records::StructuredRecord,
    persisted: &PersistedConnectorRecord,
) -> Result<(), Failure> {
    normalize_dart_supplier(
        tx,
        context.document_id,
        persisted.id,
        persisted.index,
        &record.value,
        context.supplier_identifier_hmac_key,
    )
    .await?;
    match context.operation.kind {
        "person-context-list" => {
            normalize_dart_person_observation(tx, context, record, persisted).await?
        }
        "holder-context-list" => validate_dart_shareholder_observation(tx, context, record).await?,
        _ => {}
    }
    Ok(())
}

async fn normalize_dart_person_observation(
    tx: &mut Transaction<'_, Postgres>,
    context: &StructuredJsonContext<'_>,
    record: &structured_records::StructuredRecord,
    persisted: &PersistedConnectorRecord,
) -> Result<(), Failure> {
    match gurine_source_connectors::open_dart::normalize_person_observation(
        context.operation.id,
        &record.value,
        &record.locator,
    ) {
        Ok(observation) => {
            record_dart_executive_endpoint(tx, context, persisted, &observation).await
        }
        Err(_) => record_dart_context_incident(tx, context).await,
    }
}

async fn validate_dart_shareholder_observation(
    tx: &mut Transaction<'_, Postgres>,
    context: &StructuredJsonContext<'_>,
    record: &structured_records::StructuredRecord,
) -> Result<(), Failure> {
    if gurine_source_connectors::open_dart::normalize_shareholder_observation(
        context.operation.id,
        &record.value,
        &record.locator,
    )
    .is_err()
    {
        record_dart_context_incident(tx, context).await?;
    }
    Ok(())
}

async fn record_dart_context_incident(
    tx: &mut Transaction<'_, Postgres>,
    context: &StructuredJsonContext<'_>,
) -> Result<(), Failure> {
    data_quality_incident(
        tx,
        context.source_id,
        context.document_id,
        context.operation.id,
        "OPEN_DART_DISCLOSURE_CONTEXT_INVALID",
    )
    .await
}

async fn record_dart_executive_endpoint(
    tx: &mut Transaction<'_, Postgres>,
    context: &StructuredJsonContext<'_>,
    persisted: &PersistedConnectorRecord,
    observation: &gurine_source_connectors::open_dart::OpenDartPersonObservation,
) -> Result<(), Failure> {
    let source = sqlx::query!(
        "SELECT asset_id,asset_revision,content_sha256 FROM raw.source_documents WHERE id=$1",
        context.document_id,
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(database)?;
    let source = DartEndpointSource {
        asset_id: source.asset_id,
        asset_revision: source.asset_revision,
        content_sha256: source.content_sha256.trim().to_owned(),
    };
    let command = dart_executive_endpoint_command(context, persisted, observation, &source)?;
    RelationshipGraphRepository::record_endpoint(tx, &command)
        .await
        .map_err(|error| relationship_graph_error(context.operation.id, error))?;
    Ok(())
}

fn dart_executive_endpoint_command(
    context: &StructuredJsonContext<'_>,
    persisted: &PersistedConnectorRecord,
    observation: &gurine_source_connectors::open_dart::OpenDartPersonObservation,
    source: &DartEndpointSource,
) -> Result<RecordRelationshipGraphEndpointV2, Failure> {
    let invalid = || typed_relationship_endpoint_mismatch(context.operation.id);
    Ok(RecordRelationshipGraphEndpointV2 {
        kind: RelationshipEndpointKindV2::Person,
        identity: RelationshipEndpointIdentityV2::Person {
            contextual_name: observation.contextual_name.clone(),
            role_title: observation.role_title.clone(),
        },
        source_kind: "DART_EXECUTIVE_STATUS".to_owned(),
        source_locator: observation.source_locator.clone(),
        identifier_digest: Sha256Digest::new(observation.identifier_digest.clone())
            .map_err(|_| invalid())?,
        source: ParsedRelationshipSourceV2 {
            document_id: RelationshipGraphSourceDocumentId::new(context.document_id)
                .map_err(|_| invalid())?,
            asset_id: RelationshipGraphSourceAssetId::new(source.asset_id)
                .map_err(|_| invalid())?,
            asset_revision: u64::try_from(source.asset_revision).map_err(|_| invalid())?,
            content_sha256: Sha256Digest::new(source.content_sha256.clone())
                .map_err(|_| invalid())?,
            parser_run_id: RelationshipGraphParserRunId::new(persisted.parser_run_id)
                .map_err(|_| invalid())?,
            parsed_record_id: RelationshipGraphParsedRecordId::new(persisted.id)
                .map_err(|_| invalid())?,
            parser_version: "connector-structured-json-v1".to_owned(),
            parsed_payload_sha256: Sha256Digest::new(persisted.payload_sha256.clone())
                .map_err(|_| invalid())?,
        },
    })
}

struct DartEndpointSource {
    asset_id: Uuid,
    asset_revision: i64,
    content_sha256: String,
}

fn typed_relationship_endpoint_mismatch(operation_id: &str) -> Failure {
    Failure::Terminal(
        "TYPED_RELATIONSHIP_ENDPOINT_CONTRACT_MISMATCH",
        operation_id.to_owned(),
    )
}

fn relationship_graph_error(operation_id: &str, error: sqlx::Error) -> Failure {
    if matches!(error, sqlx::Error::Decode(_)) {
        typed_relationship_endpoint_mismatch(operation_id)
    } else {
        database(error)
    }
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
