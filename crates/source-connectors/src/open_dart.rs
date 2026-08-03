use crate::ConnectorOperation;

pub const OPERATIONS: &[ConnectorOperation] = &[
    ConnectorOperation {
        connector_id: "open-dart",
        id: "dart-corp-code",
        method: "GET",
        kind: "snapshot-zip-xml",
        remote_path: "/corpCode.xml",
        pagination: "none",
    },
    ConnectorOperation {
        connector_id: "open-dart",
        id: "dart-company",
        method: "GET",
        kind: "detail",
        remote_path: "/company.json",
        pagination: "none",
    },
    ConnectorOperation {
        connector_id: "open-dart",
        id: "dart-disclosures",
        method: "GET",
        kind: "list",
        remote_path: "/list.json",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "open-dart",
        id: "dart-financial-statements",
        method: "GET",
        kind: "list",
        remote_path: "/fnlttSinglAcntAll.json",
        pagination: "none",
    },
    ConnectorOperation {
        connector_id: "open-dart",
        id: "dart-executive-status",
        method: "GET",
        kind: "person-context-list",
        remote_path: "/exctvSttus.json",
        pagination: "none",
    },
    ConnectorOperation {
        connector_id: "open-dart",
        id: "dart-major-shareholder-status",
        method: "GET",
        kind: "holder-context-list",
        remote_path: "/hyslrSttus.json",
        pagination: "none",
    },
];

use serde_json::Value;
use sha2::{Digest, Sha256};
use thiserror::Error;

/// Minimal lawful person context admitted from a statutory DART disclosure.
/// Demographic, contact and relationship fields have no normalized member.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OpenDartPersonObservation {
    pub operation_id: String,
    pub receipt_number: String,
    pub corporation_code: String,
    pub corporation_name: String,
    pub contextual_name: String,
    pub role_title: String,
    pub source_locator: String,
    /// Observation-scoped digest. It must never be used to auto-link or verify
    /// a natural person across companies or disclosure rows.
    pub identifier_digest: String,
}

/// A disclosed major-holder observation. DART does not provide an authoritative
/// natural-person discriminator here, so this type cannot become a PERSON node.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OpenDartShareholderObservation {
    pub operation_id: String,
    pub receipt_number: String,
    pub corporation_code: String,
    pub corporation_name: String,
    pub holder_name: String,
    pub source_locator: String,
    pub observation_digest: String,
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum OpenDartPersonError {
    #[error("operation is not a declared OpenDART person-context operation")]
    InvalidOperation,
    #[error("required OpenDART person context is missing")]
    RequiredField,
    #[error("source locator must be an exact JSON pointer")]
    InvalidSourceLocator,
}

pub fn normalize_person_observation(
    operation_id: &str,
    record: &Value,
    source_locator: &str,
) -> Result<OpenDartPersonObservation, OpenDartPersonError> {
    if !source_locator.starts_with('/') || source_locator.contains(char::is_whitespace) {
        return Err(OpenDartPersonError::InvalidSourceLocator);
    }
    let receipt_number = required_text(record, "rcept_no")?;
    let corporation_code = required_text(record, "corp_code")?;
    let corporation_name = required_text(record, "corp_name")?;
    let contextual_name = required_text(record, "nm")?;
    if operation_id != "dart-executive-status" {
        return Err(OpenDartPersonError::InvalidOperation);
    }
    let role_title = required_text(record, "ofcps")?;
    let preimage = [
        operation_id,
        receipt_number,
        corporation_code,
        contextual_name,
        role_title,
        source_locator,
    ]
    .join("\u{1f}");
    Ok(OpenDartPersonObservation {
        operation_id: operation_id.to_owned(),
        receipt_number: receipt_number.to_owned(),
        corporation_code: corporation_code.to_owned(),
        corporation_name: corporation_name.to_owned(),
        contextual_name: contextual_name.to_owned(),
        role_title: role_title.to_owned(),
        source_locator: source_locator.to_owned(),
        identifier_digest: hex(&Sha256::digest(preimage.as_bytes())),
    })
}

pub fn normalize_shareholder_observation(
    operation_id: &str,
    record: &Value,
    source_locator: &str,
) -> Result<OpenDartShareholderObservation, OpenDartPersonError> {
    if operation_id != "dart-major-shareholder-status" {
        return Err(OpenDartPersonError::InvalidOperation);
    }
    if !source_locator.starts_with('/') || source_locator.contains(char::is_whitespace) {
        return Err(OpenDartPersonError::InvalidSourceLocator);
    }
    let receipt_number = required_text(record, "rcept_no")?;
    let corporation_code = required_text(record, "corp_code")?;
    let corporation_name = required_text(record, "corp_name")?;
    let holder_name = required_text(record, "nm")?;
    let preimage = [
        operation_id,
        receipt_number,
        corporation_code,
        holder_name,
        source_locator,
    ]
    .join("\u{1f}");
    Ok(OpenDartShareholderObservation {
        operation_id: operation_id.to_owned(),
        receipt_number: receipt_number.to_owned(),
        corporation_code: corporation_code.to_owned(),
        corporation_name: corporation_name.to_owned(),
        holder_name: holder_name.to_owned(),
        source_locator: source_locator.to_owned(),
        observation_digest: hex(&Sha256::digest(preimage.as_bytes())),
    })
}

fn required_text<'a>(record: &'a Value, field: &str) -> Result<&'a str, OpenDartPersonError> {
    record
        .get(field)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or(OpenDartPersonError::RequiredField)
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
