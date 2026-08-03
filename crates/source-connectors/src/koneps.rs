use crate::ConnectorOperation;

pub const OPERATIONS: &[ConnectorOperation] = &[
    ConnectorOperation {
        connector_id: "koneps-contracts",
        id: "contract-goods-list",
        method: "GET",
        kind: "list",
        remote_path: "/getCntrctInfoListThng",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-contracts",
        id: "contract-goods-detail",
        method: "GET",
        kind: "detail",
        remote_path: "/getCntrctInfoListThngDetail",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-contracts",
        id: "contract-goods-change",
        method: "GET",
        kind: "change",
        remote_path: "/getCntrctInfoListThngChgHstry",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-contracts",
        id: "contract-goods-delete",
        method: "GET",
        kind: "delete",
        remote_path: "/getCntrctInfoListThngDltHstry",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-contracts",
        id: "contract-construction-list",
        method: "GET",
        kind: "list",
        remote_path: "/getCntrctInfoListCnstwk",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-contracts",
        id: "contract-construction-detail",
        method: "GET",
        kind: "detail",
        remote_path: "/getCntrctInfoListCnstwkDetail",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-contracts",
        id: "contract-construction-change",
        method: "GET",
        kind: "change",
        remote_path: "/getCntrctInfoListCnstwkChgHstry",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-contracts",
        id: "contract-construction-delete",
        method: "GET",
        kind: "delete",
        remote_path: "/getCntrctInfoListCnstwkDltHstry",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-contracts",
        id: "contract-service-list",
        method: "GET",
        kind: "list",
        remote_path: "/getCntrctInfoListServc",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-contracts",
        id: "contract-service-detail",
        method: "GET",
        kind: "detail",
        remote_path: "/getCntrctInfoListServcDetail",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-contracts",
        id: "contract-service-change",
        method: "GET",
        kind: "change",
        remote_path: "/getCntrctInfoListServcChgHstry",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-contracts",
        id: "contract-service-delete",
        method: "GET",
        kind: "delete",
        remote_path: "/getCntrctInfoListServcDltHstry",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-contracts",
        id: "contract-foreign-list",
        method: "GET",
        kind: "list",
        remote_path: "/getCntrctInfoListFrgcpt",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-contracts",
        id: "contract-foreign-detail",
        method: "GET",
        kind: "detail",
        remote_path: "/getCntrctInfoListFrgcptDetail",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-contracts",
        id: "contract-foreign-change",
        method: "GET",
        kind: "change",
        remote_path: "/getCntrctInfoListFrgcptChgHstry",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-contracts",
        id: "contract-foreign-delete",
        method: "GET",
        kind: "delete",
        remote_path: "/getCntrctInfoListFrgcptDltHstry",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-notices",
        id: "notice-goods-list",
        method: "GET",
        kind: "list",
        remote_path: "/getBidPblancListInfoThng",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-notices",
        id: "notice-goods-search",
        method: "GET",
        kind: "search",
        remote_path: "/getBidPblancListInfoThngPPSSrch",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-notices",
        id: "notice-goods-change",
        method: "GET",
        kind: "change",
        remote_path: "/getBidPblancListInfoThngChgHstry",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-notices",
        id: "notice-construction-list",
        method: "GET",
        kind: "list",
        remote_path: "/getBidPblancListInfoCnstwk",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-notices",
        id: "notice-construction-search",
        method: "GET",
        kind: "search",
        remote_path: "/getBidPblancListInfoCnstwkPPSSrch",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-notices",
        id: "notice-construction-change",
        method: "GET",
        kind: "change",
        remote_path: "/getBidPblancListInfoCnstwkChgHstry",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-notices",
        id: "notice-service-list",
        method: "GET",
        kind: "list",
        remote_path: "/getBidPblancListInfoServc",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-notices",
        id: "notice-service-search",
        method: "GET",
        kind: "search",
        remote_path: "/getBidPblancListInfoServcPPSSrch",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-notices",
        id: "notice-service-change",
        method: "GET",
        kind: "change",
        remote_path: "/getBidPblancListInfoServcChgHstry",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-notices",
        id: "notice-foreign-list",
        method: "GET",
        kind: "list",
        remote_path: "/getBidPblancListInfoFrgcpt",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-notices",
        id: "notice-foreign-search",
        method: "GET",
        kind: "search",
        remote_path: "/getBidPblancListInfoFrgcptPPSSrch",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-notices",
        id: "notice-foreign-change",
        method: "GET",
        kind: "change",
        remote_path: "/getBidPblancListInfoFrgcptChgHstry",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-notices",
        id: "notice-goods-base-amount",
        method: "GET",
        kind: "base_amount",
        remote_path: "/getBidPblancListInfoThngBsisAmount",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-notices",
        id: "notice-construction-base-amount",
        method: "GET",
        kind: "base_amount",
        remote_path: "/getBidPblancListInfoCnstwkBsisAmount",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-notices",
        id: "notice-service-base-amount",
        method: "GET",
        kind: "base_amount",
        remote_path: "/getBidPblancListInfoServcBsisAmount",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-notices",
        id: "notice-license-restriction",
        method: "GET",
        kind: "restriction",
        remote_path: "/getBidPblancListInfoLicenseLimit",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "koneps-notices",
        id: "notice-region-eligibility",
        method: "GET",
        kind: "eligibility",
        remote_path: "/getBidPblancListInfoPrtcptPsblRgn",
        pagination: "page-number",
    },
];

