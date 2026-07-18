//! Closed, source-bound multimodal extraction API.
//!
//! The format-specific implementations live in private modules so each parser
//! stays auditable and within the source-quality function/file limits.

#[path = "common.rs"]
mod common;
#[path = "html.rs"]
mod html;
#[path = "image.rs"]
mod image;
#[path = "media.rs"]
mod media;

use common::{color_model, media_type, tiff_has_multiple_ifds, webp_is_animated};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use unicode_normalization::UnicodeNormalization;
use uuid::Uuid;

const MAX_INPUT_BYTES: usize = 104_857_600;
pub(super) const MAX_IMAGE_WIDTH: u32 = 30_000;
pub(super) const MAX_IMAGE_HEIGHT: u32 = 30_000;
pub(super) const MAX_IMAGE_PIXELS: u64 = 250_000_000;
pub(super) const MAX_HTML_NODES: usize = 1_000_000;
pub(super) const MAX_HTML_DEPTH: usize = 256;
pub(super) const MAX_AUDIO_CHANNELS: u16 = 8;
pub(super) const MAX_AUDIO_RATE: u32 = 192_000;
pub(super) const MAX_AUDIO_DURATION_MS: u64 = 7_200_000;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AssetBinding {
    pub asset_id: Uuid,
    pub asset_revision: i64,
    pub content_sha256: String,
}

