use std::collections::BTreeSet;

use serde::Serialize;
use sha2::{Digest, Sha256};
use thiserror::Error;

use super::detector::{
    NORMALIZATION_VERSION, TITLE_ADJACENCY_VERSION, TITLE_LEXICON, find_registered_people,
    find_title_adjacent_names, normalize_name,
};

pub const NATURAL_PERSON_RULESET_VERSION: &str = "ko-named-individual-v1";

/// An explicit tree of text fields that are eligible for public rendering.
///
/// Callers construct this from typed DTO fields. The scanner never walks arbitrary serialized
/// input, so internal identifiers and non-public fields cannot accidentally enter its findings.
pub enum PublicTextNode<'a> {
    Text(&'a str),
    Object(Vec<(&'a str, PublicTextNode<'a>)>),
    Array(Vec<PublicTextNode<'a>>),
}

impl<'a> PublicTextNode<'a> {
    pub const fn text(value: &'a str) -> Self {
        Self::Text(value)
    }

    pub fn object(fields: Vec<(&'a str, Self)>) -> Self {
        Self::Object(fields)
    }

    pub fn array(items: Vec<Self>) -> Self {
        Self::Array(items)
    }
}

/// A registered PERSON display name used only as a blocking signal.
///
/// It deliberately carries neither a PERSON identifier nor an identity-resolution score. A scan
/// match is never evidence for merging identities.
pub struct RegisteredPersonName<'a> {
    value: &'a str,
}

impl<'a> RegisteredPersonName<'a> {
    pub fn new(value: &'a str) -> Result<Self, RegisteredPersonNameError> {
        let normalized = canonical_registered_person_name(value);
        let scalar_count = normalized.chars().count();
        if scalar_count == 0 {
            return Err(RegisteredPersonNameError::Empty);
        }
        if scalar_count > 128 || normalized.chars().any(char::is_control) {
            return Err(RegisteredPersonNameError::Invalid);
        }
        Ok(Self { value })
    }
}

/// Returns the exact canonical name used by the closed publication scanner.
///
/// The value is intended only for ephemeral in-process matching. It carries no PERSON identifier
/// or identity-resolution evidence and must not be written to receipts, audit rows, or logs.
pub fn canonical_registered_person_name(value: &str) -> String {
    normalize_name(value)
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum RegisteredPersonNameError {
    #[error("registered PERSON name is empty after normalization")]
    Empty,
    #[error("registered PERSON name is outside the closed scanner input contract")]
    Invalid,
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum NaturalPersonFindingBasis {
    RegisteredPersonExact,
    TitleAdjacentKoreanName,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NaturalPersonFinding {
    pub path: String,
    pub start_utf16: usize,
    pub end_utf16: usize,
    pub basis: NaturalPersonFindingBasis,
    pub ruleset_version: &'static str,
}

impl NaturalPersonFinding {
    /// Scanner findings are publication blockers only, never identity-resolution evidence.
    pub const fn permits_identity_merge(&self) -> bool {
        false
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NaturalPersonAssessment {
    pub ruleset_version: &'static str,
    pub ruleset_sha256: String,
    pub public_text_sha256: String,
    pub findings: Vec<NaturalPersonFinding>,
}

impl NaturalPersonAssessment {
    pub fn blocks_publication_without_override(&self) -> bool {
        !self.findings.is_empty()
    }
}

#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum NaturalPersonScanError {
    #[error("public text object contains an empty field name at {path}")]
    EmptyFieldName { path: String },
    #[error("public text object contains a duplicate field at {path}")]
    DuplicateField { path: String },
}

pub fn natural_person_ruleset_sha256() -> String {
    let mut hasher = Sha256::new();
    update_part(&mut hasher, NATURAL_PERSON_RULESET_VERSION.as_bytes());
    update_part(&mut hasher, NORMALIZATION_VERSION.as_bytes());
    update_part(&mut hasher, TITLE_ADJACENCY_VERSION.as_bytes());
    for title in TITLE_LEXICON {
        update_part(&mut hasher, title.as_bytes());
    }
    finish_sha256(hasher)
}

pub fn public_text_sha256(root: &PublicTextNode<'_>) -> Result<String, NaturalPersonScanError> {
    let mut hasher = Sha256::new();
    hash_public_text_node(root, "", &mut hasher)?;
    Ok(finish_sha256(hasher))
}

pub fn scan_public_text(
    root: &PublicTextNode<'_>,
    registered_people: &[RegisteredPersonName<'_>],
) -> Result<NaturalPersonAssessment, NaturalPersonScanError> {
    let public_text_sha256 = public_text_sha256(root)?;
    let registered_names = registered_people
        .iter()
        .map(|person| canonical_registered_person_name(person.value))
        .collect::<BTreeSet<_>>();
    let mut findings = Vec::new();
    visit_text_leaves(root, "", &mut |path, text| {
        findings.extend(find_registered_people(path, text, &registered_names));
        findings.extend(find_title_adjacent_names(path, text));
    })?;
    findings.sort_by(|left, right| {
        (&left.path, left.start_utf16, left.end_utf16, left.basis).cmp(&(
            &right.path,
            right.start_utf16,
            right.end_utf16,
            right.basis,
        ))
    });
    findings.dedup_by(|left, right| {
        left.path == right.path
            && left.start_utf16 == right.start_utf16
            && left.end_utf16 == right.end_utf16
    });
    Ok(NaturalPersonAssessment {
        ruleset_version: NATURAL_PERSON_RULESET_VERSION,
        ruleset_sha256: natural_person_ruleset_sha256(),
        public_text_sha256,
        findings,
    })
}

fn visit_text_leaves(
    node: &PublicTextNode<'_>,
    path: &str,
    visitor: &mut impl FnMut(&str, &str),
) -> Result<(), NaturalPersonScanError> {
    match node {
        PublicTextNode::Text(text) => visitor(path, text),
        PublicTextNode::Object(fields) => {
            let mut names = BTreeSet::new();
            for (name, child) in fields {
                let child_path = join_pointer(path, name);
                if name.is_empty() {
                    return Err(NaturalPersonScanError::EmptyFieldName { path: child_path });
                }
                if !names.insert(*name) {
                    return Err(NaturalPersonScanError::DuplicateField { path: child_path });
                }
                visit_text_leaves(child, &child_path, visitor)?;
            }
        }
        PublicTextNode::Array(items) => {
            for (index, child) in items.iter().enumerate() {
                visit_text_leaves(child, &join_pointer(path, &index.to_string()), visitor)?;
            }
        }
    }
    Ok(())
}

fn hash_public_text_node(
    node: &PublicTextNode<'_>,
    path: &str,
    hasher: &mut Sha256,
) -> Result<(), NaturalPersonScanError> {
    match node {
        PublicTextNode::Text(text) => {
            hasher.update(b"T");
            update_part(hasher, text.as_bytes());
        }
        PublicTextNode::Object(fields) => {
            hasher.update(b"O");
            let mut ordered = fields.iter().collect::<Vec<_>>();
            ordered.sort_by_key(|(name, _)| *name);
            for adjacent in ordered.windows(2) {
                if adjacent[0].0 == adjacent[1].0 {
                    return Err(NaturalPersonScanError::DuplicateField {
                        path: join_pointer(path, adjacent[0].0),
                    });
                }
            }
            for (name, child) in ordered {
                if name.is_empty() {
                    return Err(NaturalPersonScanError::EmptyFieldName {
                        path: join_pointer(path, name),
                    });
                }
                update_part(hasher, name.as_bytes());
                hash_public_text_node(child, &join_pointer(path, name), hasher)?;
            }
        }
        PublicTextNode::Array(items) => {
            hasher.update(b"A");
            hasher.update((items.len() as u64).to_be_bytes());
            for (index, child) in items.iter().enumerate() {
                hash_public_text_node(child, &join_pointer(path, &index.to_string()), hasher)?;
            }
        }
    }
    Ok(())
}

fn join_pointer(parent: &str, segment: &str) -> String {
    let escaped = segment.replace('~', "~0").replace('/', "~1");
    format!("{parent}/{escaped}")
}

fn update_part(hasher: &mut Sha256, bytes: &[u8]) {
    hasher.update((bytes.len() as u64).to_be_bytes());
    hasher.update(bytes);
}

fn finish_sha256(hasher: Sha256) -> String {
    hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}
