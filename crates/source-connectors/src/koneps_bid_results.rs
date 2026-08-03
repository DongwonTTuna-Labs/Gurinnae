use crate::ConnectorOperation;

pub const OPERATIONS: &[ConnectorOperation] = &[
    ConnectorOperation {
        connector_id: "koneps-bid-results",
        id: "opening-goods-search",
        method: "GET",
        kind: "opening-metadata",
        remote_path: "/getOpengResultListInfoThngPPSSrch",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-bid-results",
        id: "opening-construction-search",
        method: "GET",
        kind: "opening-metadata",
        remote_path: "/getOpengResultListInfoCnstwkPPSSrch",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-bid-results",
        id: "opening-service-search",
        method: "GET",
        kind: "opening-metadata",
        remote_path: "/getOpengResultListInfoServcPPSSrch",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-bid-results",
        id: "opening-foreign-search",
        method: "GET",
        kind: "opening-metadata",
        remote_path: "/getOpengResultListInfoFrgcptPPSSrch",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-bid-results",
        id: "award-goods-search",
        method: "GET",
        kind: "award-metadata",
        remote_path: "/getScsbidListSttusThngPPSSrch",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-bid-results",
        id: "award-construction-search",
        method: "GET",
        kind: "award-metadata",
        remote_path: "/getScsbidListSttusCnstwkPPSSrch",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-bid-results",
        id: "award-service-search",
        method: "GET",
        kind: "award-metadata",
        remote_path: "/getScsbidListSttusServcPPSSrch",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-bid-results",
        id: "award-foreign-search",
        method: "GET",
        kind: "award-metadata",
        remote_path: "/getScsbidListSttusFrgcptPPSSrch",
        pagination: "page-number",
    },
];

use hmac::{Hmac, Mac};
use serde_json::Value;
use sha2::{Digest, Sha256};
use thiserror::Error;

type HmacSha256 = Hmac<Sha256>;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum KonepsBidResultKind {
    Opening,
    Award,
}

/// Closed metadata projection for the official bid-result service.
/// `opengCorpInfo` and person/contact fields deliberately have no member here.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct KonepsBidResultMetadata {
    pub operation_id: String,
    pub kind: KonepsBidResultKind,
    pub notice_number: String,
    pub notice_order: String,
    pub classification_number: Option<String>,
    pub rebid_number: Option<String>,
    pub title: Option<String>,
    pub agency_identifier: Option<String>,
    pub agency_name: Option<String>,
    pub participant_count: Option<u32>,
    pub observed_at: Option<String>,
    pub winner_name: Option<String>,
    pub winner_business_number_hmac: Option<String>,
    pub awarded_amount: Option<String>,
    pub awarded_rate: Option<String>,
    pub record_digest: String,
}

#[derive(Debug, Error, Eq, PartialEq)]
pub enum KonepsBidResultError {
    #[error("operation is not a declared KONEPS bid-result metadata operation")]
    InvalidOperation,
    #[error("required KONEPS bid-result identity is missing")]
    RequiredField,
    #[error("KONEPS participant count is not an unsigned integer")]
    InvalidParticipantCount,
    #[error("HMAC key must be configured before normalizing a winner business number")]
    EmptyHmacKey,
    #[error("HMAC key is not accepted by the configured digest")]
    InvalidHmacKey,
}

pub fn normalize_metadata(
    operation_id: &str,
    record: &Value,
    hmac_key: &[u8],
) -> Result<KonepsBidResultMetadata, KonepsBidResultError> {
    let kind = operation_kind(operation_id)?;
    let notice_number = required_text(record, "bidNtceNo")?.to_owned();
    let notice_order = required_text(record, "bidNtceOrd")?.to_owned();
    let participant_count = optional_text(record, "prtcptCnum")
        .map(|value| {
            value
                .parse::<u32>()
                .map_err(|_| KonepsBidResultError::InvalidParticipantCount)
        })
        .transpose()?;
    let winner_business_number_hmac = optional_text(record, "bidwinnrBizno")
        .map(|value| hmac_identifier(hmac_key, value))
        .transpose()?;
    let metadata = KonepsBidResultMetadata {
        operation_id: operation_id.to_owned(),
        kind,
        notice_number,
        notice_order,
        classification_number: optional_owned(record, "bidClsfcNo"),
        rebid_number: optional_owned(record, "rbidNo"),
        title: optional_owned(record, "bidNtceNm"),
        agency_identifier: first_owned(record, &["ntceInsttCd", "dminsttCd"]),
        agency_name: first_owned(record, &["ntceInsttNm", "dminsttNm"]),
        participant_count,
        observed_at: observation_time(kind, record),
        winner_name: optional_owned(record, "bidwinnrNm"),
        winner_business_number_hmac,
        awarded_amount: optional_owned(record, "sucsfbidAmt"),
        awarded_rate: optional_owned(record, "sucsfbidRate"),
        record_digest: String::new(),
    };
    let record_digest = normalized_digest(&metadata);
    Ok(KonepsBidResultMetadata {
        record_digest,
        ..metadata
    })
}

