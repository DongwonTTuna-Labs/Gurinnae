use std::{collections::HashSet, sync::Mutex};

use super::errors::AssertionError;

pub trait ReplayGuard: Send + Sync {
    fn consume(&self, issuer: &str, jti: &str, expires_at: i64) -> Result<(), AssertionError>;
}

#[derive(Debug, Default)]
pub struct MemoryReplayGuard {
    consumed: Mutex<HashSet<(String, String)>>,
}

impl ReplayGuard for MemoryReplayGuard {
    fn consume(&self, issuer: &str, jti: &str, _expires_at: i64) -> Result<(), AssertionError> {
        let mut consumed = self
            .consumed
            .lock()
            .map_err(|_| AssertionError::ReplayGuardUnavailable)?;
        if !consumed.insert((issuer.to_owned(), jti.to_owned())) {
            return Err(AssertionError::Replayed);
        }
        Ok(())
    }
}
