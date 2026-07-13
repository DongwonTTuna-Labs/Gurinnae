use std::{path::Path, sync::Arc};

use object_store::local::LocalFileSystem;

use crate::port::{ObjectStoreClient, ObjectStoreError};

pub fn open(root: &Path) -> Result<ObjectStoreClient, ObjectStoreError> {
    let store = LocalFileSystem::new_with_prefix(root).map_err(ObjectStoreError::Backend)?;
    Ok(ObjectStoreClient::new(Arc::new(store)))
}
