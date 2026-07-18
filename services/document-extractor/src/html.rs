use std::{cell::RefCell, collections::BTreeMap, rc::Rc};

use html5ever::tokenizer::{
    BufferQueue, TagKind, Token, TokenSink, TokenSinkResult, Tokenizer, TokenizerOpts,
};
use tendril::StrTendril;

use super::{
    AssetBinding, ExtractionTable, HtmlLink, Locator, LocatorKind, MAX_HTML_DEPTH, MAX_HTML_NODES,
    MediaMetadata, MultimodalExtractionResult, ParseError, base_result, normalize_text, rejected,
    segment, stable_id,
};

pub(super) fn parse_html(
    bytes: &[u8],
    binding: &AssetBinding,
) -> Result<MultimodalExtractionResult, ParseError> {
    let source = match std::str::from_utf8(bytes) {
        Ok(value) => value,
        Err(_) => {
            return Ok(rejected(
                binding,
                "text/html",
                "html-static",
                "html5ever-0.39.0+gurinnae-html-v1",
                "MALFORMED_HTML",
            ));
        }
    };
    let sink = Rc::new(RefCell::new(HtmlState::default()));
    let tokenizer = Tokenizer::new(
        HtmlSink {
            state: sink.clone(),
        },
        TokenizerOpts {
            exact_errors: true,
            ..TokenizerOpts::default()
        },
    );
    let queue = BufferQueue::default();
    queue.push_back(StrTendril::from_slice(source));
    let _ = tokenizer.feed(&queue);
    tokenizer.end();
    drop(tokenizer);
    let state = Rc::try_unwrap(sink)
        .map_err(|_| ParseError::Malformed("HTML_STATE_BUSY".to_owned()))?
        .into_inner();
    if state.nodes > MAX_HTML_NODES || state.max_depth > MAX_HTML_DEPTH {
        let code = if state.max_depth > MAX_HTML_DEPTH {
            "HTML_DEPTH_LIMIT"
        } else {
            "HTML_NODE_LIMIT"
        };
        return Ok(rejected(
            binding,
            "text/html",
            "html-static",
            "html5ever-0.39.0+gurinnae-html-v1",
            code,
        ));
    }
    if state.text_bytes > 52_428_800 {
        return Ok(rejected(
            binding,
            "text/html",
            "html-static",
            "html5ever-0.39.0+gurinnae-html-v1",
            "HTML_TEXT_LIMIT",
        ));
    }
    Ok(build_html_result(binding, state))
}

fn build_html_result(binding: &AssetBinding, state: HtmlState) -> MultimodalExtractionResult {
    let version = "html5ever-0.39.0+gurinnae-html-v1";
    let mut result = base_result(binding, "text/html", "html-static", version);
    result.metadata = Some(MediaMetadata::Html {
        document_title: state.title.clone(),
        language: state.language.clone(),
        node_count: state.nodes,
        active_content_count: state.active_content,
    });
    result.segments = state
        .segments
        .into_iter()
        .map(|item| {
            segment(
                binding,
                &item.kind,
                &item.text,
                Locator {
                    kind: LocatorKind::HtmlCssSelector,
                    value: item.path,
                },
                state.language.clone(),
                None,
                version,
            )
        })
        .filter(|item| !item.text.is_empty())
        .collect();
    result.tables = state
        .tables
        .into_iter()
        .map(|table| ExtractionTable {
            table_id: stable_id(
                binding,
                &table.path,
                table.caption.as_deref().map_or("", |value| value),
            ),
            caption: table.caption,
            locator: Locator {
                kind: LocatorKind::HtmlCssSelector,
                value: table.path,
            },
            rows: table.rows,
        })
        .collect();
    result.links = state
        .links
        .into_iter()
        .map(|link| HtmlLink {
            text: normalize_text(&link.text),
            absolute_url: link.url,
            locator: Locator {
                kind: LocatorKind::HtmlCssSelector,
                value: link.path,
            },
        })
        .collect();
    if state.active_content > 0 {
        result.warnings.push("ACTIVE_CONTENT_IGNORED".to_owned());
    }
    result.warnings.sort();
    result
}

