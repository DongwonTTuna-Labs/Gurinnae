use std::{fs, path::Path};

use serde::de::DeserializeOwned;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum FixtureError {
    #[error("fixture path is outside the fixture root")]
    PathTraversal,
    #[error("fixture cannot be read")]
    Read(#[source] std::io::Error),
    #[error("fixture JSON is invalid")]
    Json(#[source] serde_json::Error),
}

pub fn read_json<T: DeserializeOwned>(root: &Path, relative: &str) -> Result<T, FixtureError> {
    if relative.starts_with('/') || relative.split('/').any(|segment| segment == "..") {
        return Err(FixtureError::PathTraversal);
    }
    let bytes = fs::read(root.join(relative)).map_err(FixtureError::Read)?;
    serde_json::from_slice(&bytes).map_err(FixtureError::Json)
}
