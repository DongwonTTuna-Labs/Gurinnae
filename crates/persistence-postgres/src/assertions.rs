use sqlx::PgPool;
use time::OffsetDateTime;
use uuid::Uuid;

pub struct AssertionConsumption<'a> {
    pub assertion_type: &'a str,
    pub jti: &'a str,
    pub issuer: &'a str,
    pub audience: &'a str,
    pub expires_at_unix: i64,
    pub request_digest: &'a str,
}

pub async fn consume(
    pool: &PgPool,
    assertion: &AssertionConsumption<'_>,
) -> Result<bool, sqlx::Error> {
    let jti =
        Uuid::parse_str(assertion.jti).map_err(|error| sqlx::Error::Decode(Box::new(error)))?;
    let expires_at = OffsetDateTime::from_unix_timestamp(assertion.expires_at_unix)
        .map_err(|error| sqlx::Error::Decode(Box::new(error)))?;
    sqlx::query_scalar("SELECT ops.consume_assertion_jti($1, $2, $3, $4, $5, $6)")
        .bind(assertion.assertion_type)
        .bind(jti)
        .bind(assertion.issuer)
        .bind(assertion.audience)
        .bind(expires_at)
        .bind(assertion.request_digest)
        .fetch_one(pool)
        .await
}
