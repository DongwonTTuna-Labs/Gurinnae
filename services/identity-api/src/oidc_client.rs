use openidconnect::{IssuerUrl, core::CoreProviderMetadata};
use thiserror::Error;

use crate::{config::Config, oidc_egress::OidcEgressClient};

#[derive(Debug, Error)]
pub enum OidcClientError {
    #[error("OIDC egress client initialization failed")]
    Egress,
    #[error("OIDC issuer URL is invalid")]
    Issuer,
    #[error("OIDC discovery failed")]
    Discovery,
}

pub async fn discover(
    config: &Config,
) -> Result<(CoreProviderMetadata, OidcEgressClient), OidcClientError> {
    let http = OidcEgressClient::new(config.oidc_egress_url.clone())
        .map_err(|_| OidcClientError::Egress)?;
    let issuer =
        IssuerUrl::new(config.oidc_issuer_url.clone()).map_err(|_| OidcClientError::Issuer)?;
    let provider = CoreProviderMetadata::discover_async(issuer, &http)
        .await
        .map_err(|_| OidcClientError::Discovery)?;
    Ok((provider, http))
}
