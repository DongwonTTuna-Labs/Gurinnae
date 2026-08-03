use std::{collections::VecDeque, convert::Infallible, sync::Mutex, time::Duration};

use gurine_application::ports::DomainEventSink;
use gurine_auth::{
    assertion::service::{AssertionKey, KeyRing},
    envelope::{EnvelopeKey, EnvelopeKeyRing},
};
use gurine_persistence_postgres::pool::{PoolConfig, PoolError, connect};
use serde_json::Value;
use sqlx::PgPool;
use thiserror::Error;

use crate::config::Config;

pub struct AppState {
    pub pool: PgPool,
    pub assertion_keys: KeyRing,
    pub field_keys: EnvelopeKeyRing,
    pub domain_events: Mutex<InProcessDomainEventJournal>,
}

const DOMAIN_EVENT_JOURNAL_CAPACITY: usize = 4096;

#[derive(Clone, Debug, PartialEq)]
pub struct InProcessDomainEvent {
    pub event_type: String,
    pub aggregate_id: String,
    pub version: i64,
    pub payload: Value,
}

#[derive(Default)]
pub struct InProcessDomainEventJournal {
    events: VecDeque<InProcessDomainEvent>,
}

impl DomainEventSink for InProcessDomainEventJournal {
    type Error = Infallible;

    fn append(
        &mut self,
        event_type: &str,
        aggregate_id: &str,
        version: i64,
        payload: &Value,
    ) -> Result<(), Self::Error> {
        if self.events.len() == DOMAIN_EVENT_JOURNAL_CAPACITY {
            self.events.pop_front();
        }
        self.events.push_back(InProcessDomainEvent {
            event_type: event_type.to_owned(),
            aggregate_id: aggregate_id.to_owned(),
            version,
            payload: payload.clone(),
        });
        Ok(())
    }
}

impl InProcessDomainEventJournal {
    #[cfg(test)]
    pub fn snapshot(&self) -> Vec<InProcessDomainEvent> {
        self.events.iter().cloned().collect()
    }
}

#[derive(Debug, Error)]
pub enum StateError {
    #[error(transparent)]
    Pool(#[from] PoolError),
    #[error("identity assertion key is invalid")]
    AssertionKey,
}

impl AppState {
    pub async fn initialize(config: &Config) -> Result<Self, StateError> {
        let pool = connect(&PoolConfig {
            database_url: config.database_url.clone(),
            max_connections: 20,
            acquire_timeout: Duration::from_secs(10),
        })
        .await?;
        let current = AssertionKey::from_bytes(config.assertion_key_current.clone())
            .map_err(|_| StateError::AssertionKey)?;
        let previous = config
            .assertion_key_previous
            .clone()
            .map(AssertionKey::from_bytes)
            .transpose()
            .map_err(|_| StateError::AssertionKey)?;
        Ok(Self {
            pool,
            assertion_keys: KeyRing { current, previous },
            field_keys: EnvelopeKeyRing {
                current: EnvelopeKey::new(config.field_key_current),
                previous: config.field_key_previous.map(EnvelopeKey::new),
            },
            domain_events: Mutex::new(InProcessDomainEventJournal::default()),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn domain_event_journal_implements_the_application_sink() {
        let mut journal = InProcessDomainEventJournal::default();
        DomainEventSink::append(
            &mut journal,
            "case.state_transitioned.v1",
            "case-1",
            2,
            &json!({"toState":"INVESTIGATING"}),
        )
        .expect("infallible sink");
        assert_eq!(journal.snapshot().len(), 1);
        assert_eq!(
            journal.snapshot()[0].event_type,
            "case.state_transitioned.v1"
        );
    }
}
