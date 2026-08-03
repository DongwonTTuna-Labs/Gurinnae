use std::time::Duration;

use openidconnect::{HttpRequest, HttpResponse, http};
use reqwest::redirect::Policy;
use thiserror::Error;
use url::Url;

#[derive(Clone)]
pub struct OidcEgressClient {
    client: reqwest::Client,
    gateway_url: Url,
}

#[derive(Debug, Error)]
pub enum OidcEgressError {
    #[error("OIDC egress request could not be built")]
    Request,
    #[error("OIDC egress transport failed")]
    Transport(#[from] reqwest::Error),
    #[error("OIDC egress response could not be built")]
    Response,
}

impl OidcEgressClient {
    pub fn new(gateway_url: Url) -> Result<Self, OidcEgressError> {
        let client = reqwest::Client::builder()
            .redirect(Policy::none())
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(15))
            .build()?;
        Ok(Self {
            client,
            gateway_url,
        })
    }

    async fn send(&self, request: HttpRequest) -> Result<HttpResponse, OidcEgressError> {
        let target = request.uri().to_string();
        let mut outbound = self
            .client
            .request(request.method().clone(), self.gateway_url.clone())
            .header("x-gurine-egress-target", target)
            .header("x-gurine-egress-caller", "identity-api");
        for (name, value) in request.headers() {
            if name != http::header::HOST && name != http::header::CONTENT_LENGTH {
                outbound = outbound.header(name, value);
            }
        }
        let response = outbound.body(request.into_body()).send().await?;
        let status = response.status();
        let headers = response.headers().clone();
        let body = response.bytes().await?.to_vec();
        let mut builder = http::Response::builder().status(status);
        for (name, value) in &headers {
            builder = builder.header(name, value);
        }
        builder.body(body).map_err(|_| OidcEgressError::Response)
    }
}

impl<'client> openidconnect::AsyncHttpClient<'client> for OidcEgressClient {
    type Error = OidcEgressError;
    type Future =
        std::pin::Pin<Box<dyn Future<Output = Result<HttpResponse, Self::Error>> + Send + 'client>>;

    fn call(&'client self, request: HttpRequest) -> Self::Future {
        Box::pin(self.send(request))
    }
}
