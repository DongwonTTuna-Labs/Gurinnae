use serde_json::Value;
use sqlx::PgPool;

pub async fn public_case_by_slug(pool: &PgPool, slug: &str) -> Result<Option<Value>, sqlx::Error> {
    sqlx::query!("SELECT to_jsonb(public_case) AS projection FROM public.cases AS public_case WHERE slug = $1", slug)
        .fetch_optional(pool)
        .await?
        .map(|row| {
            row.projection
                .ok_or_else(|| sqlx::Error::Decode(Box::new(sqlx::error::UnexpectedNullError)))
        })
        .transpose()
}
