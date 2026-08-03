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
        let receipt = sqlx::query_scalar!(
            "SELECT core.record_supplier_identity_resolution_v1($1::jsonb)",
            sqlx::types::Json(request) as _,
        )
        .fetch_one(&self.pool)
        .await?
        .ok_or_else(|| sqlx::Error::Decode(Box::new(sqlx::error::UnexpectedNullError)))?;
        serde_json::from_value(receipt).map_err(|error| sqlx::Error::Decode(Box::new(error)))
    }

    pub async fn record_supplier_relationship_assertion<Request, Receipt>(
        &self,
        request: &Request,
    ) -> Result<Receipt, sqlx::Error>
    where
        Request: Serialize + Sync,
        Receipt: DeserializeOwned + Send + Unpin + 'static,
    {
        let receipt = sqlx::query_scalar!(
            "SELECT core.record_supplier_relationship_assertion_v1($1::jsonb)",
            sqlx::types::Json(request) as _,
        )
        .fetch_one(&self.pool)
        .await?
        .ok_or_else(|| sqlx::Error::Decode(Box::new(sqlx::error::UnexpectedNullError)))?;
        serde_json::from_value(receipt).map_err(|error| sqlx::Error::Decode(Box::new(error)))
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
        let receipt = sqlx::query_scalar!(
            "SELECT core.decide_supplier_relationship_assertion_v1($1, $2::jsonb)",
            assertion_id,
            sqlx::types::Json(request) as _,
        )
        .fetch_one(&self.pool)
        .await?
        .ok_or_else(|| sqlx::Error::Decode(Box::new(sqlx::error::UnexpectedNullError)))?;
        serde_json::from_value(receipt).map_err(|error| sqlx::Error::Decode(Box::new(error)))
    }
}
