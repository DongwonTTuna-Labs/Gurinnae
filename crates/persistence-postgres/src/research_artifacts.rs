#![forbid(unsafe_code)]

#[path = "research_artifact_rows.rs"]
mod research_artifact_rows;

use gurine_agent_orchestration::research::{
    ResearchArtifact, ResearchArtifactError, ResearchRedirect, ResearchRequestKind,
    ResearchSafeHeader, Sha256Digest,
};
use research_artifact_rows::{decode_artifact, decode_review_chain, digest, validate_runtime_tier};
use serde::{Deserialize, de::DeserializeOwned};
use sqlx::PgConnection;
use std::collections::BTreeMap;
use thiserror::Error;
use time::OffsetDateTime;
use url::Url;
use uuid::Uuid;

const MAX_CONTENT_BYTES: usize = 26_214_400;

#[derive(Debug, Error)]
pub enum ResearchArtifactRepositoryError {
    #[error("research artifact database operation failed")]
    Database(#[from] sqlx::Error),
    #[error("research artifact aggregate is invalid")]
    Aggregate(#[from] ResearchArtifactError),
    #[error("research artifact JSON metadata is invalid")]
    Json(#[from] serde_json::Error),
    #[error("research artifact write is invalid: {0}")]
    InvalidWrite(&'static str),
    #[error("research artifact owner returned an inconsistent identity")]
    OwnerReceiptMismatch,
}

/// Storage-bound command. Fetched bytes and the object key exist only at this
/// boundary; neither is copied into the domain aggregate or a provider-facing
/// result. The owner routine atomically writes the artifact, rights/source-use
/// lineage, and the initial OFFICIAL_UNREVIEWED receipt.
pub struct ResearchFetchWrite<'a> {
    pub request_kind: ResearchRequestKind,
    pub agent_run_id: Uuid,
    pub provider_turn_id: Uuid,
    pub tool_call_id: Uuid,
    pub call_id: &'a str,
    pub input_snapshot_sha256: Sha256Digest,
    pub source_id: &'a str,
    pub external_locator: &'a str,
    pub source_url_redacted: Option<&'a str>,
    pub final_url_redacted: Option<&'a str>,
    pub http_status: u16,
    pub content_media_type: Option<&'a str>,
    pub request_sha256: Sha256Digest,
    pub content: &'a [u8],
    pub object_key: &'a str,
    pub policy_version: &'a str,
    pub result_sha256: Sha256Digest,
    pub fetch_id: Uuid,
    pub asset_id: Uuid,
    pub artifact_id: Uuid,
    pub source_use_id: Uuid,
    pub source_use_sha256: Sha256Digest,
    pub content_safety_receipt_sha256: Sha256Digest,
    pub safe_headers: Vec<ResearchSafeHeader>,
    pub redirect_chain: Vec<ResearchRedirect>,
}

impl ResearchFetchWrite<'_> {
    fn validate(&self) -> Result<(), ResearchArtifactRepositoryError> {
        if [
            self.agent_run_id,
            self.provider_turn_id,
            self.tool_call_id,
            self.fetch_id,
            self.asset_id,
            self.artifact_id,
            self.source_use_id,
        ]
        .into_iter()
        .any(|id| id.is_nil())
        {
            return Err(ResearchArtifactRepositoryError::InvalidWrite("identifier"));
        }
        if !valid_call_id(self.call_id)
            || self.source_id.trim().is_empty()
            || self.source_id.len() > 255
            || self.external_locator.trim().is_empty()
            || self.object_key.trim().is_empty()
            || self.policy_version.trim().is_empty()
            || !(100..=599).contains(&self.http_status)
            || self.content.len() > MAX_CONTENT_BYTES
            || self
                .content_media_type
                .is_some_and(|value| !valid_media_type(value))
        {
            return Err(ResearchArtifactRepositoryError::InvalidWrite(
                "fetch metadata",
            ));
        }
        let url_shape_is_valid = match self.request_kind {
            ResearchRequestKind::FetchUrl => {
                self.source_url_redacted.is_some_and(is_https_uri)
                    && self.final_url_redacted.is_some_and(is_https_uri)
            }
            ResearchRequestKind::SearchPublicWeb => {
                self.source_url_redacted.is_none() && self.final_url_redacted.is_none()
            }
        };
        if !url_shape_is_valid {
            return Err(ResearchArtifactRepositoryError::InvalidWrite(
                "request kind URL shape",
            ));
        }
        if self.safe_headers.len() > 32
            || self.safe_headers.iter().any(|header| !header.is_valid())
            || self.redirect_chain.len() > 5
            || self
                .redirect_chain
                .iter()
                .enumerate()
                .any(|(index, redirect)| {
                    !redirect.is_valid() || usize::from(redirect.ordinal) != index + 1
                })
        {
            return Err(ResearchArtifactRepositoryError::InvalidWrite(
                "safe fetch metadata",
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct ResearchArtifactRepository;

impl ResearchArtifactRepository {
    pub const fn new() -> Self {
        Self
    }

    pub async fn insert_or_replay(
        &self,
        connection: &mut PgConnection,
        write: &ResearchFetchWrite<'_>,
    ) -> Result<ResearchArtifact, ResearchArtifactRepositoryError> {
        write.validate()?;
        if write.request_kind != ResearchRequestKind::FetchUrl {
            return Err(ResearchArtifactRepositoryError::InvalidWrite(
                "artifact write request kind",
            ));
        }
        let receipt = self
            .record_owner::<OwnerResearchFetchReceipt>(connection, write)
            .await?;
        if receipt.schema_version != "source.fetch.receipt.v2"
            || receipt.review_tier != "OFFICIAL_UNREVIEWED"
            || receipt.research_artifact_id != write.artifact_id
        {
            return Err(ResearchArtifactRepositoryError::OwnerReceiptMismatch);
        }
        self.get_by_id(connection, receipt.research_artifact_id)
            .await?
            .ok_or(ResearchArtifactRepositoryError::OwnerReceiptMismatch)
    }

    pub async fn record_discovery(
        &self,
        connection: &mut PgConnection,
        write: &ResearchFetchWrite<'_>,
    ) -> Result<ResearchDiscoveryReceipt, ResearchArtifactRepositoryError> {
        write.validate()?;
        if write.request_kind != ResearchRequestKind::SearchPublicWeb {
            return Err(ResearchArtifactRepositoryError::InvalidWrite(
                "discovery write request kind",
            ));
        }
        let receipt = self
            .record_owner::<OwnerDiscoveryReceipt>(connection, write)
            .await?;
        if receipt.schema_version != "source.fetch.receipt.v2"
            || !receipt.discovery_only
            || receipt.source_fetch_id != write.fetch_id
            || receipt.receipt_digest != write.content_safety_receipt_sha256
        {
            return Err(ResearchArtifactRepositoryError::OwnerReceiptMismatch);
        }
        Ok(ResearchDiscoveryReceipt {
            source_fetch_id: receipt.source_fetch_id,
            receipt_digest: receipt.receipt_digest,
        })
    }

    async fn record_owner<Receipt>(
        &self,
        connection: &mut PgConnection,
        write: &ResearchFetchWrite<'_>,
    ) -> Result<Receipt, ResearchArtifactRepositoryError>
    where
        Receipt: DeserializeOwned,
    {
        let request_kind = match write.request_kind {
            ResearchRequestKind::SearchPublicWeb => "SEARCH_PUBLIC_WEB",
            ResearchRequestKind::FetchUrl => "FETCH_URL",
        };
        let receipt = sqlx::query_scalar!(
            "SELECT ops.record_research_fetch_v1($1,$2,$3,$4,CAST($5 AS char(64)),$6,$7,$8,$9,$10,$11,$12,CAST($13 AS char(64)),$14,$15,$16,CAST($17 AS char(64)),$18,$19,$20,$21,$22,CAST($23 AS char(64)),$24,$25)",
            write.agent_run_id,
            write.provider_turn_id,
            write.tool_call_id,
            write.call_id,
            write.input_snapshot_sha256.as_str(),
            request_kind,
            write.source_id,
            write.external_locator,
            write.source_url_redacted,
            write.final_url_redacted,
            i32::from(write.http_status),
            write.content_media_type,
            write.request_sha256.as_str(),
            write.content,
            write.object_key,
            write.policy_version,
            write.result_sha256.as_str(),
            write.fetch_id,
            write.asset_id,
            write.artifact_id,
            write.source_use_id,
            write.source_use_sha256.as_str(),
            write.content_safety_receipt_sha256.as_str(),
            sqlx::types::Json(&write.safe_headers) as _,
            sqlx::types::Json(&write.redirect_chain) as _,
        )
        .fetch_one(&mut *connection)
        .await?
        .ok_or(ResearchArtifactRepositoryError::OwnerReceiptMismatch)?;
        serde_json::from_value(receipt).map_err(Into::into)
    }

    pub async fn get_by_id(
        &self,
        connection: &mut PgConnection,
        artifact_id: Uuid,
    ) -> Result<Option<ResearchArtifact>, ResearchArtifactRepositoryError> {
        if artifact_id.is_nil() {
            return Err(ResearchArtifactRepositoryError::InvalidWrite("artifact_id"));
        }
        let row = sqlx::query_as!(
            ArtifactDbRow,
            r#"SELECT id,asset_id,asset_revision,source_fetch_id,agent_run_id,
                      provider_turn_id,tool_call_id,call_id,artifact_ordinal,
                      input_snapshot_sha256,request_kind,request_sha256,result_sha256,
                      fetch_outcome,source_url_redacted,final_url_redacted,source_authority,
                      retrieved_at,http_status,content_media_type,content_size_bytes,
                      content_sha256,response_headers_sha256,artifact_sha256,object_key_hash,
                      safe_headers::text AS "safe_headers_json!",
                      redirect_chain::text AS "redirect_chain_json!",classification,
                      content_safety_state,content_safety_receipt_sha256,created_at
                 FROM raw.research_artifacts WHERE id=$1"#,
            artifact_id,
        )
        .fetch_optional(&mut *connection)
        .await?;
        let Some(row) = row else { return Ok(None) };
        let mut tiers = self.load_review_tiers(connection, &[artifact_id]).await?;
        Ok(Some(decode_artifact(
            row,
            tiers.remove(&artifact_id).unwrap_or_else(Vec::new),
        )?))
    }

    pub async fn list_for_call(
        &self,
        connection: &mut PgConnection,
        agent_run_id: Uuid,
        call_id: &str,
    ) -> Result<Vec<ResearchArtifact>, ResearchArtifactRepositoryError> {
        if agent_run_id.is_nil() || !valid_call_id(call_id) {
            return Err(ResearchArtifactRepositoryError::InvalidWrite(
                "call binding",
            ));
        }
        let rows = sqlx::query_as!(
            ArtifactDbRow,
            r#"SELECT id,asset_id,asset_revision,source_fetch_id,agent_run_id,
                      provider_turn_id,tool_call_id,call_id,artifact_ordinal,
                      input_snapshot_sha256,request_kind,request_sha256,result_sha256,
                      fetch_outcome,source_url_redacted,final_url_redacted,source_authority,
                      retrieved_at,http_status,content_media_type,content_size_bytes,
                      content_sha256,response_headers_sha256,artifact_sha256,object_key_hash,
                      safe_headers::text AS "safe_headers_json!",
                      redirect_chain::text AS "redirect_chain_json!",classification,
                      content_safety_state,content_safety_receipt_sha256,created_at
                 FROM raw.research_artifacts
                WHERE agent_run_id=$1 AND call_id=$2
                ORDER BY artifact_ordinal,id"#,
            agent_run_id,
            call_id,
        )
        .fetch_all(&mut *connection)
        .await?;
        let ids = rows.iter().map(|row| row.id).collect::<Vec<_>>();
        let mut tiers = self.load_review_tiers(connection, &ids).await?;
        rows.into_iter()
            .map(|row| {
                let tier_rows = tiers.remove(&row.id).unwrap_or_else(Vec::new);
                decode_artifact(row, tier_rows)
            })
            .collect()
    }

    pub async fn list_runtime_capsules(
        &self,
        connection: &mut PgConnection,
        agent_run_id: Uuid,
        input_snapshot_sha256: &Sha256Digest,
    ) -> Result<Vec<RuntimeResearchArtifactCapsule>, ResearchArtifactRepositoryError> {
        if agent_run_id.is_nil() {
            return Err(ResearchArtifactRepositoryError::InvalidWrite(
                "agent_run_id",
            ));
        }
        let rows = sqlx::query!(
            "SELECT r.id AS research_artifact_id,
                su.source_use_id,r.content_sha256,r.artifact_sha256,r.content_media_type,
                r.request_kind,r.source_url_redacted,r.final_url_redacted,r.object_key
           FROM raw.research_artifacts r
           JOIN LATERAL (
             SELECT source_use_id FROM ops.agent_source_uses
              WHERE agent_run_id=r.agent_run_id AND research_artifact_id=r.id
                AND use_kind='TOOL_RESULT'
              ORDER BY source_use_id LIMIT 1
           ) su ON true
          WHERE r.agent_run_id=$1 AND r.input_snapshot_sha256=CAST($2 AS char(64)) AND r.fetch_outcome='STORED'
          ORDER BY r.id",
            agent_run_id,
            input_snapshot_sha256.as_str(),
        )
        .fetch_all(&mut *connection)
        .await?;
        let ids = rows
            .iter()
            .map(|row| row.research_artifact_id)
            .collect::<Vec<_>>();
        let mut tiers = self.load_review_tiers(connection, &ids).await?;
        rows.into_iter()
            .map(|row| {
                let request_kind = ResearchRequestKind::parse(&row.request_kind)?;
                let chain = decode_review_chain(
                    tiers
                        .remove(&row.research_artifact_id)
                        .unwrap_or_else(Vec::new),
                )?;
                validate_runtime_tier(request_kind, chain.as_ref())?;
                Ok(RuntimeResearchArtifactCapsule {
                    research_artifact_id: row.research_artifact_id,
                    source_use_id: row.source_use_id,
                    content_sha256: digest(row.content_sha256)?,
                    artifact_sha256: digest(row.artifact_sha256)?,
                    content_media_type: row.content_media_type,
                    request_kind,
                    source_url_redacted: row.source_url_redacted,
                    final_url_redacted: row.final_url_redacted,
                    object_key: row.object_key,
                })
            })
            .collect()
    }

    async fn load_review_tiers(
        &self,
        connection: &mut PgConnection,
        artifact_ids: &[Uuid],
    ) -> Result<BTreeMap<Uuid, Vec<ReviewTierDbRow>>, ResearchArtifactRepositoryError> {
        if artifact_ids.is_empty() {
            return Ok(BTreeMap::new());
        }
        let rows = sqlx::query_as!(
            ReviewTierDbRow,
            r#"SELECT tier_id,research_artifact_id,research_asset_id,
                      research_asset_revision,research_artifact_sha256,
                      research_content_sha256,revision,review_tier,
                      reviewed_classification,predecessor_revision,
                      predecessor_receipt_sha256,source_use_agent_run_id,source_use_id,
                      source_use_sha256,source_locator_digest,
                      official_source_registry_digest,promotion_id,
                      promotion_receipt_sha256,reviewed_by,reviewed_at,
                      receipt_sha256,created_at
                 FROM raw.research_artifact_review_tiers
                WHERE research_artifact_id=ANY($1::uuid[])
                ORDER BY research_artifact_id,revision"#,
            artifact_ids,
        )
        .fetch_all(&mut *connection)
        .await?;
        let mut grouped = BTreeMap::<Uuid, Vec<ReviewTierDbRow>>::new();
        for row in rows {
            grouped
                .entry(row.research_artifact_id)
                .or_default()
                .push(row);
        }
        Ok(grouped)
    }
}

struct ArtifactDbRow {
    id: Uuid,
    asset_id: Uuid,
    asset_revision: i64,
    source_fetch_id: Uuid,
    agent_run_id: Uuid,
    provider_turn_id: Uuid,
    tool_call_id: Uuid,
    call_id: String,
    artifact_ordinal: i32,
    input_snapshot_sha256: String,
    request_kind: String,
    request_sha256: String,
    result_sha256: String,
    fetch_outcome: String,
    source_url_redacted: Option<String>,
    final_url_redacted: Option<String>,
    source_authority: String,
    retrieved_at: OffsetDateTime,
    http_status: i32,
    content_media_type: String,
    content_size_bytes: i64,
    content_sha256: String,
    response_headers_sha256: String,
    artifact_sha256: String,
    object_key_hash: String,
    safe_headers_json: String,
    redirect_chain_json: String,
    classification: String,
    content_safety_state: String,
    content_safety_receipt_sha256: String,
    created_at: OffsetDateTime,
}

/// Private-object-store handle used only while materializing a trusted tool
/// snapshot. This type is intentionally not serializable.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeResearchArtifactCapsule {
    pub research_artifact_id: Uuid,
    pub source_use_id: Uuid,
    pub content_sha256: Sha256Digest,
    pub artifact_sha256: Sha256Digest,
    pub content_media_type: String,
    pub request_kind: ResearchRequestKind,
    pub source_url_redacted: Option<String>,
    pub final_url_redacted: Option<String>,
    pub object_key: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResearchDiscoveryReceipt {
    pub source_fetch_id: Uuid,
    pub receipt_digest: Sha256Digest,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OwnerResearchFetchReceipt {
    schema_version: String,
    research_artifact_id: Uuid,
    review_tier: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OwnerDiscoveryReceipt {
    schema_version: String,
    source_fetch_id: Uuid,
    receipt_digest: Sha256Digest,
    discovery_only: bool,
}

struct ReviewTierDbRow {
    tier_id: Uuid,
    research_artifact_id: Uuid,
    research_asset_id: Uuid,
    research_asset_revision: i64,
    research_artifact_sha256: String,
    research_content_sha256: String,
    revision: i64,
    review_tier: String,
    reviewed_classification: String,
    predecessor_revision: Option<i64>,
    predecessor_receipt_sha256: Option<String>,
    source_use_agent_run_id: Option<Uuid>,
    source_use_id: Option<Uuid>,
    source_use_sha256: Option<String>,
    source_locator_digest: String,
    official_source_registry_digest: String,
    promotion_id: Option<Uuid>,
    promotion_receipt_sha256: Option<String>,
    reviewed_by: Option<Uuid>,
    reviewed_at: Option<OffsetDateTime>,
    receipt_sha256: String,
    created_at: OffsetDateTime,
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

fn is_https_uri(value: &str) -> bool {
    Url::parse(value).is_ok_and(|url| url.scheme() == "https" && url.host().is_some())
}

#[cfg(test)]
mod tests {
    #[test]
    fn review_tier_relation_is_read_only_in_repository() {
        let source = include_str!("research_artifacts.rs");
        for verb in ["INSERT INTO", "UPDATE", "DELETE FROM"] {
            let forbidden = format!("{verb} raw.{}", "research_artifact_review_tiers");
            assert!(!source.contains(&forbidden));
        }
        assert!(source.contains(&["ops.", "record_research_fetch_v1"].concat()));
    }
}