#[derive(Default)]
struct HtmlState {
    stack: Vec<HtmlNode>,
    nodes: usize,
    max_depth: usize,
    text_bytes: usize,
    active_content: usize,
    title: Option<String>,
    language: Option<String>,
    segments: Vec<HtmlSegment>,
    tables: Vec<HtmlTable>,
    links: Vec<HtmlLinkRaw>,
}

struct HtmlNode {
    name: String,
    path: String,
    text: String,
    attrs: BTreeMap<String, String>,
    skip: bool,
    table_path: Option<String>,
    row: Option<Vec<String>>,
    caption: Option<String>,
    child_counts: BTreeMap<String, usize>,
}
struct HtmlSegment {
    kind: String,
    text: String,
    path: String,
}
struct HtmlTable {
    path: String,
    caption: Option<String>,
    rows: Vec<Vec<String>>,
}
struct HtmlLinkRaw {
    path: String,
    text: String,
    url: String,
}

struct HtmlSink {
    state: Rc<RefCell<HtmlState>>,
}

impl TokenSink for HtmlSink {
    type Handle = ();

    fn process_token(&self, token: Token, _line_number: u64) -> TokenSinkResult<Self::Handle> {
        let mut state = self.state.borrow_mut();
        match token {
            Token::TagToken(tag) if tag.kind == TagKind::StartTag => {
                handle_start_tag(&mut state, tag)
            }
            Token::TagToken(tag) if tag.kind == TagKind::EndTag => {
                let _ = tag;
                handle_end_tag(&mut state)
            }
            Token::CharacterTokens(text) => handle_character_tokens(&mut state, text),
            Token::NullCharacterToken => TokenSinkResult::Continue,
            Token::ParseError(_) => TokenSinkResult::Continue,
            Token::DoctypeToken(_) | Token::CommentToken(_) | Token::EOFToken => {
                TokenSinkResult::Continue
            }
            _ => TokenSinkResult::Continue,
        }
    }
}

fn handle_start_tag(state: &mut HtmlState, tag: html5ever::tokenizer::Tag) -> TokenSinkResult<()> {
    state.nodes = state.nodes.saturating_add(1);
    let name = tag.name.to_string().to_ascii_lowercase();
    let parent_skip = state.stack.last().is_some_and(|node| node.skip);
    let skip_here = parent_skip || is_inactive_element(&name);
    if is_inactive_element(&name) {
        state.active_content = state.active_content.saturating_add(1);
    }
    let attrs = tag
        .attrs
        .iter()
        .map(|attr| {
            (
                attr.name.local.to_string().to_ascii_lowercase(),
                attr.value.to_string(),
            )
        })
        .collect::<BTreeMap<_, _>>();
    if name == "html" {
        state.language = attrs.get("lang").map(|value| {
            value
                .split('-')
                .next()
                .map_or(value.as_str(), |part| part)
                .to_owned()
        });
    }
    let path = element_path(state, &name);
    let table_path = state
        .stack
        .iter()
        .rev()
        .find(|node| node.name == "table")
        .map(|node| node.path.clone())
        .or_else(|| (name == "table").then_some(path.clone()));
    let mut node = HtmlNode {
        name: name.clone(),
        path,
        text: String::new(),
        attrs,
        skip: skip_here,
        table_path,
        row: None,
        caption: None,
        child_counts: BTreeMap::new(),
    };
    if name == "tr" {
        node.row = Some(Vec::new());
    }
    state.max_depth = state.max_depth.max(state.stack.len() + 1);
    if !tag.self_closing {
        state.stack.push(node);
    } else {
        finalize_node(state, node);
    }
    TokenSinkResult::Continue
}

