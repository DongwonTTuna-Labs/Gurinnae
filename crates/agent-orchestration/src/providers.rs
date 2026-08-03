use serde_json::Value;
use thiserror::Error;

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum ProviderError {
    #[error("provider is unavailable")]
    Unavailable,
    #[error("provider output is invalid")]
    InvalidOutput,
}

pub trait Provider: Send + Sync {
    fn id(&self) -> &str;
    fn complete(&self, request: &Value) -> Result<Value, ProviderError>;
}

pub struct DeterministicProvider {
    pub provider_id: String,
    pub outcome: Result<Value, ProviderError>,
}

impl Provider for DeterministicProvider {
    fn id(&self) -> &str {
        &self.provider_id
    }
    fn complete(&self, _request: &Value) -> Result<Value, ProviderError> {
        self.outcome.clone()
    }
}

pub fn route<'a>(
    providers: &'a [&dyn Provider],
    request: &Value,
) -> Result<(&'a str, Value), ProviderError> {
    for provider in providers {
        match provider.complete(request) {
            Ok(response) => return Ok((provider.id(), response)),
            Err(ProviderError::Unavailable) => continue,
            Err(error) => return Err(error),
        }
    }
    Err(ProviderError::Unavailable)
}
