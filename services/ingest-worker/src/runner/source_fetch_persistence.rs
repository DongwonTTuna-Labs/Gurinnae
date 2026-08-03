use super::{ConnectorOperation, Failure, SourceResponse, Uuid, database};

#[expect(
    clippy::too_many_arguments,
    reason = "fetch persistence binds the leased run and exact source response metadata"
)]
pub(super) async fn persist_source_fetch(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    run_id: Uuid,
    source_id: &str,
    target_url: &str,
    operation: &'static ConnectorOperation,
    response: &SourceResponse,
    digest: &str,
    object_key: &str,
) -> Result<Uuid, Failure> {
    let fetch_id = Uuid::new_v4();
    sqlx::query!(
        "INSERT INTO raw.source_fetches(id,source_id,source_run_id,external_locator,            requested_at,completed_at,http_status,content_type,payload_sha256,payload_size_bytes,object_key)          VALUES($1,$2,$3,$4,clock_timestamp(),clock_timestamp(),$5,$6,$7,$8,$9)          ON CONFLICT(source_id,external_locator,payload_sha256) DO NOTHING",
        fetch_id,
        source_id,
        run_id,
        target_url,
        i32::from(response.http_status),
        &response.content_type,
        digest,
        i64::try_from(response.bytes.len()).map_err(|_| {
            Failure::Terminal("SOURCE_PAYLOAD_TOO_LARGE", operation.id.to_owned())
        })?,
        object_key,
    )
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    Ok(fetch_id)
}