fn is_inactive_element(name: &str) -> bool {
    matches!(
        name,
        "script" | "style" | "template" | "noscript" | "form" | "select" | "textarea" | "button"
    )
}

fn element_path(state: &mut HtmlState, name: &str) -> String {
    let Some(parent) = state.stack.last_mut() else {
        return name.to_owned();
    };
    let count = parent.child_counts.entry(name.to_owned()).or_insert(0);
    *count += 1;
    let suffix = if matches!(name, "html" | "body" | "head" | "main") {
        String::new()
    } else {
        format!(":nth-of-type({count})")
    };
    format!("{} > {}{}", parent.path, name, suffix)
}

fn handle_end_tag(state: &mut HtmlState) -> TokenSinkResult<()> {
    let Some(node) = state.stack.pop() else {
        return TokenSinkResult::Continue;
    };
    finalize_node(state, node);
    TokenSinkResult::Continue
}

fn handle_character_tokens(
    state: &mut HtmlState,
    text: tendril::StrTendril,
) -> TokenSinkResult<()> {
    let text = text.to_string();
    state.text_bytes = state.text_bytes.saturating_add(text.len());
    if let Some(node) = state.stack.last_mut()
        && !node.skip
    {
        node.text.push_str(&text);
    }
    TokenSinkResult::Continue
}

fn finalize_node(state: &mut HtmlState, node: HtmlNode) {
    if node.skip {
        return;
    }
    let text = normalize_text(&node.text);
    if node.name == "title" && !text.is_empty() {
        state.title = Some(text.clone());
    }
    if matches!(
        node.name.as_str(),
        "h1" | "h2" | "h3" | "h4" | "h5" | "h6" | "p" | "li" | "a"
    ) && !text.is_empty()
    {
        let kind = match node.name.as_str() {
            "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => "HTML_HEADING",
            "li" => "HTML_LIST_ITEM",
            "a" => "HTML_LINK_TEXT",
            _ => "HTML_PARAGRAPH",
        };
        state.segments.push(HtmlSegment {
            kind: kind.to_owned(),
            text: text.clone(),
            path: node.path.clone(),
        });
    }
    if node.name == "a"
        && let Some(url) = node
            .attrs
            .get("href")
            .filter(|value| value.starts_with("https://"))
    {
        state.links.push(HtmlLinkRaw {
            path: node.path.clone(),
            text: text.clone(),
            url: url.clone(),
        });
    }
    if node.name == "td" || node.name == "th" {
        if let Some(parent) = state.stack.iter_mut().rev().find(|item| item.name == "tr")
            && let Some(row) = parent.row.as_mut()
        {
            row.push(text.clone());
        }
        if !text.is_empty() {
            state.segments.push(HtmlSegment {
                kind: "HTML_TABLE_CELL".to_owned(),
                text: text.clone(),
                path: node.path.clone(),
            });
        }
    }
    if node.name == "caption"
        && let Some(table) = state
            .stack
            .iter_mut()
            .rev()
            .find(|item| item.name == "table")
    {
        table.caption = Some(text.clone());
    }
    if node.name == "tr"
        && let (Some(table_path), Some(row)) = (node.table_path.clone(), node.row.clone())
    {
        if let Some(table) = state
            .tables
            .iter_mut()
            .find(|table| table.path == table_path)
        {
            table.rows.push(row);
        } else {
            state.tables.push(HtmlTable {
                path: table_path,
                caption: None,
                rows: vec![row],
            });
        }
    }
    finalize_table(state, &node);
}

fn finalize_table(state: &mut HtmlState, node: &HtmlNode) {
    if node.name != "table" {
        return;
    }
    if let Some(table) = state
        .tables
        .iter_mut()
        .find(|table| table.path == node.path)
    {
        table.caption = node.caption.clone();
    } else {
        state.tables.push(HtmlTable {
            path: node.path.clone(),
            caption: node.caption.clone(),
            rows: Vec::new(),
        });
    }
}
