#![forbid(unsafe_code)]

pub mod archive;
pub mod config;
pub mod formats;
pub mod handlers;
pub mod health;
pub mod model;
pub mod pdf;
pub mod runner;
pub mod shutdown;
pub mod xml;

use std::path::{Path, PathBuf};

use model::{ExtractionResult, rejected, sha256_hex};

const MAX_INPUT_BYTES: u64 = 104_857_600;
const HWP_OLE_MAGIC: &[u8] = &[0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum DocumentKind {
    Csv,
    Xml,
    Xlsx,
    Docx,
    Hwpx,
    Pdf,
    BinaryHwp,
    Unknown,
}

pub async fn extract_path(path: &Path) -> Result<ExtractionResult, std::io::Error> {
    let metadata = tokio::fs::metadata(path).await?;
    if metadata.len() > MAX_INPUT_BYTES {
        let document_sha256 = sha256_hex(&tokio::fs::read(path).await?);
        return Ok(rejected(
            document_sha256,
            "application/octet-stream",
            "unknown",
            "unknown",
            "SIZE_LIMIT",
        ));
    }
    let bytes = tokio::fs::read(path).await?;
    let kind = detect_kind(path, &bytes);
    match kind {
        DocumentKind::Pdf => {
            let versions = pdf::ToolVersions::detect()
                .await
                .map_err(std::io::Error::other)?;
            Ok(pdf::extract(path, &bytes, &versions).await)
        }
        DocumentKind::BinaryHwp => Ok(rejected(
            sha256_hex(&bytes),
            "application/x-hwp",
            "legacy-hwp",
            "unsupported",
            "BINARY_HWP_UNSUPPORTED_REQUIRES_TRUSTED_CONVERSION",
        )),
        DocumentKind::Unknown => Ok(rejected(
            sha256_hex(&bytes),
            "application/octet-stream",
            "unknown",
            "unknown",
            "UNSUPPORTED_MEDIA_TYPE",
        )),
        blocking_kind => extract_blocking(path.to_path_buf(), bytes, blocking_kind).await,
    }
}

async fn extract_blocking(
    path: PathBuf,
    bytes: Vec<u8>,
    kind: DocumentKind,
) -> Result<ExtractionResult, std::io::Error> {
    tokio::task::spawn_blocking(move || match kind {
        DocumentKind::Csv => formats::csv(&bytes),
        DocumentKind::Xml => formats::xml(&bytes),
        DocumentKind::Xlsx => formats::xlsx(&path, &bytes),
        DocumentKind::Docx => formats::docx(&path, &bytes),
        DocumentKind::Hwpx => formats::hwpx(&path, &bytes),
        _ => rejected(
            sha256_hex(&bytes),
            "application/octet-stream",
            "unknown",
            "unknown",
            "UNSUPPORTED_MEDIA_TYPE",
        ),
    })
    .await
    .map_err(std::io::Error::other)
}

fn detect_kind(path: &Path, bytes: &[u8]) -> DocumentKind {
    if bytes.starts_with(HWP_OLE_MAGIC) {
        return DocumentKind::BinaryHwp;
    }
    if bytes.starts_with(b"%PDF") {
        return DocumentKind::Pdf;
    }
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    if bytes.starts_with(b"PK\x03\x04") {
        return match extension.as_str() {
            "xlsx" => DocumentKind::Xlsx,
            "docx" => DocumentKind::Docx,
            "hwpx" => DocumentKind::Hwpx,
            _ => DocumentKind::Unknown,
        };
    }
    let content = bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(bytes);
    if content
        .iter()
        .copied()
        .find(|byte| !byte.is_ascii_whitespace())
        == Some(b'<')
    {
        return DocumentKind::Xml;
    }
    if extension == "csv" && std::str::from_utf8(content).is_ok() {
        return DocumentKind::Csv;
    }
    if extension == "hwp" {
        return DocumentKind::BinaryHwp;
    }
    DocumentKind::Unknown
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn authority_parser_golden_cases_match_exactly() -> Result<(), Box<dyn std::error::Error>>
    {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../specs/parsers");
        let fixture_directory = root.join("fixtures");
        let expected_directory = root.join("expected");
        let mut fixtures = std::fs::read_dir(&fixture_directory)?
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| path.is_file())
            .collect::<Vec<_>>();
        fixtures.sort();
        assert_eq!(fixtures.len(), 15);
        for fixture in fixtures {
            let file_name = fixture
                .file_name()
                .and_then(|value| value.to_str())
                .ok_or("fixture name")?;
            let expected_path = expected_directory.join(format!("{file_name}.extraction.json"));
            let expected: serde_json::Value =
                serde_json::from_slice(&std::fs::read(expected_path)?)?;
            let actual = serde_json::to_value(extract_path(&fixture).await?)?;
            assert_eq!(actual, expected, "fixture {file_name}");
        }
        Ok(())
    }
}