use hmac::{Hmac, Mac};
use quick_xml::Reader;
use quick_xml::events::Event;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use thiserror::Error;

type HmacSha256 = Hmac<Sha256>;

/// The only fields admitted past the KONEPS connector boundary.  All other
/// provider fields remain in the immutable raw response and are not silently
/// promoted into procurement facts.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct KonepsProcurementRecord {
    #[serde(alias = "bidNtceNo", alias = "cntrctNo")]
    pub external_id: String,
    #[serde(alias = "bidNtceOrd", alias = "revision")]
    pub external_revision: String,
    #[serde(alias = "bidNtceNm", alias = "cntrctNm")]
    pub title: String,
    #[serde(alias = "dminsttNm", alias = "cntrctInsttNm")]
    pub agency_name: String,
    #[serde(default, alias = "cntrctCorpNm", alias = "prtcptContstnNm")]
    pub supplier_name: Option<String>,
    #[serde(default, alias = "bizno", alias = "corpBizno")]
    pub supplier_identifier: Option<String>,
    #[serde(default)]
    pub effective_date: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NormalizedKonepsRecord {
    pub source_operation_id: String,
    pub external_id: String,
    pub external_revision: String,
    pub title: String,
    pub agency_name: String,
    pub supplier_name: Option<String>,
    pub supplier_identifier_hmac: Option<String>,
    pub record_digest: String,
}

