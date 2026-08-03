use std::sync::Arc;

use object_store::aws::AmazonS3Builder;

use crate::port::{ObjectStoreClient, ObjectStoreError};

pub struct S3Config<'a> {
    pub bucket: &'a str,
    pub region: &'a str,
    pub endpoint: Option<&'a str>,
    pub access_key_id: &'a str,
    pub secret_access_key: &'a str,
    pub allow_http: bool,
}

pub fn open(config: S3Config<'_>) -> Result<ObjectStoreClient, ObjectStoreError> {
    let mut builder = AmazonS3Builder::new()
        .with_bucket_name(config.bucket)
        .with_region(config.region)
        .with_access_key_id(config.access_key_id)
        .with_secret_access_key(config.secret_access_key)
        .with_allow_http(config.allow_http);
    if let Some(endpoint) = config.endpoint {
        builder = builder.with_endpoint(endpoint);
    }
    let store = builder.build().map_err(ObjectStoreError::Backend)?;
    Ok(ObjectStoreClient::new(Arc::new(store)))
}
