use std::{
    collections::BTreeMap,
    io::Write,
    process::{Command, Stdio},
};

use image::{DynamicImage, GenericImageView, ImageFormat, ImageReader, Limits};

use super::common::{bounded_stdout, command_in_process_group, terminate_process_group};
use super::{
    AssetBinding, Locator, LocatorKind, MAX_IMAGE_HEIGHT, MAX_IMAGE_PIXELS, MAX_IMAGE_WIDTH,
    MediaMetadata, MultimodalExtractionResult, ParseError, base_result, color_model, media_type,
    normalize_text, rejected, segment, tiff_has_multiple_ifds, webp_is_animated,
};

pub(super) fn parse_image(
    bytes: &[u8],
    binding: &AssetBinding,
    format: &str,
) -> Result<MultimodalExtractionResult, ParseError> {
    if let Some(result) = reject_unsupported_format(bytes, binding, format) {
        return Ok(result);
    }
    let image_format = match format {
        "png" => ImageFormat::Png,
        "jpeg" => ImageFormat::Jpeg,
        "webp" => ImageFormat::WebP,
        "tiff" => ImageFormat::Tiff,
        _ => return Err(ParseError::UnsupportedMediaType),
    };
    let mut reader = ImageReader::with_format(std::io::Cursor::new(bytes), image_format);
    let mut limits = Limits::default();
    limits.max_image_width = Some(MAX_IMAGE_WIDTH);
    limits.max_image_height = Some(MAX_IMAGE_HEIGHT);
    limits.max_alloc = Some(1_000_000_000);
    reader.limits(limits);
    let image = match reader.decode() {
        Ok(image) => image,
        Err(error) if format!("{error:?}").contains("Limits") => {
            return Ok(rejected(
                binding,
                media_type(format),
                "image-ocr",
                "image-0.25.10+tesseract-5.5.0-kor+eng+gurinnae-image-v1",
                "IMAGE_DIMENSION_LIMIT",
            ));
        }
        Err(_) => {
            return Ok(rejected(
                binding,
                media_type(format),
                "image-ocr",
                "image-0.25.10+tesseract-5.5.0-kor+eng+gurinnae-image-v1",
                "MALFORMED_IMAGE",
            ));
        }
    };
    let (width, height) = image.dimensions();
    if width == 0 || height == 0 || width > MAX_IMAGE_WIDTH || height > MAX_IMAGE_HEIGHT {
        return Ok(rejected(
            binding,
            media_type(format),
            "image-ocr",
            "image-0.25.10+tesseract-5.5.0-kor+eng+gurinnae-image-v1",
            "IMAGE_DIMENSION_LIMIT",
        ));
    }
    if u64::from(width).saturating_mul(u64::from(height)) > MAX_IMAGE_PIXELS {
        return Ok(rejected(
            binding,
            media_type(format),
            "image-ocr",
            "image-0.25.10+tesseract-5.5.0-kor+eng+gurinnae-image-v1",
            "IMAGE_PIXEL_LIMIT",
        ));
    }
    let version = "image-0.25.10+tesseract-5.5.0-kor+eng+gurinnae-image-v1";
    let mut result = base_result(binding, media_type(format), "image-ocr", version);
    result.metadata = Some(MediaMetadata::Image {
        width_px: width,
        height_px: height,
        frame_count: 1,
        color_model: color_model(&image),
        orientation_applied: "NONE".to_owned(),
    });
    append_ocr_segments(&mut result, binding, &image, version);
    Ok(result)
}

fn reject_unsupported_format(
    bytes: &[u8],
    binding: &AssetBinding,
    format: &str,
) -> Option<MultimodalExtractionResult> {
    let code = if format == "webp" && webp_is_animated(bytes) {
        Some("ACTIVE_IMAGE_UNSUPPORTED")
    } else if format == "tiff" && tiff_has_multiple_ifds(bytes) {
        Some("MULTIPAGE_TIFF_UNSUPPORTED")
    } else {
        None
    }?;
    Some(rejected(
        binding,
        media_type(format),
        "image-ocr",
        IMAGE_VERSION,
        code,
    ))
}

const IMAGE_VERSION: &str = "image-0.25.10+tesseract-5.5.0-kor+eng+gurinnae-image-v1";

fn append_ocr_segments(
    result: &mut MultimodalExtractionResult,
    binding: &AssetBinding,
    image: &DynamicImage,
    version: &str,
) {
    match tesseract_ocr(image) {
        Ok(ocr) => {
            result.segments.extend(ocr.lines.into_iter().map(|line| {
                segment(
                    binding,
                    "OCR_LINE",
                    &line.text,
                    Locator {
                        kind: LocatorKind::ImageBbox,
                        value: line.locator,
                    },
                    Some("en".to_owned()),
                    line.confidence,
                    version,
                )
            }));
            result.segments.extend(ocr.words.into_iter().map(|word| {
                segment(
                    binding,
                    "OCR_WORD",
                    &word.text,
                    Locator {
                        kind: LocatorKind::ImageBbox,
                        value: word.locator,
                    },
                    Some("en".to_owned()),
                    word.confidence,
                    version,
                )
            }));
        }
        Err(code) => {
            result.status = super::MultimodalStatus::Rejected;
            result.rejection_code = Some(code);
        }
    }
}

pub(super) struct OcrLine {
    pub(super) text: String,
    pub(super) locator: String,
    pub(super) confidence: Option<u16>,
}
pub(super) struct OcrWord {
    pub(super) text: String,
    pub(super) locator: String,
    pub(super) confidence: Option<u16>,
}
pub(super) struct OcrOutput {
    pub(super) lines: Vec<OcrLine>,
    pub(super) words: Vec<OcrWord>,
}

