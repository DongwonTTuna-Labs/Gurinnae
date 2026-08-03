use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use unicode_normalization::UnicodeNormalization;

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtractionResult {
    pub document_sha256: String,
    pub media_type: String,
    pub parser_id: String,
    pub parser_version: String,
    pub status: ExtractionStatus,
    pub pages: Vec<Page>,
    pub warnings: Vec<String>,
    pub rejection_code: Option<String>,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ExtractionStatus {
    Extracted,
    OcrRequired,
    Rejected,
    Failed,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Page {
    pub index: usize,
    pub width: Option<f64>,
    pub height: Option<f64>,
    pub blocks: Vec<Block>,
    pub tables: Vec<Table>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Block {
    pub id: String,
    pub kind: BlockKind,
    pub text: String,
    pub locator: Locator,
    pub confidence: Option<f64>,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum BlockKind {
    Paragraph,
    Heading,
    OcrText,
    CellText,
    Other,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Table {
    pub id: String,
    pub locator: Locator,
    pub rows: Vec<Vec<Cell>>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Cell {
    pub text: String,
    pub row: usize,
    pub column: usize,
    pub locator: Locator,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Locator {
    pub kind: LocatorKind,
    pub value: String,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum LocatorKind {
    PageBbox,
    XlsxCell,
    CsvRowColumn,
    XmlXpath,
    DocxParagraph,
    HwpxXpath,
}

pub fn normalize_text(value: &str) -> String {
    value
        .replace("\r\n", "\n")
        .replace('\r', "\n")
        .nfc()
        .map(|character| {
            if matches!(character, '\t' | '\u{000c}' | '\u{000b}') {
                ' '
            } else {
                character
            }
        })
        .collect::<String>()
        .lines()
        .map(|line| line.split_whitespace().collect::<Vec<_>>().join(" "))
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

pub fn stable_id(
    prefix: &str,
    document_sha256: &str,
    locator_kind: &str,
    locator_value: &str,
    text: &str,
) -> String {
    let normalized = normalize_text(text);
    let material = [
        document_sha256,
        locator_kind,
        locator_value,
        normalized.as_str(),
    ]
    .join("\0");
    let digest = sha256_hex(material.as_bytes());
    format!("{prefix}-{}", &digest[..20])
}

pub fn rejected(
    document_sha256: String,
    media_type: &str,
    parser_id: &str,
    parser_version: &str,
    code: &str,
) -> ExtractionResult {
    ExtractionResult {
        document_sha256,
        media_type: media_type.to_owned(),
        parser_id: parser_id.to_owned(),
        parser_version: parser_version.to_owned(),
        status: ExtractionStatus::Rejected,
        pages: Vec::new(),
        warnings: Vec::new(),
        rejection_code: Some(code.to_owned()),
    }
}

pub fn locator(kind: LocatorKind, value: impl Into<String>) -> Locator {
    Locator {
        kind,
        value: value.into(),
    }
}