impl AssetBinding {
    fn validate(&self, bytes: &[u8]) -> Result<(), ParseError> {
        if self.asset_revision < 1 || !is_sha256(&self.content_sha256) {
            return Err(ParseError::AssetBindingInvalid);
        }
        if sha256_hex(bytes) != self.content_sha256 {
            return Err(ParseError::ContentDigestMismatch);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum MultimodalStatus {
    Extracted,
    Rejected,
    Failed,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum MediaKind {
    Html,
    Image,
    Audio,
    Video,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "mediaKind", rename_all = "SCREAMING_SNAKE_CASE")]
pub enum MediaMetadata {
    Html {
        #[serde(rename = "documentTitle")]
        document_title: Option<String>,
        #[serde(rename = "language")]
        language: Option<String>,
        #[serde(rename = "nodeCount")]
        node_count: usize,
        #[serde(rename = "activeContentCount")]
        active_content_count: usize,
    },
    Image {
        #[serde(rename = "widthPx")]
        width_px: u32,
        #[serde(rename = "heightPx")]
        height_px: u32,
        #[serde(rename = "frameCount")]
        frame_count: u32,
        #[serde(rename = "colorModel")]
        color_model: String,
        #[serde(rename = "orientationApplied")]
        orientation_applied: String,
    },
    Audio {
        #[serde(rename = "container")]
        container: String,
        #[serde(rename = "codec")]
        codec: String,
        #[serde(rename = "sampleRateHz")]
        sample_rate_hz: u32,
        #[serde(rename = "channelCount")]
        channel_count: u16,
        #[serde(rename = "durationMs")]
        duration_ms: u64,
        #[serde(rename = "silenceState")]
        silence_state: String,
        #[serde(rename = "transcriptState")]
        transcript_state: String,
    },
    Video {
        #[serde(rename = "container")]
        container: String,
        #[serde(rename = "durationMs")]
        duration_ms: u64,
        #[serde(rename = "widthPx")]
        width_px: u32,
        #[serde(rename = "heightPx")]
        height_px: u32,
        #[serde(rename = "frameRateMilliHz")]
        frame_rate_millihz: u32,
        #[serde(rename = "videoCodec")]
        video_codec: String,
        #[serde(rename = "frameCount")]
        frame_count: u64,
        #[serde(rename = "audioStreamState")]
        audio_stream_state: String,
        #[serde(rename = "audioCodec")]
        audio_codec: Option<String>,
        #[serde(rename = "transcriptState")]
        transcript_state: String,
    },
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum LocatorKind {
    HtmlCssSelector,
    ImageBbox,
    AudioTimeRange,
    VideoTimeRange,
    VideoRegionTime,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Locator {
    pub kind: LocatorKind,
    pub value: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtractionSegment {
    pub segment_id: String,
    pub kind: String,
    pub text: String,
    pub normalized_text_sha256: String,
    pub locator: Locator,
    pub confidence_basis_points: Option<u16>,
    pub language: Option<String>,
    pub source_asset_id: Uuid,
    pub source_asset_revision: i64,
    pub source_content_sha256: String,
    pub extraction_version: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtractionShot {
    pub shot_id: String,
    pub locator: Locator,
    pub decoded_frame_count: u64,
    pub representative_frame_sha256: String,
    pub source_asset_id: Uuid,
    pub source_asset_revision: i64,
    pub source_content_sha256: String,
    pub extraction_version: String,
    pub confidence_basis_points: Option<u16>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtractionTable {
    pub table_id: String,
    pub caption: Option<String>,
    pub locator: Locator,
    pub rows: Vec<Vec<String>>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HtmlLink {
    pub text: String,
    pub absolute_url: String,
    pub locator: Locator,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MultimodalExtractionResult {
    pub schema_version: String,
    pub document_sha256: String,
    pub media_type: String,
    pub parser_id: String,
    pub parser_version: String,
    pub status: MultimodalStatus,
    pub metadata: Option<MediaMetadata>,
    pub segments: Vec<ExtractionSegment>,
    pub shots: Vec<ExtractionShot>,
    pub tables: Vec<ExtractionTable>,
    pub links: Vec<HtmlLink>,
    pub warnings: Vec<String>,
    pub rejection_code: Option<String>,
    pub extraction_sha256: String,
}

#[derive(Clone, Debug, Eq, PartialEq, thiserror::Error)]
pub enum ParseError {
    #[error("input exceeds the immutable parser byte limit")]
    SizeLimit,
    #[error("asset binding is invalid")]
    AssetBindingInvalid,
    #[error("source content digest does not match the asset binding")]
    ContentDigestMismatch,
    #[error("unsupported media type")]
    UnsupportedMediaType,
    #[error("malformed multimodal input: {0}")]
    Malformed(String),
}

/// Detects only by bytes/structure. Extension and Content-Type are not used.
pub fn detect_format(bytes: &[u8]) -> Option<&'static str> {
    common::detect_format(bytes)
}

pub fn parse_bytes(
    bytes: &[u8],
    binding: &AssetBinding,
) -> Result<MultimodalExtractionResult, ParseError> {
    if bytes.len() > MAX_INPUT_BYTES {
        return Err(ParseError::SizeLimit);
    }
    binding.validate(bytes)?;
    let format = detect_format(bytes).ok_or(ParseError::UnsupportedMediaType)?;
    let mut result = match format {
        "html" => html::parse_html(bytes, binding)?,
        "png" | "jpeg" | "webp" | "tiff" => image::parse_image(bytes, binding, format)?,
        "wav" => media::parse_wav(bytes, binding)?,
        "webm" => media::parse_webm(bytes, binding)?,
        _ => return Err(ParseError::UnsupportedMediaType),
    };
    result.extraction_sha256 = result_digest(&result)?;
    Ok(result)
}

fn base_result(
    binding: &AssetBinding,
    media_type: &str,
    parser_id: &str,
    parser_version: &str,
) -> MultimodalExtractionResult {
    MultimodalExtractionResult {
        schema_version: "multimodal-extraction-result.v2".to_owned(),
        document_sha256: binding.content_sha256.clone(),
        media_type: media_type.to_owned(),
        parser_id: parser_id.to_owned(),
        parser_version: parser_version.to_owned(),
        status: MultimodalStatus::Extracted,
        metadata: None,
        segments: Vec::new(),
        shots: Vec::new(),
        tables: Vec::new(),
        links: Vec::new(),
        warnings: Vec::new(),
        rejection_code: None,
        extraction_sha256: String::new(),
    }
}

fn rejected(
    binding: &AssetBinding,
    media_type: &str,
    parser_id: &str,
    version: &str,
    code: &str,
) -> MultimodalExtractionResult {
    let mut result = base_result(binding, media_type, parser_id, version);
    result.status = MultimodalStatus::Rejected;
    result.rejection_code = Some(code.to_owned());
    result
}

fn segment(
    binding: &AssetBinding,
    kind: &str,
    text: &str,
    locator: Locator,
    language: Option<String>,
    confidence: Option<u16>,
    version: &str,
) -> ExtractionSegment {
    let normalized = normalize_text(text);
    let material = [
        binding.content_sha256.as_str(),
        format!("{:?}:{}", locator.kind, locator.value).as_str(),
        normalized.as_str(),
    ]
    .join("\0");
    let id_digest = sha256_hex(material.as_bytes());
    ExtractionSegment {
        segment_id: format!("seg-{}", &id_digest[..24]),
        kind: kind.to_owned(),
        text: normalized.clone(),
        normalized_text_sha256: sha256_hex(normalized.as_bytes()),
        locator,
        confidence_basis_points: confidence,
        language,
        source_asset_id: binding.asset_id,
        source_asset_revision: binding.asset_revision,
        source_content_sha256: binding.content_sha256.clone(),
        extraction_version: version.to_owned(),
    }
}

fn stable_id(binding: &AssetBinding, locator: &str, suffix: &str) -> String {
    let digest =
        sha256_hex(format!("{}\0{}\0{}", binding.content_sha256, locator, suffix).as_bytes());
    format!("{suffix}-{}", &digest[..24])
}

fn normalize_text(value: &str) -> String {
    value
        .replace("\r\n", "\n")
        .replace('\r', "\n")
        .nfc()
        .map(|character| {
            if matches!(character, '\t' | '\u{000b}' | '\u{000c}') {
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

fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}
fn is_sha256(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}
fn result_digest(result: &MultimodalExtractionResult) -> Result<String, ParseError> {
    let mut projection = result.clone();
    projection.extraction_sha256.clear();
    serde_json::to_vec(&projection)
        .map(|bytes| sha256_hex(&bytes))
        .map_err(|_| ParseError::Malformed("RESULT_SERIALIZATION".to_owned()))
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