pub(super) fn tesseract_ocr(image: &DynamicImage) -> Result<OcrOutput, String> {
    let text = run_ocr_process(image)?;
    parse_ocr_tsv(&text)
}

fn run_ocr_process(image: &DynamicImage) -> Result<String, String> {
    let configured = match std::env::var("GURINNAE_TESSERACT_PATH") {
        Ok(value) => value,
        Err(_) => "/opt/gurinnae/bin/tesseract".to_owned(),
    };
    let executable = configured.as_str();
    if !std::path::Path::new(executable).is_absolute() {
        return Err("OCR_RUNTIME_FAILURE".to_owned());
    }
    if !std::path::Path::new(executable).is_file() {
        return Err("OCR_NOT_ACTIVATED".to_owned());
    }
    let mut command = Command::new(executable);
    command.args(["stdin", "stdout", "-l", "kor+eng", "--psm", "6", "tsv"]);
    let mut child = command_in_process_group(&mut command)
        .env_clear()
        .env("LC_ALL", "C")
        .env("TZ", "UTC")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "OCR_RUNTIME_FAILURE".to_owned())?;
    let mut png = Vec::new();
    image
        .write_to(&mut std::io::Cursor::new(&mut png), ImageFormat::Png)
        .map_err(|_| "OCR_RUNTIME_FAILURE".to_owned())?;
    if let Some(mut stdin) = child.stdin.take()
        && stdin.write_all(&png).is_err()
    {
        terminate_process_group(&mut child);
        return Err("OCR_RUNTIME_FAILURE".to_owned());
    }
    let (status, output) =
        bounded_stdout(&mut child, 16_777_216, std::time::Duration::from_secs(120))
            .map_err(|_| "OCR_RUNTIME_FAILURE".to_owned())?;
    if !status.success() {
        return Err("OCR_RUNTIME_FAILURE".to_owned());
    }
    Ok(String::from_utf8_lossy(&output).into_owned())
}

fn parse_ocr_tsv(text: &str) -> Result<OcrOutput, String> {
    let (words, line_groups) = collect_ocr_rows(text);
    let mut lines = Vec::new();
    for words_in_line in line_groups.into_values() {
        let Some(first) = words_in_line.first() else {
            continue;
        };
        let (mut min_x, mut min_y, mut max_x, mut max_y) = (
            first.1,
            first.2,
            first.1.saturating_add(first.3),
            first.2.saturating_add(first.4),
        );
        let mut confidence_sum = 0_u64;
        let mut confidence_count = 0_u64;
        let text = words_in_line
            .iter()
            .map(|word| {
                min_x = min_x.min(word.1);
                min_y = min_y.min(word.2);
                max_x = max_x.max(word.1.saturating_add(word.3));
                max_y = max_y.max(word.2.saturating_add(word.4));
                if let Some(confidence) = word.5 {
                    confidence_sum = confidence_sum.saturating_add(u64::from(confidence));
                    confidence_count = confidence_count.saturating_add(1);
                }
                word.0.as_str()
            })
            .collect::<Vec<_>>()
            .join(" ");
        lines.push(OcrLine {
            text,
            locator: format!(
                "pixel:x={min_x},y={min_y},w={},h={}",
                max_x.saturating_sub(min_x),
                max_y.saturating_sub(min_y)
            ),
            confidence: (confidence_count > 0)
                .then(|| u16::try_from(confidence_sum / confidence_count).ok())
                .flatten(),
        });
    }
    Ok(OcrOutput { lines, words })
}

type OcrLineKey = (String, String, String, String);
type OcrWordTuple = (String, u32, u32, u32, u32, Option<u16>);

fn collect_ocr_rows(text: &str) -> (Vec<OcrWord>, BTreeMap<OcrLineKey, Vec<OcrWordTuple>>) {
    let mut words = Vec::new();
    let mut groups: BTreeMap<OcrLineKey, Vec<OcrWordTuple>> = BTreeMap::new();
    for row in text.lines().skip(1) {
        let columns = row.split('\t').collect::<Vec<_>>();
        if columns.len() < 12 || columns.first().copied() != Some("5") {
            continue;
        }
        let Some(text_column) = columns.get(11) else {
            continue;
        };
        let value = normalize_text(text_column);
        if value.is_empty() {
            continue;
        }
        let confidence = parse_confidence(columns.get(10).copied());
        let left = parse_coordinate(columns.get(6).copied());
        let top = parse_coordinate(columns.get(7).copied());
        let width = parse_coordinate(columns.get(8).copied());
        let height = parse_coordinate(columns.get(9).copied());
        if width == 0 || height == 0 {
            continue;
        }
        words.push(OcrWord {
            text: value.clone(),
            locator: format!("pixel:x={left},y={top},w={width},h={height}"),
            confidence,
        });
        let key = (1..=4)
            .map(|index| columns.get(index).map_or("", |value| *value).to_owned())
            .collect::<Vec<_>>();
        if let [a, b, c, d] = key.as_slice() {
            groups
                .entry((a.clone(), b.clone(), c.clone(), d.clone()))
                .or_default()
                .push((value, left, top, width, height, confidence));
        }
    }
    (words, groups)
}

fn parse_confidence(value: Option<&str>) -> Option<u16> {
    value
        .and_then(|column| column.parse::<f64>().ok())
        .and_then(|value| {
            if value.is_finite() && value >= 0.0 {
                u16::try_from((value.clamp(0.0, 100.0) * 100.0).round() as u64).ok()
            } else {
                None
            }
        })
}

fn parse_coordinate(value: Option<&str>) -> u32 {
    value
        .and_then(|item| item.parse::<u32>().ok())
        .map_or(0, |item| item)
}
