use serde_json::Value;
use uuid::Uuid;

use gurine_persistence_postgres::procurement::ProcurementRepository;

use super::ServiceError;
use crate::state::AppState;

fn parse(body: &[u8]) -> Result<Value, ServiceError> {
    let value: Value = serde_json::from_slice(body).map_err(|_| ServiceError::InvalidRequest)?;
    if !value.is_object() {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(value)
}

pub async fn record_supplier_identity_resolution(
    state: &AppState,
    body: &[u8],
) -> Result<Value, ServiceError> {
    let request = parse(body)?;
    ProcurementRepository::new(state.pool.clone())
        .record_supplier_identity_resolution::<_, Value>(&request)
        .await
        .map_err(|_| ServiceError::Persistence)
}

pub async fn record_supplier_relationship_assertion(
    state: &AppState,
    body: &[u8],
) -> Result<Value, ServiceError> {
    let request = parse(body)?;
    ProcurementRepository::new(state.pool.clone())
        .record_supplier_relationship_assertion::<_, Value>(&request)
        .await
        .map_err(|_| ServiceError::Persistence)
}

pub async fn decide_supplier_relationship_assertion(
    state: &AppState,
    body: &[u8],
) -> Result<Value, ServiceError> {
    let request = parse(body)?;
    let assertion_id = request
        .get("assertionId")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or(ServiceError::InvalidRequest)?;
    ProcurementRepository::new(state.pool.clone())
        .decide_supplier_relationship_assertion::<_, Value>(assertion_id, &request)
        .await
        .map_err(|_| ServiceError::Persistence)
}
