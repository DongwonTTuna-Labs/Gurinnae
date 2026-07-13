use thiserror::Error;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PageRequest {
    pub cursor: Option<String>,
    pub limit: u16,
}

impl PageRequest {
    pub fn new(cursor: Option<String>, limit: u16) -> Result<Self, QueryError> {
        if !(1..=200).contains(&limit) || cursor.as_ref().is_some_and(|value| value.len() > 512) {
            return Err(QueryError::InvalidPagination);
        }
        Ok(Self { cursor, limit })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Page<T> {
    pub items: Vec<T>,
    pub next_cursor: Option<String>,
    pub total: Option<u64>,
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum QueryError {
    #[error("pagination parameters are invalid")]
    InvalidPagination,
    #[error("requested projection was not found")]
    NotFound,
}
