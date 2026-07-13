use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

use crate::error::DomainError;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct TimeRange {
    pub starts_at: OffsetDateTime,
    pub ends_at: OffsetDateTime,
}

impl TimeRange {
    pub fn new(starts_at: OffsetDateTime, ends_at: OffsetDateTime) -> Result<Self, DomainError> {
        if starts_at >= ends_at {
            return Err(DomainError::InvalidTimeRange);
        }
        Ok(Self { starts_at, ends_at })
    }

    pub fn contains(self, instant: OffsetDateTime) -> bool {
        self.starts_at <= instant && instant < self.ends_at
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AggregateVersion(i64);

impl AggregateVersion {
    pub fn new(value: i64) -> Result<Self, DomainError> {
        if value < 1 {
            return Err(DomainError::VersionConflict);
        }
        Ok(Self(value))
    }

    pub const fn value(self) -> i64 {
        self.0
    }

    pub fn next(self) -> Result<Self, DomainError> {
        self.0
            .checked_add(1)
            .ok_or(DomainError::VersionConflict)
            .and_then(Self::new)
    }
}
