use std::path::Path;

use calamine::{Reader, open_workbook_auto};

use crate::{
    archive,
    model::{
        Block, BlockKind, Cell, ExtractionResult, ExtractionStatus, LocatorKind, Page, Table,
        locator, normalize_text, rejected, sha256_hex, stable_id,
    },
    xml::{self, XmlNode},
};

const CSV_MEDIA: &str = "text/csv";
const XML_MEDIA: &str = "application/xml";
const XLSX_MEDIA: &str = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
const DOCX_MEDIA: &str = "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
const HWPX_MEDIA: &str = "application/hwp+zip";

pub fn csv(bytes: &[u8]) -> ExtractionResult {
    let document_sha256 = sha256_hex(bytes);
    let content = bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(bytes);
    let mut reader = csv::ReaderBuilder::new()
        .has_headers(false)
        .from_reader(content);
    let mut rows = Vec::new();
    for (row_index, record) in reader.records().enumerate() {
        let record = match record {
            Ok(record) => record,
            Err(_) => {
                return rejected(
                    document_sha256,
                    CSV_MEDIA,
                    "csv",
                    "1.4.0-reference-v1",
                    "CSV_INVALID",
                );
            }
        };
        let cells = record
            .iter()
            .enumerate()
            .map(|(column_index, text)| {
                let row = row_index + 1;
                let column = column_index + 1;
                Cell {
                    text: normalize_text(text),
                    row,
                    column,
                    locator: locator(
                        LocatorKind::CsvRowColumn,
                        format!("row={row};column={column}"),
                    ),
                }
            })
            .collect::<Vec<_>>();
        rows.push(cells);
    }
    let columns = rows.iter().map(Vec::len).max().unwrap_or(0);
    let table_locator = format!("csv:rows=1-{};columns=1-{columns}", rows.len());
    let table = Table {
        id: stable_id(
            "tbl",
            &document_sha256,
            "CSV_ROW_COLUMN",
            &table_locator,
            "",
        ),
        locator: locator(LocatorKind::CsvRowColumn, table_locator),
        rows,
    };
    complete(
        document_sha256,
        CSV_MEDIA,
        "csv",
        "1.4.0-reference-v1",
        vec![Page {
            index: 0,
            width: None,
            height: None,
            blocks: Vec::new(),
            tables: vec![table],
        }],
        Vec::new(),
    )
}

pub fn xml(bytes: &[u8]) -> ExtractionResult {
    let document_sha256 = sha256_hex(bytes);
    let root = match xml::parse(bytes) {
        Ok(root) => root,
        Err(code) => {
            let rejection = if code == "XML_DTD_OR_ENTITY" {
                code
            } else {
                "XML_INVALID".to_owned()
            };
            return rejected(
                document_sha256,
                XML_MEDIA,
                "xml",
                "0.41.0-reference-v1",
                &rejection,
            );
        }
    };
    let mut records = Vec::new();
    let root_path = format!("/{}[1]", root.name);
    collect_leaf_records(&root, &root_path, &mut records);
    let blocks = records
        .into_iter()
        .map(|(path, text)| {
            block(
                &document_sha256,
                BlockKind::Paragraph,
                LocatorKind::XmlXpath,
                "XML_XPATH",
                path,
                text,
                None,
            )
        })
        .collect();
    extracted_blocks(
        document_sha256,
        XML_MEDIA,
        "xml",
        "0.41.0-reference-v1",
        blocks,
    )
}

