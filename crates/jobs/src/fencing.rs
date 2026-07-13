use thiserror::Error;
use uuid::Uuid;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Fence {
    pub lease_token: Uuid,
    pub fencing_token: i64,
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum FenceError {
    #[error("job lease token or fencing token is stale")]
    StaleFence,
}

pub fn verify(expected: Fence, candidate: Fence) -> Result<(), FenceError> {
    if expected != candidate || candidate.fencing_token < 1 {
        return Err(FenceError::StaleFence);
    }
    Ok(())
}
