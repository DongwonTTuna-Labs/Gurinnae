use reqwest::{StatusCode, Url, redirect::Policy};
use sha2::{Digest, Sha256};

use crate::port::{ObjectStoreError, StoredObject};

#[derive(Clone)]
pub struct GatewayObjectStore {
    client: reqwest::Client,
    url: Url,
    caller: &'static str,
}

impl GatewayObjectStore {
    pub fn new(url: Url, caller: &'static str) -> Result<Self, ObjectStoreError> {
        if !matches!(
            caller,
            "submission-api" | "workflow-worker" | "document-extractor" | "ingest-worker"
        ) {
            return Err(ObjectStoreError::InvalidKey);
        }
        let client = reqwest::Client::builder()
            .redirect(Policy::none())
            .timeout(std::time::Duration::from_secs(60))
            .build()
            .map_err(|_| ObjectStoreError::InvalidKey)?;
        Ok(Self {
            client,
            url,
            caller,
        })
    }

    pub async fn put(
        &self,
        key: &str,
        bytes: Vec<u8>,
        expected_sha256: &str,
    ) -> Result<StoredObject, ObjectStoreError> {
        validate_key(key)?;
        if digest(&bytes) != expected_sha256 {
            return Err(ObjectStoreError::DigestMismatch);
        }
        let size = bytes.len();
        let response = self
            .client
            .put(self.url.clone())
            .header("x-gurine-object-key", key)
            .header("x-gurine-object-sha256", expected_sha256)
            .header("x-gurine-egress-caller", self.caller)
            .body(bytes)
            .send()
            .await
            .map_err(backend)?;
        if !response.status().is_success() {
            return Err(backend_status());
        }
        Ok(StoredObject {
            key: key.to_owned(),
            size,
            sha256: expected_sha256.to_owned(),
            etag: response
                .headers()
                .get("etag")
                .and_then(|value| value.to_str().ok())
                .map(str::to_owned),
        })
    }

    pub async fn get(
        &self,
        key: &str,
        expected_sha256: Option<&str>,
    ) -> Result<Vec<u8>, ObjectStoreError> {
        validate_key(key)?;
        let response = self
            .client
            .get(self.url.clone())
            .header("x-gurine-object-key", key)
            .header("x-gurine-egress-caller", self.caller)
            .send()
            .await
            .map_err(backend)?;
        if !response.status().is_success() {
            return Err(backend_status());
        }
        let bytes = response.bytes().await.map_err(backend)?.to_vec();
        if expected_sha256.is_some_and(|expected| digest(&bytes) != expected) {
            return Err(ObjectStoreError::DigestMismatch);
        }
        Ok(bytes)
    }

    pub async fn delete(&self, key: &str) -> Result<(), ObjectStoreError> {
        validate_key(key)?;
        let response = self
            .client
            .delete(self.url.clone())
            .header("x-gurine-object-key", key)
            .header("x-gurine-egress-caller", self.caller)
            .send()
            .await
            .map_err(backend)?;
        if response.status().is_success() || response.status() == StatusCode::NOT_FOUND {
            Ok(())
        } else {
            Err(backend_status())
        }
    }
}

fn validate_key(key: &str) -> Result<(), ObjectStoreError> {
    if key.is_empty()
        || key.starts_with('/')
        || key
            .split('/')
            .any(|segment| segment.is_empty() || segment == "." || segment == "..")
    {
        Err(ObjectStoreError::InvalidKey)
    } else {
        Ok(())
    }
}

fn digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn backend(error: reqwest::Error) -> ObjectStoreError {
    ObjectStoreError::Backend(object_store::Error::Generic {
        store: "egress-gateway",
        source: Box::new(error),
    })
}

fn backend_status() -> ObjectStoreError {
    ObjectStoreError::Backend(object_store::Error::Generic {
        store: "egress-gateway",
        source: Box::new(std::io::Error::other(
            "object-store gateway rejected request",
        )),
    })
}
