use std::collections::BTreeMap;

use thiserror::Error;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FetchRequest {
    pub operation_id: String,
    pub cursor: Option<String>,
    pub parameters: BTreeMap<String, String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FetchResponse {
    pub status: u16,
    pub content_type: String,
    pub body: Vec<u8>,
    pub next_cursor: Option<String>,
    pub etag: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum FetchError {
    #[error("source response exceeds the configured byte limit")]
    SizeLimit,
    #[error("source response media type is not allowed")]
    MediaTypeDenied,
    #[error("source rate limited the request")]
    RateLimited,
    #[error("source returned a retryable error")]
    Retryable,
    #[error("source returned a terminal error")]
    Terminal,
}

impl FetchResponse {
    pub fn validate(
        &self,
        maximum_bytes: usize,
        allowed_media_types: &[&str],
    ) -> Result<(), FetchError> {
        if self.body.len() > maximum_bytes {
            return Err(FetchError::SizeLimit);
        }
        if !allowed_media_types.contains(&self.content_type.as_str()) {
            return Err(FetchError::MediaTypeDenied);
        }
        match self.status {
            200..=299 => Ok(()),
            429 => Err(FetchError::RateLimited),
            500..=599 => Err(FetchError::Retryable),
            _ => Err(FetchError::Terminal),
        }
    }
}
