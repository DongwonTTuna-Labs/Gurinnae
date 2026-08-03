use serde_json::Value;
use time::OffsetDateTime;
use uuid::Uuid;

pub trait Clock: Send + Sync {
    fn now(&self) -> OffsetDateTime;
}

pub trait IdGenerator: Send + Sync {
    fn generate(&self) -> Uuid;
}

pub trait DomainEventSink: Send + Sync {
    type Error;

    fn append(
        &mut self,
        event_type: &str,
        aggregate_id: &str,
        version: i64,
        payload: &Value,
    ) -> Result<(), Self::Error>;
}

pub trait AuditSink: Send + Sync {
    type Error;

    fn record(
        &mut self,
        action: &str,
        outcome: &str,
        actor_id: Uuid,
        object_id: Option<&str>,
    ) -> Result<(), Self::Error>;
}
