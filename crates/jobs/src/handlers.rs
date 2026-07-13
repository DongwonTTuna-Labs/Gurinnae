use serde_json::Value;
use thiserror::Error;

use crate::lease::JobLease;

pub trait JobHandler: Send + Sync {
    fn job_type(&self) -> &'static str;
    fn handle(&self, lease: &JobLease, payload: &Value) -> Result<Value, HandlerError>;
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum HandlerError {
    #[error("job lease is expired")]
    ExpiredLease,
    #[error("job payload is invalid")]
    InvalidPayload,
    #[error("job handler failed with a retryable error")]
    Retryable,
    #[error("job handler failed with a terminal error")]
    Terminal,
}
