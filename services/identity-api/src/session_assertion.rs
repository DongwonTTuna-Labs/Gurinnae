use gurine_auth::{
    assertion::service::{AssertionKey, KeyRing},
    envelope::{EnvelopeKey, EnvelopeKeyRing},
};
use thiserror::Error;

use crate::config::Config;

pub struct SessionAssertionMaterial {
    pub service_keys: KeyRing,
    pub actor_key: AssertionKey,
    pub field_keys: EnvelopeKeyRing,
}

#[derive(Debug, Error)]
#[error("identity assertion key is invalid")]
pub struct SessionAssertionError;

impl SessionAssertionMaterial {
    pub fn from_config(config: &Config) -> Result<Self, SessionAssertionError> {
        Ok(Self {
            service_keys: KeyRing {
                current: assertion_key(&config.service_key_current)?,
                previous: config
                    .service_key_previous
                    .as_deref()
                    .map(assertion_key)
                    .transpose()?,
            },
            actor_key: assertion_key(&config.actor_key_current)?,
            field_keys: EnvelopeKeyRing {
                current: EnvelopeKey::new(config.field_key_current),
                previous: config.field_key_previous.map(EnvelopeKey::new),
            },
        })
    }
}

fn assertion_key(bytes: &[u8]) -> Result<AssertionKey, SessionAssertionError> {
    AssertionKey::from_bytes(bytes.to_vec()).map_err(|_| SessionAssertionError)
}
