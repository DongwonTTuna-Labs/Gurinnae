use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
pub struct Confidence(u16);

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum ConfidenceError {
    #[error("confidence basis points must be between 0 and 10000")]
    OutOfRange,
}

impl Confidence {
    pub const ZERO: Self = Self(0);
    pub const CERTAIN: Self = Self(10_000);

    pub fn from_basis_points(value: u16) -> Result<Self, ConfidenceError> {
        if value > 10_000 {
            return Err(ConfidenceError::OutOfRange);
        }
        Ok(Self(value))
    }

    pub const fn basis_points(self) -> u16 {
        self.0
    }

    pub fn combine(self, other: Self) -> Self {
        let combined =
            10_000_u32 - ((10_000 - u32::from(self.0)) * (10_000 - u32::from(other.0)) / 10_000);
        Self(combined as u16)
    }
}