#[derive(Debug, Error)]
pub enum KonepsMappingError {
    #[error("invalid JSON record: {0}")]
    Json(#[from] serde_json::Error),
    #[error("invalid XML record: {0}")]
    Xml(String),
    #[error("required KONEPS field is empty")]
    RequiredField,
    #[error("HMAC key must not be empty")]
    EmptyHmacKey,
    #[error("HMAC key is not accepted by the configured digest")]
    InvalidHmacKey,
}

pub fn parse_json_record(
    operation_id: &str,
    bytes: &[u8],
    hmac_key: &[u8],
) -> Result<NormalizedKonepsRecord, KonepsMappingError> {
    let record: KonepsProcurementRecord = serde_json::from_slice(bytes)?;
    normalize(operation_id, record, hmac_key)
}

pub fn parse_xml_record(
    operation_id: &str,
    bytes: &[u8],
    hmac_key: &[u8],
) -> Result<NormalizedKonepsRecord, KonepsMappingError> {
    let mut reader = Reader::from_reader(bytes);
    reader.config_mut().trim_text(true);
    let mut buffer = Vec::new();
    let mut current = None::<String>;
    let mut values = std::collections::BTreeMap::<String, String>::new();
    loop {
        match reader.read_event_into(&mut buffer) {
            Ok(Event::Start(event)) => {
                current = Some(String::from_utf8_lossy(event.name().as_ref()).to_string());
            }
            Ok(Event::Text(text)) => {
                if let Some(key) = current.take() {
                    let value = text
                        .decode()
                        .map_err(|error| KonepsMappingError::Xml(error.to_string()))?;
                    values.insert(key, value.into_owned());
                }
            }
            Ok(Event::Eof) => break,
            Err(error) => return Err(KonepsMappingError::Xml(error.to_string())),
            _ => {}
        }
        buffer.clear();
    }
    let record = KonepsProcurementRecord {
        external_id: first(&values, &["bidNtceNo", "cntrctNo"])?,
        external_revision: first(&values, &["bidNtceOrd", "revision"])?,
        title: first(&values, &["bidNtceNm", "cntrctNm"])?,
        agency_name: first(&values, &["dminsttNm", "cntrctInsttNm"])?,
        supplier_name: optional(&values, &["cntrctCorpNm", "prtcptContstnNm"]),
        supplier_identifier: optional(&values, &["bizno", "corpBizno"]),
        effective_date: optional(&values, &["bidNtceDt", "cntrctDate"]),
    };
    normalize(operation_id, record, hmac_key)
}

fn normalize(
    operation_id: &str,
    record: KonepsProcurementRecord,
    hmac_key: &[u8],
) -> Result<NormalizedKonepsRecord, KonepsMappingError> {
    if hmac_key.is_empty() {
        return Err(KonepsMappingError::EmptyHmacKey);
    }
    let required = [
        &record.external_id,
        &record.external_revision,
        &record.title,
        &record.agency_name,
    ];
    if required.iter().any(|value| value.trim().is_empty()) {
        return Err(KonepsMappingError::RequiredField);
    }
    let supplier_identifier_hmac = record
        .supplier_identifier
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .map(|value| hmac_identifier(hmac_key, value))
        .transpose()?;
    let canonical = format!(
        "{}\u{1f}{}\u{1f}{}\u{1f}{}\u{1f}{}\u{1f}{}\u{1f}{}",
        operation_id,
        record.external_id,
        record.external_revision,
        record.title,
        record.agency_name,
        record.supplier_name.as_deref().unwrap_or(""),
        supplier_identifier_hmac.as_deref().unwrap_or(""),
    );
    let record_digest = hex_digest(canonical.as_bytes());
    Ok(NormalizedKonepsRecord {
        source_operation_id: operation_id.to_owned(),
        external_id: record.external_id,
        external_revision: record.external_revision,
        title: record.title,
        agency_name: record.agency_name,
        supplier_name: record.supplier_name,
        supplier_identifier_hmac,
        record_digest,
    })
}

fn hmac_identifier(key: &[u8], value: &str) -> Result<String, KonepsMappingError> {
    let mut mac =
        HmacSha256::new_from_slice(key).map_err(|_| KonepsMappingError::InvalidHmacKey)?;
    mac.update(value.trim().as_bytes());
    Ok(encode_hex(&mac.finalize().into_bytes()))
}

fn hex_digest(bytes: &[u8]) -> String {
    encode_hex(&Sha256::digest(bytes))
}

fn encode_hex(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(HEX[(byte >> 4) as usize] as char);
        output.push(HEX[(byte & 0x0f) as usize] as char);
    }
    output
}

fn first(
    values: &std::collections::BTreeMap<String, String>,
    keys: &[&str],
) -> Result<String, KonepsMappingError> {
    keys.iter()
        .find_map(|key| values.get(*key).cloned())
        .ok_or(KonepsMappingError::RequiredField)
}

fn optional(values: &std::collections::BTreeMap<String, String>, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| values.get(*key).cloned())
}