pub fn xlsx(path: &Path, bytes: &[u8]) -> ExtractionResult {
    let document_sha256 = sha256_hex(bytes);
    if let Err(code) = preflight_archive(path) {
        return rejected(
            document_sha256,
            XLSX_MEDIA,
            "xlsx",
            "0.35.0-reference-v1",
            &code,
        );
    }
    let mut workbook = match open_workbook_auto(path) {
        Ok(workbook) => workbook,
        Err(_) => {
            return rejected(
                document_sha256,
                XLSX_MEDIA,
                "xlsx",
                "0.35.0-reference-v1",
                "XLSX_INVALID",
            );
        }
    };
    let mut pages = Vec::new();
    for (sheet_index, sheet_name) in workbook.sheet_names().into_iter().enumerate() {
        let range = match workbook.worksheet_range(&sheet_name) {
            Ok(range) => range,
            Err(_) => {
                return rejected(
                    document_sha256,
                    XLSX_MEDIA,
                    "xlsx",
                    "0.35.0-reference-v1",
                    "XLSX_INVALID",
                );
            }
        };
        let start = range.start().unwrap_or((0, 0));
        let rows = range
            .rows()
            .enumerate()
            .map(|(row_offset, values)| {
                values
                    .iter()
                    .enumerate()
                    .map(|(column_offset, value)| {
                        let row = start.0 as usize + row_offset + 1;
                        let column = start.1 as usize + column_offset + 1;
                        let reference = format!("{}{row}", column_letters(column));
                        Cell {
                            text: normalize_text(&value.to_string()),
                            row,
                            column,
                            locator: locator(
                                LocatorKind::XlsxCell,
                                format!("sheet={sheet_name};cell={reference}"),
                            ),
                        }
                    })
                    .collect::<Vec<_>>()
            })
            .collect::<Vec<_>>();
        let range_reference = range
            .start()
            .zip(range.end())
            .map(|(start, end)| {
                format!(
                    "{}{}:{}{}",
                    column_letters(start.1 as usize + 1),
                    start.0 + 1,
                    column_letters(end.1 as usize + 1),
                    end.0 + 1
                )
            })
            .unwrap_or_default();
        let table_locator = format!("sheet={sheet_name};range={range_reference}");
        pages.push(Page {
            index: sheet_index,
            width: None,
            height: None,
            blocks: Vec::new(),
            tables: vec![Table {
                id: stable_id("tbl", &document_sha256, "XLSX_CELL", &table_locator, ""),
                locator: locator(LocatorKind::XlsxCell, table_locator),
                rows,
            }],
        });
    }
    complete(
        document_sha256,
        XLSX_MEDIA,
        "xlsx",
        "0.35.0-reference-v1",
        pages,
        Vec::new(),
    )
}

pub fn docx(path: &Path, bytes: &[u8]) -> ExtractionResult {
    let document_sha256 = sha256_hex(bytes);
    let mut archive = match archive::open_checked(path) {
        Ok(archive) => archive,
        Err(code) => {
            return rejected(
                document_sha256,
                DOCX_MEDIA,
                "docx",
                "zip-8.6.0+quick-xml-0.41.0-reference-v1",
                &code,
            );
        }
    };
    if let Err(code) = archive::reject_external_relationships(&mut archive) {
        return rejected(
            document_sha256,
            DOCX_MEDIA,
            "docx",
            "zip-8.6.0+quick-xml-0.41.0-reference-v1",
            &code,
        );
    }
    let document = match archive::read_entry(&mut archive, "word/document.xml") {
        Ok(document) => document,
        Err(_) => {
            return rejected(
                document_sha256,
                DOCX_MEDIA,
                "docx",
                "zip-8.6.0+quick-xml-0.41.0-reference-v1",
                "DOCX_MAIN_DOCUMENT_MISSING",
            );
        }
    };
    let root = match xml::parse(&document) {
        Ok(root) => root,
        Err(code) => {
            return rejected(
                document_sha256,
                DOCX_MEDIA,
                "docx",
                "zip-8.6.0+quick-xml-0.41.0-reference-v1",
                &code,
            );
        }
    };
    let body = root.descendants_named("body").into_iter().next();
    let paragraphs = body
        .map(|body| body.children.iter().filter(|node| node.name == "p"))
        .into_iter()
        .flatten();
    let blocks = paragraphs
        .enumerate()
        .filter_map(|(index, paragraph)| {
            let text = normalize_text(&paragraph.all_text());
            if text.is_empty() {
                return None;
            }
            let heading = paragraph
                .descendants_named("pStyle")
                .into_iter()
                .filter_map(|style| style.attributes.get("val"))
                .any(|style| {
                    matches!(
                        style.to_ascii_lowercase().as_str(),
                        "title" | "heading1" | "heading2"
                    )
                });
            let value = format!("word/document.xml#/w:document/w:body/w:p[{}]", index + 1);
            Some(block(
                &document_sha256,
                if heading {
                    BlockKind::Heading
                } else {
                    BlockKind::Paragraph
                },
                LocatorKind::DocxParagraph,
                "DOCX_PARAGRAPH",
                value,
                text,
                None,
            ))
        })
        .collect();
    extracted_blocks(
        document_sha256,
        DOCX_MEDIA,
        "docx",
        "zip-8.6.0+quick-xml-0.41.0-reference-v1",
        blocks,
    )
}

