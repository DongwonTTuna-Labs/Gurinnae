use serde_json::Value;
use sqlx::{PgPool, Row};
use time::{Duration, OffsetDateTime};

#[derive(Clone, Debug)]
pub struct StoredResponse {
    pub status: i32,
    pub body: Value,
}

#[derive(Clone, Debug)]
pub enum Claim {
    Execute,
    Replay(StoredResponse),
    RequestConflict,
    InFlight,
}

pub async fn claim(
    pool: &PgPool,
    scope: &str,
    key_hash: &str,
    request_hash: &str,
) -> Result<Claim, sqlx::Error> {
    let expires_at = OffsetDateTime::now_utc() + Duration::hours(24);
    let inserted = sqlx::query(
        "INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,expires_at) \
         VALUES($1,$2,$3,$4) ON CONFLICT(scope,key_hash) DO NOTHING",
    )
    .bind(scope)
    .bind(key_hash)
    .bind(request_hash)
    .bind(expires_at)
    .execute(pool)
    .await?
    .rows_affected();
    if inserted == 1 {
        return Ok(Claim::Execute);
    }
    let row = sqlx::query(
        "SELECT request_hash,response_status,response_body FROM ops.idempotency_keys \
         WHERE scope=$1 AND key_hash=$2 AND expires_at>clock_timestamp()",
    )
    .bind(scope)
    .bind(key_hash)
    .fetch_optional(pool)
    .await?;
    let Some(row) = row else {
        return Ok(Claim::InFlight);
    };
    let stored_request_hash: String = row.try_get("request_hash")?;
    if stored_request_hash != request_hash {
        return Ok(Claim::RequestConflict);
    }
    let status: Option<i32> = row.try_get("response_status")?;
    let body: Option<Value> = row.try_get("response_body")?;
    match (status, body) {
        (Some(status), Some(body)) => Ok(Claim::Replay(StoredResponse { status, body })),
        _ => Ok(Claim::InFlight),
    }
}

pub async fn complete(
    pool: &PgPool,
    scope: &str,
    key_hash: &str,
    request_hash: &str,
    response: &StoredResponse,
) -> Result<bool, sqlx::Error> {
    Ok(sqlx::query(
        "UPDATE ops.idempotency_keys SET response_status=$4,response_body=$5 \
         WHERE scope=$1 AND key_hash=$2 AND request_hash=$3 AND response_status IS NULL",
    )
    .bind(scope)
    .bind(key_hash)
    .bind(request_hash)
    .bind(response.status)
    .bind(&response.body)
    .execute(pool)
    .await?
    .rows_affected()
        == 1)
}
