use std::path::Path;

use gurine_object_store::{filesystem, port::ObjectStoreClient};
use reqwest::Url;
use thiserror::Error;

#[derive(Clone)]
pub enum AttachmentStore {
    Filesystem(ObjectStoreClient),
    Egress { client: reqwest::Client, url: Url },
}

#[derive(Debug, Error)]
pub enum AttachmentStoreError {
    #[error("attachment store configuration is invalid")]
    InvalidConfiguration,
    #[error("attachment store operation failed")]
    Operation,
}

pub struct StoredUpload {
    pub etag: Option<String>,
}

impl AttachmentStore {
    pub async fn filesystem(root: &Path) -> Result<Self, AttachmentStoreError> {
        tokio::fs::create_dir_all(root)
            .await
            .map_err(|_| AttachmentStoreError::InvalidConfiguration)?;
        filesystem::open(root)
            .map(Self::Filesystem)
            .map_err(|_| AttachmentStoreError::InvalidConfiguration)
    }

    pub fn egress(url: Url) -> Result<Self, AttachmentStoreError> {
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(std::time::Duration::from_secs(60))
            .build()
            .map_err(|_| AttachmentStoreError::InvalidConfiguration)?;
        Ok(Self::Egress { client, url })
    }

    pub async fn put(
        &self,
        key: &str,
        bytes: Vec<u8>,
        sha256: &str,
    ) -> Result<StoredUpload, AttachmentStoreError> {
        match self {
            Self::Filesystem(store) => store
                .put(key, bytes, sha256)
                .await
                .map(|stored| StoredUpload { etag: stored.etag })
                .map_err(|_| AttachmentStoreError::Operation),
            Self::Egress { client, url } => {
                let response = client
                    .put(url.clone())
                    .header("x-gurine-object-key", key)
                    .header("x-gurine-object-sha256", sha256)
                    .header("x-gurine-egress-caller", "submission-api")
                    .body(bytes)
                    .send()
                    .await
                    .map_err(|_| AttachmentStoreError::Operation)?;
                if !response.status().is_success() {
                    return Err(AttachmentStoreError::Operation);
                }
                Ok(StoredUpload {
                    etag: response
                        .headers()
                        .get("etag")
                        .and_then(|value| value.to_str().ok())
                        .map(str::to_owned),
                })
            }
        }
    }

    pub async fn delete(&self, key: &str) -> Result<(), AttachmentStoreError> {
        match self {
            Self::Filesystem(store) => store
                .delete(key)
                .await
                .map_err(|_| AttachmentStoreError::Operation),
            Self::Egress { client, url } => {
                let response = client
                    .delete(url.clone())
                    .header("x-gurine-object-key", key)
                    .header("x-gurine-egress-caller", "submission-api")
                    .send()
                    .await
                    .map_err(|_| AttachmentStoreError::Operation)?;
                if response.status().is_success()
                    || response.status() == reqwest::StatusCode::NOT_FOUND
                {
                    Ok(())
                } else {
                    Err(AttachmentStoreError::Operation)
                }
            }
        }
    }
}
