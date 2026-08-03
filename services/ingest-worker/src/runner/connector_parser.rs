use sqlx::{Postgres, Transaction};
use uuid::Uuid;

use super::{Failure, database, sha256};

pub(super) struct ConnectorParserRun {
    pub id: Uuid,
    pub output_digest: String,
    pub extraction_receipt_sha256: String,
}

pub(super) async fn ensure(
    tx: &mut Transaction<'_, Postgres>,
    source_document_id: Uuid,
    record_digests: &[String],
) -> Result<ConnectorParserRun, Failure> {
    let output_record_count = i32::try_from(record_digests.len())
        .map_err(|_| Failure::Terminal("SOURCE_RECORD_LIMIT", source_document_id.to_string()))?;
    let output_digest = ordered_record_digest(record_digests);
    let extraction_receipt_sha256 = sha256(
        format!(
            "connector-structured-json-v1\u{1f}{source_document_id}\u{1f}v1\u{1f}{output_record_count}\u{1f}{output_digest}"
        )
        .as_bytes(),
    );
    if let Some(row) = sqlx::query!(
        "SELECT r.id FROM core.parser_runs r JOIN raw.source_documents d ON d.id=r.source_document_id \
         WHERE r.source_document_id=$1 AND r.parser_name='connector-structured-json' \
           AND r.parser_version='connector-structured-json-v1' AND r.status='SUCCEEDED' \
           AND r.input_content_sha256=d.content_sha256 AND r.extraction_schema_version='v1' \
           AND r.output_record_count=$2 AND r.output_digest=$3 \
           AND r.extraction_receipt_sha256=$4 \
         ORDER BY r.created_at,r.id LIMIT 1",
        source_document_id,
        output_record_count,
        &output_digest,
        &extraction_receipt_sha256,
    )
    .fetch_optional(&mut **tx)
    .await
    .map_err(database)?
    {
        return Ok(ConnectorParserRun {
            id: row.id,
            output_digest,
            extraction_receipt_sha256,
        });
    }
    let id = sqlx::query_scalar!(
        "INSERT INTO core.parser_runs( \
           source_document_id,parser_name,parser_version,status,output_record_count,output_digest, \
           started_at,completed_at,input_content_sha256,extraction_schema_version, \
           implementation_sha256,extraction_receipt_sha256) \
         SELECT d.id,'connector-structured-json','connector-structured-json-v1','SUCCEEDED',$2,$3, \
           clock_timestamp(),clock_timestamp(),d.content_sha256,'v1',p.implementation_digest,$4 \
         FROM raw.source_documents d JOIN core.parser_versions p \
           ON p.parser_name='connector-structured-json' \
          AND p.version='connector-structured-json-v1' AND p.status='ACTIVE' \
         WHERE d.id=$1 RETURNING id",
        source_document_id,
        output_record_count,
        &output_digest,
        &extraction_receipt_sha256,
    )
    .fetch_optional(&mut **tx)
    .await
    .map_err(database)?
    .ok_or_else(|| {
        Failure::Terminal(
            "CONNECTOR_PARSER_NOT_ACTIVE",
            "connector-structured-json-v1".to_owned(),
        )
    })?;
    Ok(ConnectorParserRun {
        id,
        output_digest,
        extraction_receipt_sha256,
    })
}

fn ordered_record_digest(record_digests: &[String]) -> String {
    let mut preimage = format!(
        "connector-structured-json-output-v1\u{1f}{}",
        record_digests.len()
    );
    for digest in record_digests {
        preimage.push('\u{1e}');
        preimage.push_str(digest);
    }
    sha256(preimage.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::ordered_record_digest;

    #[test]
    fn ordered_output_digest_is_deterministic_and_order_sensitive() {
        let first = vec!["a".repeat(64), "b".repeat(64)];
        let reversed = vec!["b".repeat(64), "a".repeat(64)];
        assert_eq!(ordered_record_digest(&first), ordered_record_digest(&first));
        assert_ne!(
            ordered_record_digest(&first),
            ordered_record_digest(&reversed)
        );
        assert_ne!(
            ordered_record_digest(&first),
            ordered_record_digest(&first[..1])
        );
    }
}
