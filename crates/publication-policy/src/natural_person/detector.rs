use std::collections::BTreeSet;

use unicode_normalization::UnicodeNormalization;

use super::scanner::{
    NATURAL_PERSON_RULESET_VERSION, NaturalPersonFinding, NaturalPersonFindingBasis,
};

pub(super) const NORMALIZATION_VERSION: &str = "nfkc-lower-name-separators-v1";
pub(super) const TITLE_ADJACENCY_VERSION: &str = "horizontal-separator-token-v1";
pub(super) const TITLE_LEXICON: &[&str] = &[
    "감사원장",
    "국회의원",
    "대표이사",
    "상임감사",
    "지방의원",
    "교육감",
    "국무총리",
    "기관장",
    "대통령",
    "부기관장",
    "부사장",
    "부위원장",
    "시장",
    "실장",
    "위원장",
    "이사장",
    "차관",
    "총장",
    "감사",
    "과장",
    "구청장",
    "국장",
    "군수",
    "담당관",
    "도지사",
    "대표",
    "본부장",
    "부장",
    "상무",
    "원장",
    "이사",
    "임원",
    "장관",
    "전무",
    "청장",
    "팀장",
    "회장",
    "부회장",
    "사장",
];
const KOREAN_PARTICLES: &[&str] = &[
    "에게서",
    "으로서",
    "으로는",
    "에게",
    "께서",
    "으로",
    "라는",
    "이라고",
    "은",
    "는",
    "이",
    "가",
    "을",
    "를",
    "의",
    "와",
    "과",
    "께",
    "도",
    "만",
];

pub(super) fn normalize_name(value: &str) -> String {
    value
        .nfkc()
        .flat_map(char::to_lowercase)
        .filter(|character| !is_name_separator(*character))
        .collect()
}

pub(super) fn find_registered_people(
    path: &str,
    text: &str,
    registered_names: &BTreeSet<String>,
) -> Vec<NaturalPersonFinding> {
    let maximum_name_length = registered_names
        .iter()
        .map(|name| name.chars().count())
        .max()
        .unwrap_or_default();
    if maximum_name_length == 0 {
        return Vec::new();
    }
    let maximum_source_length = maximum_name_length.saturating_mul(3).saturating_add(8);
    let boundaries = text
        .char_indices()
        .map(|(start, character)| (start, start + character.len_utf8(), character))
        .collect::<Vec<_>>();
    let mut findings = Vec::new();
    for start_index in 0..boundaries.len() {
        if !boundaries[start_index].2.is_alphanumeric() {
            continue;
        }
        let final_index = boundaries.len().min(start_index + maximum_source_length);
        for end_index in start_index..final_index {
            let (_, end, character) = boundaries[end_index];
            if !character.is_alphanumeric() && !is_name_separator(character) {
                break;
            }
            if is_name_separator(character) {
                continue;
            }
            let start = boundaries[start_index].0;
            if registered_names.contains(&normalize_name(&text[start..end])) {
                findings.push(finding(
                    path,
                    text,
                    (start, end),
                    NaturalPersonFindingBasis::RegisteredPersonExact,
                ));
            }
        }
    }
    findings
}

pub(super) fn find_title_adjacent_names(path: &str, text: &str) -> Vec<NaturalPersonFinding> {
    let tokens = title_tokens(text);
    let mut findings = Vec::new();
    for pair in tokens.windows(2) {
        if !are_adjacent_title_tokens(text, pair[0], pair[1]) {
            continue;
        }
        if is_title_token(pair[0].text(text))
            && let Some(span) = person_token_span(pair[1], text)
        {
            findings.push(finding(
                path,
                text,
                span,
                NaturalPersonFindingBasis::TitleAdjacentKoreanName,
            ));
        }
        if is_title_token(pair[1].text(text))
            && let Some(span) = person_token_span(pair[0], text)
        {
            findings.push(finding(
                path,
                text,
                span,
                NaturalPersonFindingBasis::TitleAdjacentKoreanName,
            ));
        }
    }
    findings
}

#[derive(Clone, Copy)]
struct TextToken {
    start: usize,
    end: usize,
}

impl TextToken {
    fn text(self, source: &str) -> &str {
        &source[self.start..self.end]
    }
}

fn title_tokens(text: &str) -> Vec<TextToken> {
    let mut tokens = Vec::new();
    let mut token_start = None;
    for (start, character) in text.char_indices() {
        if is_title_separator(character) {
            if let Some(open) = token_start.take() {
                tokens.push(TextToken {
                    start: open,
                    end: start,
                });
            }
        } else if token_start.is_none() {
            token_start = Some(start);
        }
    }
    if let Some(start) = token_start {
        tokens.push(TextToken {
            start,
            end: text.len(),
        });
    }
    tokens
}

fn are_adjacent_title_tokens(text: &str, left: TextToken, right: TextToken) -> bool {
    let separator = &text[left.end..right.start];
    let separator_length = separator.chars().count();
    (1..=4).contains(&separator_length) && separator.chars().all(is_title_separator)
}

fn is_title_token(value: &str) -> bool {
    let normalized = value.nfkc().collect::<String>();
    TITLE_LEXICON.iter().any(|title| {
        normalized == *title
            || normalized
                .strip_prefix(title)
                .is_some_and(|suffix| KOREAN_PARTICLES.contains(&suffix))
    })
}

fn person_token_span(token: TextToken, text: &str) -> Option<(usize, usize)> {
    let value = token.text(text).nfkc().collect::<String>();
    let stripped = strip_korean_particle(&value);
    if !(2..=4).contains(&stripped.chars().count()) || !stripped.chars().all(is_hangul_syllable) {
        return None;
    }
    original_prefix_end(token.text(text), stripped).map(|end| (token.start, token.start + end))
}

fn original_prefix_end(value: &str, normalized_prefix: &str) -> Option<usize> {
    value
        .char_indices()
        .map(|(start, character)| start + character.len_utf8())
        .find(|end| normalize_name(&value[..*end]) == normalized_prefix)
}

fn strip_korean_particle(value: &str) -> &str {
    KOREAN_PARTICLES
        .iter()
        .filter_map(|particle| value.strip_suffix(particle))
        .filter(|candidate| (2..=4).contains(&candidate.chars().count()))
        .max_by_key(|candidate| candidate.len())
        .unwrap_or(value)
}

fn finding(
    path: &str,
    text: &str,
    span: (usize, usize),
    basis: NaturalPersonFindingBasis,
) -> NaturalPersonFinding {
    NaturalPersonFinding {
        path: path.to_owned(),
        start_utf16: text[..span.0].encode_utf16().count(),
        end_utf16: text[..span.1].encode_utf16().count(),
        basis,
        ruleset_version: NATURAL_PERSON_RULESET_VERSION,
    }
}

fn is_name_separator(character: char) -> bool {
    character.is_whitespace() || matches!(character, '.' | '·' | 'ㆍ' | '-' | '‐' | '‑' | '–')
}

fn is_title_separator(character: char) -> bool {
    matches!(
        character,
        ' ' | '\t' | ':' | ',' | '·' | 'ㆍ' | '-' | '‐' | '‑' | '–' | '(' | ')' | '[' | ']'
    )
}

fn is_hangul_syllable(character: char) -> bool {
    ('가'..='힣').contains(&character)
}
