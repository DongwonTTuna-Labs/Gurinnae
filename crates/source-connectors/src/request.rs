use std::{collections::BTreeMap, time::Duration};

use reqwest::{Client, StatusCode};
use serde_json::Value;
use thiserror::Error;
use url::Url;

use crate::ConnectorOperation;

#[derive(Debug, Error)]
pub enum ConnectorError {
    #[error("egress gateway URL is invalid")]
    InvalidGateway,
    #[error("connector request failed")]
    Transport(#[source] reqwest::Error),
    #[error("connector quota is exhausted")]
    Quota,
    #[error("connector authorization failed")]
    Authorization,
    #[error("upstream dependency is unavailable")]
    Unavailable,
    #[error("upstream payload is malformed")]
    MalformedPayload,
}

pub struct EgressClient {
    base_url: Url,
    client: Client,
}

impl EgressClient {
    pub fn new(base_url: &str) -> Result<Self, ConnectorError> {
        let base_url = Url::parse(base_url).map_err(|_| ConnectorError::InvalidGateway)?;
        if !matches!(base_url.scheme(), "http" | "https") || base_url.host_str().is_none() {
            return Err(ConnectorError::InvalidGateway);
        }
        let client = Client::builder()
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(30))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(ConnectorError::Transport)?;
        Ok(Self { base_url, client })
    }

    pub async fn fetch(
        &self,
        operation: &ConnectorOperation,
        parameters: &BTreeMap<String, String>,
    ) -> Result<Value, ConnectorError> {
        let path = format!("source/{}/{}", operation.connector_id, operation.id);
        let url = self
            .base_url
            .join(&path)
            .map_err(|_| ConnectorError::InvalidGateway)?;
        let response = self
            .client
            .get(url)
            .query(parameters)
            .send()
            .await
            .map_err(ConnectorError::Transport)?;
        match response.status() {
            StatusCode::TOO_MANY_REQUESTS => Err(ConnectorError::Quota),
            StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => Err(ConnectorError::Authorization),
            status if status.is_server_error() => Err(ConnectorError::Unavailable),
            status if !status.is_success() => Err(ConnectorError::MalformedPayload),
            _ => response
                .json()
                .await
                .map_err(|_| ConnectorError::MalformedPayload),
        }
    }
}
