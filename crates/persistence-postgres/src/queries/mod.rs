use serde_json::Value;
use sqlx::{PgPool, Row};

pub async fn public_case_by_slug(pool: &PgPool, slug: &str) -> Result<Option<Value>, sqlx::Error> {
    sqlx::query("SELECT to_jsonb(public_case) AS projection FROM public.cases AS public_case WHERE slug = $1")
        .bind(slug)
        .fetch_optional(pool)
        .await?
        .map(|row| row.try_get("projection"))
        .transpose()
}
