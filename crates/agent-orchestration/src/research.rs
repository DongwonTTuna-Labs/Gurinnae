#![forbid(unsafe_code)]

use serde::{Deserialize, Deserializer, Serialize};
use std::collections::BTreeSet;
use thiserror::Error;
use time::OffsetDateTime;
use url::Url;
use uuid::Uuid;

const MAX_CONTENT_BYTES: u64 = 26_214_400;

#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum ResearchArtifactError {
    #[error("invalid SHA-256 digest")]
    InvalidDigest,
    #[error("invalid research artifact identifier")]
    InvalidIdentifier,
    #[error("invalid research artifact field: {0}")]
    InvalidField(&'static str),
    #[error("invalid research artifact review-tier chain: {0}")]
    InvalidReviewChain(&'static str),
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(transparent)]
pub struct Sha256Digest(String);

impl Sha256Digest {
    pub fn parse(value: impl Into<String>) -> Result<Self, ResearchArtifactError> {
        let value = value.into();
        if value.len() == 64
            && value
                .bytes()
                .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
        {
            Ok(Self(value))
        } else {
            Err(ResearchArtifactError::InvalidDigest)
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl<'de> Deserialize<'de> for Sha256Digest {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        Self::parse(String::deserialize(deserializer)?)
            .map_err(|_| serde::de::Error::custom("expected lowercase SHA-256"))
    }
}

macro_rules! closed_enum {
    ($name:ident, $field:literal, {$($wire:literal => $variant:ident),+ $(,)?}) => {
        #[derive(Clone, Copy, Debug, Eq, PartialEq)]
        pub enum $name { $($variant),+ }
        impl $name {
            pub fn parse(value: &str) -> Result<Self, ResearchArtifactError> {
                match value {
                    $($wire => Ok(Self::$variant),)+
                    _ => Err(ResearchArtifactError::InvalidField($field)),
                }
            }
        }
    };
}

closed_enum!(ResearchRequestKind, "request_kind", {
    "SEARCH_PUBLIC_WEB" => SearchPublicWeb,
    "FETCH_URL" => FetchUrl,
});
closed_enum!(ResearchFetchOutcome, "fetch_outcome", {
    "STORED" => Stored,
    "RENDER_REQUIRED" => RenderRequired,
    "QUARANTINED" => Quarantined,
});
closed_enum!(ResearchClassification, "classification", {
    "PUBLIC" => Public,
    "INTERNAL" => Internal,
    "RESTRICTED" => Restricted,
    "PERSONAL_DATA" => PersonalData,
    "LEGAL_HOLD" => LegalHold,
});
closed_enum!(ContentSafetyState, "content_safety_state", {
    "CLEAN" => Clean,
    "FLAGGED" => Flagged,
    "QUARANTINED" => Quarantined,
});

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum ResearchSafeHeaderName {
    #[serde(rename = "content-type")]
    ContentType,
    #[serde(rename = "content-length")]
    ContentLength,
    #[serde(rename = "content-language")]
    ContentLanguage,
    #[serde(rename = "etag")]
    Etag,
    #[serde(rename = "last-modified")]
    LastModified,
    #[serde(rename = "cache-control")]
    CacheControl,
    #[serde(rename = "date")]
    Date,
    #[serde(rename = "location")]
    Location,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ResearchSafeHeader {
    pub name: ResearchSafeHeaderName,
    pub value_sha256: Sha256Digest,
    pub safe_value: Option<String>,
}

impl ResearchSafeHeader {
    pub fn is_valid(&self) -> bool {
        self.safe_value
            .as_ref()
            .is_none_or(|value| value.len() <= 512)
            && (self.name != ResearchSafeHeaderName::Location || self.safe_value.is_none())
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ResearchRedirect {
    pub ordinal: u8,
    pub from_origin: String,
    pub to_origin: String,
    pub status: u16,
    pub dns_decision_sha256: Sha256Digest,
    pub policy_decision_sha256: Sha256Digest,
}

impl ResearchRedirect {
    pub fn is_valid(&self) -> bool {
        (1..=5).contains(&self.ordinal)
            && matches!(self.status, 301 | 302 | 303 | 307 | 308)
            && is_http_uri(&self.from_origin)
            && is_http_uri(&self.to_origin)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResearchArtifactBinding {
    pub research_artifact_id: Uuid,
    pub asset_id: Uuid,
    pub asset_revision: u64,
    pub artifact_sha256: Sha256Digest,
    pub content_sha256: Sha256Digest,
}

impl ResearchArtifactBinding {
    fn is_valid(&self) -> bool {
        !self.research_artifact_id.is_nil() && !self.asset_id.is_nil() && self.asset_revision == 1
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OfficialUnreviewedTier {
    tier_id: Uuid,
    binding: ResearchArtifactBinding,
    source_locator_digest: Sha256Digest,
    official_source_registry_digest: Sha256Digest,
    receipt_sha256: Sha256Digest,
    created_at: OffsetDateTime,
}

impl OfficialUnreviewedTier {
    pub fn new(
        tier_id: Uuid,
        binding: ResearchArtifactBinding,
        source_locator_digest: Sha256Digest,
        official_source_registry_digest: Sha256Digest,
        receipt_sha256: Sha256Digest,
        created_at: OffsetDateTime,
    ) -> Result<Self, ResearchArtifactError> {
        if tier_id.is_nil() || !binding.is_valid() {
            return Err(ResearchArtifactError::InvalidIdentifier);
        }
        Ok(Self {
            tier_id,
            binding,
            source_locator_digest,
            official_source_registry_digest,
            receipt_sha256,
            created_at,
        })
    }

    pub fn receipt_sha256(&self) -> &Sha256Digest {
        &self.receipt_sha256
    }

    pub fn binding(&self) -> &ResearchArtifactBinding {
        &self.binding
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ReviewSourceUseBinding {
    pub agent_run_id: Uuid,
    pub source_use_id: Uuid,
    pub source_use_sha256: Sha256Digest,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PromotionBinding {
    pub promotion_id: Uuid,
    pub promotion_receipt_sha256: Sha256Digest,
    pub reviewed_by: Uuid,
    pub reviewed_at: OffsetDateTime,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HumanPromotedTier {
    tier_id: Uuid,
    binding: ResearchArtifactBinding,
    reviewed_classification: ResearchClassification,
    predecessor_receipt_sha256: Sha256Digest,
    source_use: ReviewSourceUseBinding,
    source_locator_digest: Sha256Digest,
    official_source_registry_digest: Sha256Digest,
    promotion: PromotionBinding,
    receipt_sha256: Sha256Digest,
    created_at: OffsetDateTime,
}

impl HumanPromotedTier {
    #[expect(
        clippy::too_many_arguments,
        reason = "the immutable receipt binds each independent provenance root"
    )]
    pub fn new(
        tier_id: Uuid,
        binding: ResearchArtifactBinding,
        reviewed_classification: ResearchClassification,
        predecessor_receipt_sha256: Sha256Digest,
        source_use: ReviewSourceUseBinding,
        source_locator_digest: Sha256Digest,
        official_source_registry_digest: Sha256Digest,
        promotion: PromotionBinding,
        receipt_sha256: Sha256Digest,
        created_at: OffsetDateTime,
    ) -> Result<Self, ResearchArtifactError> {
        if tier_id.is_nil()
            || !binding.is_valid()
            || source_use.agent_run_id.is_nil()
            || source_use.source_use_id.is_nil()
            || promotion.promotion_id.is_nil()
            || promotion.reviewed_by.is_nil()
        {
            return Err(ResearchArtifactError::InvalidIdentifier);
        }
        Ok(Self {
            tier_id,
            binding,
            reviewed_classification,
            predecessor_receipt_sha256,
            source_use,
            source_locator_digest,
            official_source_registry_digest,
            promotion,
            receipt_sha256,
            created_at,
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ReviewTierChain {
    initial: OfficialUnreviewedTier,
    promoted: Option<HumanPromotedTier>,
}

impl ReviewTierChain {
    pub fn new(
        initial: OfficialUnreviewedTier,
        promoted: Option<HumanPromotedTier>,
    ) -> Result<Self, ResearchArtifactError> {
        if let Some(current) = &promoted {
            if current.binding != initial.binding
                || current.predecessor_receipt_sha256 != initial.receipt_sha256
                || current.source_locator_digest != initial.source_locator_digest
                || current.official_source_registry_digest
                    != initial.official_source_registry_digest
                || current.created_at < initial.created_at
                || current.promotion.reviewed_at > current.created_at
            {
                return Err(ResearchArtifactError::InvalidReviewChain(
                    "promotion does not bind the initial receipt",
                ));
            }
        }
        Ok(Self { initial, promoted })
    }

    pub fn current_classification(&self) -> ResearchClassification {
        self.promoted
            .as_ref()
            .map_or(ResearchClassification::Restricted, |tier| {
                tier.reviewed_classification
            })
    }

    pub fn current_receipt_sha256(&self) -> &Sha256Digest {
        self.promoted
            .as_ref()
            .map_or_else(|| &self.initial.receipt_sha256, |tier| &tier.receipt_sha256)
    }

    pub fn is_human_promoted(&self) -> bool {
        self.promoted.is_some()
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResearchArtifactRecord {
    pub id: Uuid,
    pub asset_id: Uuid,
    pub asset_revision: u64,
    pub source_fetch_id: Uuid,
    pub agent_run_id: Uuid,
    pub provider_turn_id: Uuid,
    pub tool_call_id: Uuid,
    pub call_id: String,
    pub artifact_ordinal: u32,
    pub input_snapshot_sha256: Sha256Digest,
    pub request_kind: ResearchRequestKind,
    pub request_sha256: Sha256Digest,
    pub result_sha256: Sha256Digest,
    pub fetch_outcome: ResearchFetchOutcome,
    pub source_url_redacted: Option<String>,
    pub final_url_redacted: Option<String>,
    pub source_authority: String,
    pub retrieved_at: OffsetDateTime,
    pub http_status: u16,
    pub content_media_type: String,
    pub content_size_bytes: u64,
    pub content_sha256: Sha256Digest,
    pub response_headers_sha256: Sha256Digest,
    pub artifact_sha256: Sha256Digest,
    pub object_key_hash: Sha256Digest,
    pub safe_headers: Vec<ResearchSafeHeader>,
    pub redirect_chain: Vec<ResearchRedirect>,
    pub classification: ResearchClassification,
    pub content_safety_state: ContentSafetyState,
    pub content_safety_receipt_sha256: Sha256Digest,
    pub created_at: OffsetDateTime,
}

/// Safe aggregate projection. Raw fetched bytes, object keys, canonical receipt
/// payloads, snippets, person attributes, and provider responses are not part
/// of this type and therefore cannot be serialized through it by accident.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResearchArtifact {
    record: ResearchArtifactRecord,
    review_tiers: Option<ReviewTierChain>,
}

impl ResearchArtifact {
    pub fn from_record(
        record: ResearchArtifactRecord,
        review_tiers: Option<ReviewTierChain>,
    ) -> Result<Self, ResearchArtifactError> {
        validate_record(&record)?;
        match record.request_kind {
            ResearchRequestKind::FetchUrl => {
                let chain =
                    review_tiers
                        .as_ref()
                        .ok_or(ResearchArtifactError::InvalidReviewChain(
                            "FETCH_URL has no review receipt",
                        ))?;
                if record.classification != ResearchClassification::Restricted
                    || chain.initial.binding
                        != (ResearchArtifactBinding {
                            research_artifact_id: record.id,
                            asset_id: record.asset_id,
                            asset_revision: record.asset_revision,
                            artifact_sha256: record.artifact_sha256.clone(),
                            content_sha256: record.content_sha256.clone(),
                        })
                {
                    return Err(ResearchArtifactError::InvalidReviewChain(
                        "artifact and review receipt bindings differ",
                    ));
                }
            }
            ResearchRequestKind::SearchPublicWeb if review_tiers.is_some() => {
                return Err(ResearchArtifactError::InvalidReviewChain(
                    "legacy discovery artifact cannot carry a review tier",
                ));
            }
            ResearchRequestKind::SearchPublicWeb => {}
        }
        Ok(Self {
            record,
            review_tiers,
        })
    }

    pub fn id(&self) -> Uuid {
        self.record.id
    }

    pub fn artifact_sha256(&self) -> &Sha256Digest {
        &self.record.artifact_sha256
    }

    pub fn review_tiers(&self) -> Option<&ReviewTierChain> {
        self.review_tiers.as_ref()
    }
}

fn validate_record(record: &ResearchArtifactRecord) -> Result<(), ResearchArtifactError> {
    if [
        record.id,
        record.asset_id,
        record.source_fetch_id,
        record.agent_run_id,
        record.provider_turn_id,
        record.tool_call_id,
    ]
    .into_iter()
    .any(|id| id.is_nil())
        || record.asset_revision != 1
    {
        return Err(ResearchArtifactError::InvalidIdentifier);
    }
    if !valid_call_id(&record.call_id) {
        return Err(ResearchArtifactError::InvalidField("call_id"));
    }
    if !(100..=599).contains(&record.http_status)
        || record.content_size_bytes > MAX_CONTENT_BYTES
        || !valid_media_type(&record.content_media_type)
        || record.source_authority.trim().is_empty()
        || record.source_authority.len() > 255
    {
        return Err(ResearchArtifactError::InvalidField("fetch_metadata"));
    }
    if record
        .source_url_redacted
        .as_deref()
        .is_some_and(|value| !is_http_uri(value))
        || record
            .final_url_redacted
            .as_deref()
            .is_some_and(|value| !is_http_uri(value))
        || record.request_kind == ResearchRequestKind::FetchUrl
            && (!record
                .source_url_redacted
                .as_deref()
                .is_some_and(is_https_uri)
                || !record
                    .final_url_redacted
                    .as_deref()
                    .is_some_and(is_https_uri))
    {
        return Err(ResearchArtifactError::InvalidField("redacted_url"));
    }
    if record.fetch_outcome == ResearchFetchOutcome::RenderRequired
        && record.content_media_type != "text/html"
    {
        return Err(ResearchArtifactError::InvalidField("render_media_type"));
    }
    if record.safe_headers.len() > 32 || record.safe_headers.iter().any(|item| !item.is_valid()) {
        return Err(ResearchArtifactError::InvalidField("safe_headers"));
    }
    let ordinals = record
        .redirect_chain
        .iter()
        .map(|redirect| redirect.ordinal)
        .collect::<BTreeSet<_>>();
    if record.redirect_chain.len() > 5
        || record.redirect_chain.iter().any(|item| !item.is_valid())
        || !record
            .redirect_chain
            .iter()
            .enumerate()
            .all(|(index, item)| usize::from(item.ordinal) == index + 1)
        || ordinals.len() != record.redirect_chain.len()
    {
        return Err(ResearchArtifactError::InvalidField("redirect_chain"));
    }
    Ok(())
}

fn valid_call_id(value: &str) -> bool {
    let mut bytes = value.bytes();
    matches!(bytes.next(), Some(byte) if byte.is_ascii_alphanumeric())
        && value.len() <= 64
        && bytes.all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

fn valid_media_type(value: &str) -> bool {
    let Some((kind, subtype)) = value.split_once('/') else {
        return false;
    };
    !kind.is_empty()
        && !subtype.is_empty()
        && !subtype.contains('/')
        && value.bytes().all(|byte| {
            byte.is_ascii_lowercase()
                || byte.is_ascii_digit()
                || matches!(
                    byte,
                    b'!' | b'#' | b'$' | b'&' | b'^' | b'_' | b'.' | b'+' | b'-' | b'/'
                )
        })
}

fn is_http_uri(value: &str) -> bool {
    Url::parse(value)
        .is_ok_and(|url| matches!(url.scheme(), "http" | "https") && url.host().is_some())
}

fn is_https_uri(value: &str) -> bool {
    Url::parse(value).is_ok_and(|url| url.scheme() == "https" && url.host().is_some())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn digest(character: char) -> Sha256Digest {
        Sha256Digest::parse(character.to_string().repeat(64)).expect("test digest")
    }

    fn binding() -> ResearchArtifactBinding {
        ResearchArtifactBinding {
            research_artifact_id: Uuid::from_u128(1),
            asset_id: Uuid::from_u128(2),
            asset_revision: 1,
            artifact_sha256: digest('a'),
            content_sha256: digest('b'),
        }
    }

    fn initial() -> OfficialUnreviewedTier {
        OfficialUnreviewedTier::new(
            Uuid::from_u128(3),
            binding(),
            digest('c'),
            digest('d'),
            digest('e'),
            OffsetDateTime::UNIX_EPOCH,
        )
        .expect("initial tier")
    }

    #[test]
    fn digest_is_lowercase_and_closed() {
        assert!(Sha256Digest::parse("a".repeat(64)).is_ok());
        assert!(Sha256Digest::parse("A".repeat(64)).is_err());
        assert!(Sha256Digest::parse("a".repeat(63)).is_err());
    }

    #[test]
    fn promoted_tier_must_bind_initial_receipt_and_human() {
        let first = initial();
        let promoted = HumanPromotedTier::new(
            Uuid::from_u128(4),
            binding(),
            ResearchClassification::Public,
            first.receipt_sha256().clone(),
            ReviewSourceUseBinding {
                agent_run_id: Uuid::from_u128(5),
                source_use_id: Uuid::from_u128(6),
                source_use_sha256: digest('f'),
            },
            digest('c'),
            digest('d'),
            PromotionBinding {
                promotion_id: Uuid::from_u128(7),
                promotion_receipt_sha256: digest('1'),
                reviewed_by: Uuid::from_u128(8),
                reviewed_at: OffsetDateTime::UNIX_EPOCH,
            },
            digest('2'),
            OffsetDateTime::UNIX_EPOCH,
        )
        .expect("promoted tier");
        let mut mismatched = promoted.clone();
        mismatched.predecessor_receipt_sha256 = digest('9');
        assert!(ReviewTierChain::new(first.clone(), Some(mismatched)).is_err());
        let chain = ReviewTierChain::new(first, Some(promoted)).expect("valid chain");
        assert!(chain.is_human_promoted());
        assert!(chain.current_classification() == ResearchClassification::Public);
    }
}
