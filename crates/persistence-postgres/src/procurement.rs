#![forbid(unsafe_code)]

use serde::{Serialize, de::DeserializeOwned};
use sqlx::PgPool;
use uuid::Uuid;

/// PostgreSQL boundary for immutable procurement decisions.  The procedures
/// own validation, predecessor locks, audit/outbox writes and idempotency;
/// callers never write the core tables directly.
#[derive(Clone)]
pub struct ProcurementRepository {
    pool: PgPool,
}

impl ProcurementRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn record_supplier_identity_resolution<Request, Receipt>(
        &self,
        request: &Request,
    ) -> Result<Receipt, sqlx::Error>
    where
        Request: Serialize + Sync,
        Receipt: DeserializeOwned + Send + Unpin + 'static,
    {
        let receipt: sqlx::types::Json<Receipt> =
            sqlx::query_scalar("SELECT core.record_supplier_identity_resolution_v1($1::jsonb)")
                .bind(sqlx::types::Json(request))
                .fetch_one(&self.pool)
                .await?;
        Ok(receipt.0)
    }

    pub async fn record_supplier_relationship_assertion<Request, Receipt>(
        &self,
        request: &Request,
    ) -> Result<Receipt, sqlx::Error>
    where
        Request: Serialize + Sync,
        Receipt: DeserializeOwned + Send + Unpin + 'static,
    {
        let receipt: sqlx::types::Json<Receipt> =
            sqlx::query_scalar("SELECT core.record_supplier_relationship_assertion_v1($1::jsonb)")
                .bind(sqlx::types::Json(request))
                .fetch_one(&self.pool)
                .await?;
        Ok(receipt.0)
    }

    pub async fn decide_supplier_relationship_assertion<Request, Receipt>(
        &self,
        assertion_id: Uuid,
        request: &Request,
    ) -> Result<Receipt, sqlx::Error>
    where
        Request: Serialize + Sync,
        Receipt: DeserializeOwned + Send + Unpin + 'static,
    {
        let receipt: sqlx::types::Json<Receipt> = sqlx::query_scalar(
            "SELECT core.decide_supplier_relationship_assertion_v1($1, $2::jsonb)",
        )
        .bind(assertion_id)
        .bind(sqlx::types::Json(request))
        .fetch_one(&self.pool)
        .await?;
        Ok(receipt.0)
    }
}
