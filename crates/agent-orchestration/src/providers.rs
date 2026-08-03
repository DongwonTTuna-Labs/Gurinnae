use serde_json::Value;
use thiserror::Error;

#[derive(Debug, Error)]
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
    pub response: Value,
}

impl Provider for DeterministicProvider {
    fn id(&self) -> &str {
        "deterministic"
    }
    fn complete(&self, _request: &Value) -> Result<Value, ProviderError> {
        Ok(self.response.clone())
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
