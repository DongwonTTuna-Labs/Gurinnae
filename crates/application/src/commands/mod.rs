use serde::Serialize;
use thiserror::Error;
use uuid::Uuid;

use crate::{authorization::ActorContext, idempotency::IdempotencyRequest};

pub struct CommandEnvelope<T> {
    pub request_id: Uuid,
    pub operation_id: &'static str,
    pub actor: ActorContext,
    pub idempotency: IdempotencyRequest,
    pub expected_version: Option<i64>,
    pub payload: T,
}

impl<T: Serialize> CommandEnvelope<T> {
    pub fn validate(&self) -> Result<(), CommandError> {
        if self.operation_id.is_empty()
            || self.expected_version.is_some_and(|version| version < 0)
            || serde_json::to_vec(&self.payload).is_err()
        {
            return Err(CommandError::InvalidCommand);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CommandReceipt {
    pub operation_id: &'static str,
    pub request_id: Uuid,
    pub resource_id: Option<String>,
    pub resource_version: Option<i64>,
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum CommandError {
    #[error("command payload or concurrency contract is invalid")]
    InvalidCommand,
    #[error("command expected version conflicts with the current aggregate")]
    VersionConflict,
}