fn operation_kind(operation_id: &str) -> Result<KonepsBidResultKind, KonepsBidResultError> {
    let operation = OPERATIONS
        .iter()
        .find(|operation| operation.id == operation_id)
        .ok_or(KonepsBidResultError::InvalidOperation)?;
    match operation.kind {
        "opening-metadata" => Ok(KonepsBidResultKind::Opening),
        "award-metadata" => Ok(KonepsBidResultKind::Award),
        _ => Err(KonepsBidResultError::InvalidOperation),
    }
}

fn observation_time(kind: KonepsBidResultKind, record: &Value) -> Option<String> {
    let fields = match kind {
        KonepsBidResultKind::Opening => &["opengDt", "inptDt"][..],
        KonepsBidResultKind::Award => &["fnlSucsfDate", "rlOpengDt", "rgstDt"][..],
    };
    first_owned(record, fields)
}

fn required_text<'a>(record: &'a Value, field: &str) -> Result<&'a str, KonepsBidResultError> {
    optional_text(record, field).ok_or(KonepsBidResultError::RequiredField)
}

fn optional_text<'a>(record: &'a Value, field: &str) -> Option<&'a str> {
    record
        .get(field)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
}

fn optional_owned(record: &Value, field: &str) -> Option<String> {
    optional_text(record, field).map(str::to_owned)
}

fn first_owned(record: &Value, fields: &[&str]) -> Option<String> {
    fields
        .iter()
        .find_map(|field| optional_owned(record, field))
}

fn hmac_identifier(key: &[u8], value: &str) -> Result<String, KonepsBidResultError> {
    if key.is_empty() {
        return Err(KonepsBidResultError::EmptyHmacKey);
    }
    let mut mac =
        HmacSha256::new_from_slice(key).map_err(|_| KonepsBidResultError::InvalidHmacKey)?;
    mac.update(value.as_bytes());
    Ok(hex(&mac.finalize().into_bytes()))
}

fn normalized_digest(metadata: &KonepsBidResultMetadata) -> String {
    let kind = match metadata.kind {
        KonepsBidResultKind::Opening => "OPENING",
        KonepsBidResultKind::Award => "AWARD",
    };
    let fields = [
        metadata.operation_id.as_str(),
        kind,
        metadata.notice_number.as_str(),
        metadata.notice_order.as_str(),
        metadata.classification_number.as_deref().unwrap_or(""),
        metadata.rebid_number.as_deref().unwrap_or(""),
        metadata.title.as_deref().unwrap_or(""),
        metadata.agency_identifier.as_deref().unwrap_or(""),
        metadata.agency_name.as_deref().unwrap_or(""),
        metadata.observed_at.as_deref().unwrap_or(""),
        metadata.winner_name.as_deref().unwrap_or(""),
        metadata
            .winner_business_number_hmac
            .as_deref()
            .unwrap_or(""),
        metadata.awarded_amount.as_deref().unwrap_or(""),
        metadata.awarded_rate.as_deref().unwrap_or(""),
    ];
    let mut preimage = fields.join("\u{1f}");
    preimage.push('\u{1f}');
    preimage.push_str(
        &metadata
            .participant_count
            .map_or_else(String::new, |value| value.to_string()),
    );
    hex(&Sha256::digest(preimage.as_bytes()))
}

fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(DIGITS[(byte >> 4) as usize] as char);
        output.push(DIGITS[(byte & 0x0f) as usize] as char);
    }
    output
}
