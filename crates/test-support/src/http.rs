use std::collections::BTreeMap;

use serde::Serialize;
use serde_json::Value;
use uuid::Uuid;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TestRequest {
    pub method: String,
    pub path: String,
    pub headers: BTreeMap<String, String>,
    pub body: Vec<u8>,
}

impl TestRequest {
    pub fn json(
        method: &str,
        path: &str,
        body: &impl Serialize,
    ) -> Result<Self, serde_json::Error> {
        let mut headers = BTreeMap::new();
        headers.insert("content-type".to_owned(), "application/json".to_owned());
        headers.insert("x-request-id".to_owned(), Uuid::new_v4().to_string());
        Ok(Self {
            method: method.to_owned(),
            path: path.to_owned(),
            headers,
            body: serde_json::to_vec(body)?,
        })
    }

    pub fn body_json(&self) -> Result<Value, serde_json::Error> {
        serde_json::from_slice(&self.body)
    }
}
