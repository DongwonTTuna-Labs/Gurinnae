use std::sync::Arc;

use object_store::{ObjectStore, ObjectStoreExt, PutPayload, path::Path};
use sha2::{Digest, Sha256};
use thiserror::Error;

#[derive(Clone)]
pub struct ObjectStoreClient {
    inner: Arc<dyn ObjectStore>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredObject {
    pub key: String,
    pub size: usize,
    pub sha256: String,
    pub etag: Option<String>,
}

#[derive(Debug, Error)]
pub enum ObjectStoreError {
    #[error("object key is invalid")]
    InvalidKey,
    #[error("object store operation failed")]
    Backend(#[source] object_store::Error),
    #[error("object content digest does not match")]
    DigestMismatch,
}

impl ObjectStoreClient {
    pub fn new(inner: Arc<dyn ObjectStore>) -> Self {
        Self { inner }
    }

    pub async fn put(
        &self,
        key: &str,
        bytes: Vec<u8>,
        expected_sha256: &str,
    ) -> Result<StoredObject, ObjectStoreError> {
        let location = location(key)?;
        let sha256 = digest(&bytes);
        if sha256 != expected_sha256 {
            return Err(ObjectStoreError::DigestMismatch);
        }
        let size = bytes.len();
        let result = self
            .inner
            .put(&location, PutPayload::from(bytes))
            .await
            .map_err(ObjectStoreError::Backend)?;
        Ok(StoredObject {
            key: key.to_owned(),
            size,
            sha256,
            etag: result.e_tag,
        })
    }

    pub async fn get(
        &self,
        key: &str,
        expected_sha256: Option<&str>,
    ) -> Result<Vec<u8>, ObjectStoreError> {
        let bytes = self
            .inner
            .get(&location(key)?)
            .await
            .map_err(ObjectStoreError::Backend)?
            .bytes()
            .await
            .map_err(ObjectStoreError::Backend)?
            .to_vec();
        if expected_sha256.is_some_and(|expected| digest(&bytes) != expected) {
            return Err(ObjectStoreError::DigestMismatch);
        }
        Ok(bytes)
    }

    pub async fn delete(&self, key: &str) -> Result<(), ObjectStoreError> {
        self.inner
            .delete(&location(key)?)
            .await
            .map_err(ObjectStoreError::Backend)
    }

    pub async fn move_object(
        &self,
        source: &str,
        destination: &str,
    ) -> Result<(), ObjectStoreError> {
        let source = location(source)?;
        let destination = location(destination)?;
        self.inner
            .copy(&source, &destination)
            .await
            .map_err(ObjectStoreError::Backend)?;
        self.inner
            .delete(&source)
            .await
            .map_err(ObjectStoreError::Backend)
    }
}

fn location(key: &str) -> Result<Path, ObjectStoreError> {
    if key.is_empty()
        || key.starts_with('/')
        || key
            .split('/')
            .any(|segment| segment.is_empty() || segment == "." || segment == "..")
    {
        return Err(ObjectStoreError::InvalidKey);
    }
    Path::parse(key).map_err(|_| ObjectStoreError::InvalidKey)
}

fn digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}