pub fn hwpx(path: &Path, bytes: &[u8]) -> ExtractionResult {
    let document_sha256 = sha256_hex(bytes);
    let mut archive = match archive::open_checked(path) {
        Ok(archive) => archive,
        Err(code) => {
            return rejected(
                document_sha256,
                HWPX_MEDIA,
                "hwpx",
                "zip-8.6.0+quick-xml-0.41.0-reference-v1",
                &code,
            );
        }
    };
    if let Err(code) = archive::reject_external_relationships(&mut archive) {
        return rejected(
            document_sha256,
            HWPX_MEDIA,
            "hwpx",
            "zip-8.6.0+quick-xml-0.41.0-reference-v1",
            &code,
        );
    }
    let mut sections = (0..archive.len())
        .filter_map(|index| {
            archive
                .by_index(index)
                .ok()
                .map(|entry| entry.name().to_owned())
        })
        .filter(|name| section_number(name).is_some())
        .collect::<Vec<_>>();
    sections.sort_by_key(|name| section_number(name));
    if sections.is_empty() {
        return rejected(
            document_sha256,
            HWPX_MEDIA,
            "hwpx",
            "zip-8.6.0+quick-xml-0.41.0-reference-v1",
            "HWPX_SECTION_MISSING",
        );
    }
    let mut pages = Vec::new();
    for (page_index, name) in sections.into_iter().enumerate() {
        let section =
            match archive::read_entry(&mut archive, &name).and_then(|bytes| xml::parse(&bytes)) {
                Ok(section) => section,
                Err(code) => {
                    return rejected(
                        document_sha256,
                        HWPX_MEDIA,
                        "hwpx",
                        "zip-8.6.0+quick-xml-0.41.0-reference-v1",
                        &code,
                    );
                }
            };
        let blocks = section
            .descendants_named("p")
            .into_iter()
            .enumerate()
            .filter_map(|(index, paragraph)| {
                let text = normalize_text(&paragraph.all_text());
                if text.is_empty() {
                    return None;
                }
                let value = format!("{name}#/section[1]/p[{}]", index + 1);
                Some(block(
                    &document_sha256,
                    BlockKind::Paragraph,
                    LocatorKind::HwpxXpath,
                    "HWPX_XPATH",
                    value,
                    text,
                    None,
                ))
            })
            .collect();
        pages.push(Page {
            index: page_index,
            width: None,
            height: None,
            blocks,
            tables: Vec::new(),
        });
    }
    complete(
        document_sha256,
        HWPX_MEDIA,
        "hwpx",
        "zip-8.6.0+quick-xml-0.41.0-reference-v1",
        pages,
        Vec::new(),
    )
}

fn preflight_archive(path: &Path) -> Result<(), String> {
    let mut archive = archive::open_checked(path)?;
    archive::reject_external_relationships(&mut archive)
}

fn collect_leaf_records(node: &XmlNode, path: &str, records: &mut Vec<(String, String)>) {
    let mut counts = std::collections::BTreeMap::<&str, usize>::new();
    for child in &node.children {
        let count = counts.entry(child.name.as_str()).or_default();
        *count += 1;
        collect_leaf_records(child, &format!("{path}/{}[{count}]", child.name), records);
    }
    let text = normalize_text(&node.text);
    if node.children.is_empty() && !text.is_empty() {
        records.push((path.to_owned(), text));
    }
}

fn extracted_blocks(
    document_sha256: String,
    media: &str,
    parser: &str,
    version: &str,
    blocks: Vec<Block>,
) -> ExtractionResult {
    complete(
        document_sha256,
        media,
        parser,
        version,
        vec![Page {
            index: 0,
            width: None,
            height: None,
            blocks,
            tables: Vec::new(),
        }],
        Vec::new(),
    )
}

pub(crate) fn block(
    document_sha256: &str,
    kind: BlockKind,
    locator_kind: LocatorKind,
    locator_name: &str,
    value: String,
    text: String,
    confidence: Option<f64>,
) -> Block {
    Block {
        id: stable_id("blk", document_sha256, locator_name, &value, &text),
        kind,
        text,
        locator: locator(locator_kind, value),
        confidence,
    }
}

pub(crate) fn complete(
    document_sha256: String,
    media: &str,
    parser: &str,
    version: &str,
    pages: Vec<Page>,
    warnings: Vec<String>,
) -> ExtractionResult {
    ExtractionResult {
        document_sha256,
        media_type: media.to_owned(),
        parser_id: parser.to_owned(),
        parser_version: version.to_owned(),
        status: ExtractionStatus::Extracted,
        pages,
        warnings,
        rejection_code: None,
    }
}

fn column_letters(mut column: usize) -> String {
    let mut letters = Vec::new();
    while column > 0 {
        let remainder = (column - 1) % 26;
        letters.push((b'A' + remainder as u8) as char);
        column = (column - 1) / 26;
    }
    letters.into_iter().rev().collect()
}

fn section_number(name: &str) -> Option<u32> {
    name.strip_prefix("Contents/section")
        .and_then(|value| value.strip_suffix(".xml"))
        .and_then(|value| value.parse().ok())
}
