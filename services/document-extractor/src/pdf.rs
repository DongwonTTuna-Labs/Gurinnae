use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    process::Output,
    time::Duration,
};

use tokio::{fs, process::Command, time::timeout};
use uuid::Uuid;

use crate::{
    formats::{block, complete},
    model::{
        BlockKind, ExtractionResult, ExtractionStatus, LocatorKind, Page, rejected, sha256_hex,
    },
};

const PDF_MEDIA: &str = "application/pdf";
const MAX_PAGES: usize = 1_000;
const MAX_PIXELS_PER_PAGE: u64 = 250_000_000;

#[derive(Clone, Debug)]
pub struct ToolVersions {
    pub pdftotext: String,
    pub pdftoppm: String,
    pub tesseract: String,
}

impl ToolVersions {
    pub async fn detect() -> Result<Self, String> {
        let pdftotext = version(&["pdftotext", "-v"], "pdftotext version ").await?;
        let pdftoppm = version(&["pdftoppm", "-v"], "pdftoppm version ").await?;
        let tesseract = version(&["tesseract", "--version"], "tesseract ").await?;
        if pdftotext != "25.06.0" || pdftoppm != "25.06.0" || tesseract != "5.5.0" {
            return Err("PARSER_TOOL_VERSION_MISMATCH".to_owned());
        }
        Ok(Self {
            pdftotext,
            pdftoppm,
            tesseract,
        })
    }
}

pub async fn extract(path: &Path, bytes: &[u8], versions: &ToolVersions) -> ExtractionResult {
    let document_sha256 = sha256_hex(bytes);
    if !bytes.starts_with(b"%PDF")
        || !bytes
            .strip_suffix(b"\n")
            .unwrap_or(bytes)
            .ends_with(b"%%EOF")
    {
        return rejected(
            document_sha256,
            PDF_MEDIA,
            "pdf",
            "pdf-reference-v1",
            "PDF_TRUNCATED_OR_INVALID",
        );
    }
    let metadata = match pdf_metadata(path).await {
        Ok(metadata) => metadata,
        Err(_) => {
            return rejected(
                document_sha256,
                PDF_MEDIA,
                "pdf",
                "pdf-reference-v1",
                "PDF_INVALID",
            );
        }
    };
    if metadata.encrypted {
        return rejected(
            document_sha256,
            PDF_MEDIA,
            "pdf",
            "pdf-reference-v1",
            "ENCRYPTED_DOCUMENT",
        );
    }
    if metadata.pages > MAX_PAGES {
        return rejected(
            document_sha256,
            PDF_MEDIA,
            "pdf",
            "pdf-reference-v1",
            "TOO_MANY_PAGES",
        );
    }
    let text_output = match run(
        &["pdftotext", "-layout", path_string(path).as_str(), "-"],
        60,
    )
    .await
    {
        Ok(output) if output.status.success() => output,
        _ => {
            return failed(
                document_sha256,
                "pdf-digital",
                &format!("pdftotext-{}", versions.pdftotext),
                "PDF_TEXT_EXTRACTION_FAILED",
            );
        }
    };
    let text = String::from_utf8_lossy(&text_output.stdout);
    let normalized = text
        .split('\u{000c}')
        .take(metadata.pages)
        .map(crate::model::normalize_text)
        .collect::<Vec<_>>();
    let empty = normalized.iter().filter(|text| text.is_empty()).count();
    let characters = normalized.iter().map(String::len).sum::<usize>();
    let page_count = metadata.pages.max(1);
    let needs_ocr = characters / page_count < 20 || empty * 10 > page_count * 8;
    if !needs_ocr {
        let pages = normalized
            .into_iter()
            .enumerate()
            .map(|(index, text)| {
                let blocks = if text.is_empty() {
                    Vec::new()
                } else {
                    let value = format!(
                        "page={};bbox=0,0,{:.3},{:.3};unit=pt",
                        index + 1,
                        metadata.width,
                        metadata.height
                    );
                    vec![block(
                        &document_sha256,
                        BlockKind::Paragraph,
                        LocatorKind::PageBbox,
                        "PAGE_BBOX",
                        value,
                        text,
                        None,
                    )]
                };
                Page {
                    index,
                    width: Some(metadata.width),
                    height: Some(metadata.height),
                    blocks,
                    tables: Vec::new(),
                }
            })
            .collect();
        return complete(
            document_sha256,
            PDF_MEDIA,
            "pdf-digital",
            &format!("pdftotext-{}", versions.pdftotext),
            pages,
            Vec::new(),
        );
    }
    ocr(path, document_sha256, metadata, versions).await
}

