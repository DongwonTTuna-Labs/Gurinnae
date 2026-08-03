use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use uuid::Uuid;

use crate::{
    error::{DomainError, validated_text},
    ids::JobId,
};

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum JobStatus {
    Queued,
    Leased,
    Succeeded,
    Failed,
    DeadLetter,
    Cancelled,
    Quarantined,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Job {
    pub id: JobId,
    pub queue: String,
    pub job_type: String,
    pub status: JobStatus,
    pub attempt_count: u32,
    pub max_attempts: u32,
    pub fencing_token: i64,
    pub lease_token: Option<Uuid>,
    pub lease_expires_at: Option<OffsetDateTime>,
}

impl Job {
    pub fn queued(
        id: JobId,
        queue: impl Into<String>,
        job_type: impl Into<String>,
        max_attempts: u32,
    ) -> Result<Self, DomainError> {
        if max_attempts == 0 {
            return Err(DomainError::InvalidTransition);
        }
        Ok(Self {
            id,
            queue: validated_text(queue, 100)?,
            job_type: validated_text(job_type, 200)?,
            status: JobStatus::Queued,
            attempt_count: 0,
            max_attempts,
            fencing_token: 0,
            lease_token: None,
            lease_expires_at: None,
        })
    }

    pub fn lease(
        &mut self,
        lease_token: Uuid,
        expires_at: OffsetDateTime,
    ) -> Result<i64, DomainError> {
        if self.status != JobStatus::Queued || self.attempt_count >= self.max_attempts {
            return Err(DomainError::InvalidTransition);
        }
        self.status = JobStatus::Leased;
        self.fencing_token = self
            .fencing_token
            .checked_add(1)
            .ok_or(DomainError::InvalidTransition)?;
        self.lease_token = Some(lease_token);
        self.lease_expires_at = Some(expires_at);
        Ok(self.fencing_token)
    }

    pub fn complete(&mut self, lease_token: Uuid, fencing_token: i64) -> Result<(), DomainError> {
        self.require_lease(lease_token, fencing_token)?;
        self.status = JobStatus::Succeeded;
        self.clear_lease();
        Ok(())
    }

    pub fn fail(&mut self, lease_token: Uuid, fencing_token: i64) -> Result<(), DomainError> {
        self.require_lease(lease_token, fencing_token)?;
        self.attempt_count += 1;
        self.status = if self.attempt_count >= self.max_attempts {
            JobStatus::DeadLetter
        } else {
            JobStatus::Queued
        };
        self.clear_lease();
        Ok(())
    }

    fn require_lease(&self, lease_token: Uuid, fencing_token: i64) -> Result<(), DomainError> {
        if self.status != JobStatus::Leased
            || self.lease_token != Some(lease_token)
            || self.fencing_token != fencing_token
        {
            return Err(DomainError::InvalidTransition);
        }
        Ok(())
    }

    fn clear_lease(&mut self) {
        self.lease_token = None;
        self.lease_expires_at = None;
    }
}
