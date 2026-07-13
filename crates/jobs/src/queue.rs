use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum QueueState {
    Running,
    PausedNew,
    Draining,
    Paused,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct QueueControl {
    pub name: String,
    pub state: QueueState,
    pub reason: Option<String>,
    pub version: i64,
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum QueueError {
    #[error("queue state transition is invalid")]
    InvalidTransition,
    #[error("queue version conflicts")]
    VersionConflict,
}

impl QueueControl {
    pub fn transition(
        &mut self,
        next: QueueState,
        expected_version: i64,
        reason: Option<String>,
    ) -> Result<(), QueueError> {
        if self.version != expected_version {
            return Err(QueueError::VersionConflict);
        }
        let allowed = matches!(
            (self.state, next),
            (
                QueueState::Running,
                QueueState::PausedNew | QueueState::Draining | QueueState::Paused
            ) | (
                QueueState::PausedNew,
                QueueState::Running | QueueState::Draining | QueueState::Paused
            ) | (
                QueueState::Draining,
                QueueState::Paused | QueueState::Running
            ) | (QueueState::Paused, QueueState::Running)
        );
        if !allowed {
            return Err(QueueError::InvalidTransition);
        }
        self.state = next;
        self.reason = reason;
        self.version += 1;
        Ok(())
    }
}