#[derive(Clone, Copy)]
struct PdfMetadata {
    pages: usize,
    width: f64,
    height: f64,
    encrypted: bool,
}

async fn pdf_metadata(path: &Path) -> Result<PdfMetadata, String> {
    let output = run(&["pdfinfo", path_string(path).as_str()], 20).await?;
    if !output.status.success() {
        return Err("PDF_INVALID".to_owned());
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let mut pages = None;
    let mut width = None;
    let mut height = None;
    let mut encrypted = false;
    for line in text.lines() {
        if let Some(value) = line.strip_prefix("Pages:") {
            pages = value.trim().parse().ok();
        }
        if let Some(value) = line.strip_prefix("Page size:") {
            let dimensions = value.split_whitespace().collect::<Vec<_>>();
            width = dimensions.first().and_then(|value| value.parse().ok());
            height = dimensions.get(2).and_then(|value| value.parse().ok());
        }
        if let Some(value) = line.strip_prefix("Encrypted:") {
            encrypted = !value.trim().eq_ignore_ascii_case("no");
        }
    }
    match (pages, width, height) {
        (Some(pages), Some(width), Some(height)) => Ok(PdfMetadata {
            pages,
            width,
            height,
            encrypted,
        }),
        _ => Err("PDF_INVALID".to_owned()),
    }
}

async fn ocr(
    path: &Path,
    document_sha256: String,
    metadata: PdfMetadata,
    versions: &ToolVersions,
) -> ExtractionResult {
    let directory = std::env::temp_dir().join(format!("gurine-extractor-{}", Uuid::new_v4()));
    if fs::create_dir(&directory).await.is_err() {
        return failed(
            document_sha256,
            "pdf-ocr",
            &ocr_version(versions),
            "OCR_TEMP_DIRECTORY_FAILED",
        );
    }
    let result = ocr_in_directory(path, &directory, &document_sha256, metadata, versions).await;
    let _cleanup = fs::remove_dir_all(&directory).await;
    result
}

async fn ocr_in_directory(
    path: &Path,
    directory: &Path,
    document_sha256: &str,
    metadata: PdfMetadata,
    versions: &ToolVersions,
) -> ExtractionResult {
    let prefix = directory.join("page");
    let render = run(
        &[
            "pdftoppm",
            "-png",
            "-r",
            "300",
            path_string(path).as_str(),
            path_string(&prefix).as_str(),
        ],
        60,
    )
    .await;
    if !matches!(render, Ok(output) if output.status.success()) {
        return failed(
            document_sha256.to_owned(),
            "pdf-ocr",
            &ocr_version(versions),
            "PDF_RENDER_FAILED",
        );
    }
    let images = match image_files(directory).await {
        Ok(images) => images,
        Err(code) => {
            return failed(
                document_sha256.to_owned(),
                "pdf-ocr",
                &ocr_version(versions),
                &code,
            );
        }
    };
    if images.len() != metadata.pages {
        return failed(
            document_sha256.to_owned(),
            "pdf-ocr",
            &ocr_version(versions),
            "PDF_PAGE_COUNT_MISMATCH",
        );
    }
    let mut pages = Vec::new();
    for (index, image) in images.iter().enumerate() {
        if !valid_pixel_count(image).await {
            return rejected(
                document_sha256.to_owned(),
                PDF_MEDIA,
                "pdf-ocr",
                &ocr_version(versions),
                "PIXEL_LIMIT",
            );
        }
        let output = run(
            &[
                "tesseract",
                path_string(image).as_str(),
                "stdout",
                "-l",
                "kor+eng",
                "--psm",
                "6",
                "tsv",
            ],
            60,
        )
        .await;
        let output = match output {
            Ok(output) if output.status.success() => output,
            _ => {
                return failed(
                    document_sha256.to_owned(),
                    "pdf-ocr",
                    &ocr_version(versions),
                    "OCR_FAILED",
                );
            }
        };
        let blocks = match tsv_blocks(&output.stdout, document_sha256, index) {
            Ok(blocks) => blocks,
            Err(code) => {
                return failed(
                    document_sha256.to_owned(),
                    "pdf-ocr",
                    &ocr_version(versions),
                    &code,
                );
            }
        };
        pages.push(Page {
            index,
            width: Some(metadata.width),
            height: Some(metadata.height),
            blocks,
            tables: Vec::new(),
        });
    }
    complete(
        document_sha256.to_owned(),
        PDF_MEDIA,
        "pdf-ocr",
        &ocr_version(versions),
        pages,
        vec![
            "OCR_FALLBACK_USED".to_owned(),
            "OCR_LANGUAGE_KOR_ENG".to_owned(),
        ],
    )
}

#[derive(Clone)]
struct Word {
    text: String,
    left: i32,
    top: i32,
    width: i32,
    height: i32,
    confidence: f64,
}

fn tsv_blocks(
    bytes: &[u8],
    document_sha256: &str,
    page_index: usize,
) -> Result<Vec<crate::model::Block>, String> {
    let mut reader = csv::ReaderBuilder::new()
        .delimiter(b'\t')
        .from_reader(bytes);
    let headers = reader
        .headers()
        .map_err(|_| "OCR_TSV_INVALID".to_owned())?
        .clone();
    let index = |name: &str| {
        headers
            .iter()
            .position(|header| header == name)
            .ok_or_else(|| "OCR_TSV_INVALID".to_owned())
    };
    let level = index("level")?;
    let block_num = index("block_num")?;
    let par_num = index("par_num")?;
    let line_num = index("line_num")?;
    let left = index("left")?;
    let top = index("top")?;
    let width = index("width")?;
    let height = index("height")?;
    let confidence = index("conf")?;
    let text = index("text")?;
    let mut lines = BTreeMap::<(u32, u32, u32), Vec<Word>>::new();
    for record in reader.records() {
        let record = record.map_err(|_| "OCR_TSV_INVALID".to_owned())?;
        if record.get(level) != Some("5") {
            continue;
        }
        let word_text = crate::model::normalize_text(record.get(text).unwrap_or_default());
        if word_text.is_empty() {
            continue;
        }
        let parse_u32 = |position| {
            record
                .get(position)
                .and_then(|value| value.parse::<u32>().ok())
                .ok_or_else(|| "OCR_TSV_INVALID".to_owned())
        };
        let parse_i32 = |position| {
            record
                .get(position)
                .and_then(|value| value.parse::<i32>().ok())
                .ok_or_else(|| "OCR_TSV_INVALID".to_owned())
        };
        let parsed_confidence = record
            .get(confidence)
            .and_then(|value| value.parse::<f64>().ok())
            .ok_or_else(|| "OCR_TSV_INVALID".to_owned())?;
        let key = (
            parse_u32(block_num)?,
            parse_u32(par_num)?,
            parse_u32(line_num)?,
        );
        lines.entry(key).or_default().push(Word {
            text: word_text,
            left: parse_i32(left)?,
            top: parse_i32(top)?,
            width: parse_i32(width)?,
            height: parse_i32(height)?,
            confidence: parsed_confidence,
        });
    }
    let mut blocks = Vec::new();
    for (line_index, words) in lines.into_values().enumerate() {
        let left = words
            .iter()
            .map(|word| word.left)
            .min()
            .ok_or_else(|| "OCR_TSV_INVALID".to_owned())?;
        let top = words
            .iter()
            .map(|word| word.top)
            .min()
            .ok_or_else(|| "OCR_TSV_INVALID".to_owned())?;
        let right = words
            .iter()
            .map(|word| word.left + word.width)
            .max()
            .ok_or_else(|| "OCR_TSV_INVALID".to_owned())?;
        let bottom = words
            .iter()
            .map(|word| word.top + word.height)
            .max()
            .ok_or_else(|| "OCR_TSV_INVALID".to_owned())?;
        let accepted = words
            .iter()
            .filter(|word| word.confidence >= 0.0)
            .map(|word| word.confidence)
            .collect::<Vec<_>>();
        let confidence = if accepted.is_empty() {
            None
        } else {
            let average = accepted.iter().sum::<f64>() / accepted.len() as f64 / 100.0;
            Some((average * 1_000_000.0).round() / 1_000_000.0)
        };
        let value = format!(
            "page={};bbox={left},{top},{},{};unit=px;dpi=300;line={}",
            page_index + 1,
            right - left,
            bottom - top,
            line_index + 1
        );
        let text = words
            .into_iter()
            .map(|word| word.text)
            .collect::<Vec<_>>()
            .join(" ");
        blocks.push(block(
            document_sha256,
            BlockKind::OcrText,
            LocatorKind::PageBbox,
            "PAGE_BBOX",
            value,
            text,
            confidence,
        ));
    }
    Ok(blocks)
}

async fn image_files(directory: &Path) -> Result<Vec<PathBuf>, String> {
    let mut entries = fs::read_dir(directory)
        .await
        .map_err(|_| "PDF_RENDER_FAILED".to_owned())?;
    let mut images = Vec::new();
    while let Some(entry) = entries
        .next_entry()
        .await
        .map_err(|_| "PDF_RENDER_FAILED".to_owned())?
    {
        let path = entry.path();
        if path.extension().and_then(|value| value.to_str()) == Some("png") {
            images.push(path);
        }
    }
    images.sort();
    Ok(images)
}

async fn valid_pixel_count(path: &Path) -> bool {
    let bytes = match fs::read(path).await {
        Ok(bytes) => bytes,
        Err(_) => return false,
    };
    if bytes.len() < 24 || &bytes[..8] != b"\x89PNG\r\n\x1a\n" {
        return false;
    }
    let width = u32::from_be_bytes([bytes[16], bytes[17], bytes[18], bytes[19]]) as u64;
    let height = u32::from_be_bytes([bytes[20], bytes[21], bytes[22], bytes[23]]) as u64;
    width.saturating_mul(height) <= MAX_PIXELS_PER_PAGE
}

async fn version(command: &[&str], prefix: &str) -> Result<String, String> {
    let output = run(command, 10).await?;
    let combined = format!(
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    combined
        .lines()
        .find_map(|line| {
            line.split_once(prefix).map(|(_, value)| {
                value
                    .split_whitespace()
                    .next()
                    .unwrap_or_default()
                    .to_owned()
            })
        })
        .filter(|version| !version.is_empty())
        .ok_or_else(|| "PARSER_TOOL_VERSION_UNAVAILABLE".to_owned())
}

async fn run(command: &[&str], seconds: u64) -> Result<Output, String> {
    let (program, arguments) = command
        .split_first()
        .ok_or_else(|| "PROCESS_COMMAND_EMPTY".to_owned())?;
    let mut child = Command::new(program);
    child.args(arguments).kill_on_drop(true);
    timeout(Duration::from_secs(seconds), child.output())
        .await
        .map_err(|_| "TIMEOUT".to_owned())?
        .map_err(|_| "PROCESS_START_FAILED".to_owned())
}

fn failed(document_sha256: String, parser: &str, version: &str, code: &str) -> ExtractionResult {
    ExtractionResult {
        document_sha256,
        media_type: PDF_MEDIA.to_owned(),
        parser_id: parser.to_owned(),
        parser_version: version.to_owned(),
        status: ExtractionStatus::Failed,
        pages: Vec::new(),
        warnings: vec![code.to_owned()],
        rejection_code: Some(code.to_owned()),
    }
}

fn ocr_version(versions: &ToolVersions) -> String {
    format!(
        "pdftoppm-{}+tesseract-{}-kor+eng",
        versions.pdftoppm, versions.tesseract
    )
}

fn path_string(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}
