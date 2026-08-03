use sqlx::PgPool;

#[derive(Clone)]
pub struct VersionRepository {
    pool: PgPool,
}

impl VersionRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn current_version(
        &self,
        relation: &str,
        id: &str,
    ) -> Result<Option<i64>, sqlx::Error> {
        match relation {
            "editorial.cases" => {
                sqlx::query_scalar!(
                    "SELECT version::bigint FROM editorial.cases WHERE id::text = $1",
                    id,
                )
                .fetch_optional(&self.pool)
                .await
            }
            "core.rule_versions" => {
                let version = sqlx::query_scalar!(
                    "SELECT version::bigint FROM core.rule_versions WHERE id::text = $1",
                    id,
                )
                .fetch_optional(&self.pool)
                .await?;
                version
                    .map(|value| {
                        value
                            .ok_or_else(|| {
                                sqlx::Error::Decode(Box::new(sqlx::error::UnexpectedNullError))
                            })
                            .map(Some)
                    })
                    .unwrap_or(Ok(None))
            }
            "ops.source_runs" => {
                sqlx::query_scalar!(
                    "SELECT version::bigint FROM ops.source_runs WHERE id::text = $1",
                    id,
                )
                .fetch_optional(&self.pool)
                .await
            }
            "ops.users" => {
                sqlx::query_scalar!(
                    "SELECT version::bigint FROM ops.users WHERE id::text = $1",
                    id,
                )
                .fetch_optional(&self.pool)
                .await
            }
            _ => Err(sqlx::Error::Protocol(
                "relation is not repository-allowlisted".to_owned(),
            )),
        }
    }
}
