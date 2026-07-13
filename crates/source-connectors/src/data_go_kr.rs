use serde::Deserialize;
use serde_json::Value;
use thiserror::Error;

#[derive(Debug, Deserialize)]
pub struct DataGoKrHeader {
    #[serde(rename = "resultCode")]
    pub result_code: String,
    #[serde(rename = "resultMsg")]
    pub result_message: String,
}

#[derive(Debug, Deserialize)]
pub struct DataGoKrBody {
    pub items: Value,
    #[serde(rename = "numOfRows")]
    pub rows_per_page: u32,
    #[serde(rename = "pageNo")]
    pub page_number: u32,
    #[serde(rename = "totalCount")]
    pub total_count: u64,
}

#[derive(Debug, Deserialize)]
pub struct DataGoKrResponse {
    pub header: DataGoKrHeader,
    pub body: DataGoKrBody,
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum DataGoKrError {
    #[error("data.go.kr response envelope is malformed")]
    MalformedEnvelope,
    #[error("data.go.kr rejected the request")]
    UpstreamRejected,
}

pub fn decode(value: Value) -> Result<DataGoKrResponse, DataGoKrError> {
    let response: DataGoKrResponse = value
        .get("response")
        .cloned()
        .ok_or(DataGoKrError::MalformedEnvelope)
        .and_then(|response| {
            serde_json::from_value(response).map_err(|_| DataGoKrError::MalformedEnvelope)
        })?;
    if response.header.result_code != "00" {
        return Err(DataGoKrError::UpstreamRejected);
    }
    Ok(response)
}
