#![forbid(unsafe_code)]

use super::{ArtifactDbRow, ResearchArtifactRepositoryError, ReviewTierDbRow};
use gurine_agent_orchestration::research::{
    ContentSafetyState, HumanPromotedTier, OfficialUnreviewedTier, PromotionBinding,
    ResearchArtifact, ResearchArtifactBinding, ResearchArtifactError, ResearchArtifactRecord,
    ResearchClassification, ResearchFetchOutcome, ResearchRequestKind, ReviewSourceUseBinding,
    ReviewTierChain, Sha256Digest,
};

pub(super) fn decode_artifact(
    row: ArtifactDbRow,
    tier_rows: Vec<ReviewTierDbRow>,
) -> Result<ResearchArtifact, ResearchArtifactRepositoryError> {
    let record = ResearchArtifactRecord {
        id: row.id,
        asset_id: row.asset_id,
        asset_revision: unsigned(row.asset_revision, "asset_revision")?,
        source_fetch_id: row.source_fetch_id,
        agent_run_id: row.agent_run_id,
        provider_turn_id: row.provider_turn_id,
        tool_call_id: row.tool_call_id,
        call_id: row.call_id,
        artifact_ordinal: u32::try_from(row.artifact_ordinal)
            .map_err(|_| ResearchArtifactError::InvalidField("artifact_ordinal"))?,
        input_snapshot_sha256: digest(row.input_snapshot_sha256)?,
        request_kind: ResearchRequestKind::parse(&row.request_kind)?,
        request_sha256: digest(row.request_sha256)?,
        result_sha256: digest(row.result_sha256)?,
        fetch_outcome: ResearchFetchOutcome::parse(&row.fetch_outcome)?,
        source_url_redacted: row.source_url_redacted,
        final_url_redacted: row.final_url_redacted,
        source_authority: row.source_authority,
        retrieved_at: row.retrieved_at,
        http_status: u16::try_from(row.http_status)
            .map_err(|_| ResearchArtifactError::InvalidField("http_status"))?,
        content_media_type: row.content_media_type,
        content_size_bytes: unsigned(row.content_size_bytes, "content_size_bytes")?,
        content_sha256: digest(row.content_sha256)?,
        response_headers_sha256: digest(row.response_headers_sha256)?,
        artifact_sha256: digest(row.artifact_sha256)?,
        object_key_hash: digest(row.object_key_hash)?,
        safe_headers: serde_json::from_str(&row.safe_headers_json)?,
        redirect_chain: serde_json::from_str(&row.redirect_chain_json)?,
        classification: ResearchClassification::parse(&row.classification)?,
        content_safety_state: ContentSafetyState::parse(&row.content_safety_state)?,
        content_safety_receipt_sha256: digest(row.content_safety_receipt_sha256)?,
        created_at: row.created_at,
    };
    ResearchArtifact::from_record(record, decode_review_chain(tier_rows)?).map_err(Into::into)
}

pub(super) fn decode_review_chain(
    rows: Vec<ReviewTierDbRow>,
) -> Result<Option<ReviewTierChain>, ResearchArtifactRepositoryError> {
    let mut rows = rows.into_iter();
    let Some(initial_row) = rows.next() else {
        return Ok(None);
    };
    let initial = decode_initial_tier(initial_row)?;
    let promoted = rows
        .next()
        .map(|row| decode_promoted_tier(row, &initial))
        .transpose()?;
    if rows.next().is_some() {
        return Err(ResearchArtifactError::InvalidReviewChain("more than two revisions").into());
    }
    Ok(Some(ReviewTierChain::new(initial, promoted)?))
}

pub(super) fn validate_runtime_tier(
    request_kind: ResearchRequestKind,
    chain: Option<&ReviewTierChain>,
) -> Result<(), ResearchArtifactRepositoryError> {
    let valid = match request_kind {
        ResearchRequestKind::FetchUrl => chain.is_some_and(|value| !value.is_human_promoted()),
        ResearchRequestKind::SearchPublicWeb => chain.is_none(),
    };
    if valid {
        Ok(())
    } else {
        Err(
            ResearchArtifactError::InvalidReviewChain("runtime capsule tier is not eligible")
                .into(),
        )
    }
}

fn decode_initial_tier(
    row: ReviewTierDbRow,
) -> Result<OfficialUnreviewedTier, ResearchArtifactRepositoryError> {
    if row.revision != 1
        || row.review_tier != "OFFICIAL_UNREVIEWED"
        || row.reviewed_classification != "RESTRICTED"
        || row.predecessor_revision.is_some()
        || row.predecessor_receipt_sha256.is_some()
        || row.source_use_agent_run_id.is_some()
        || row.source_use_id.is_some()
        || row.source_use_sha256.is_some()
        || row.promotion_id.is_some()
        || row.promotion_receipt_sha256.is_some()
        || row.reviewed_by.is_some()
        || row.reviewed_at.is_some()
    {
        return Err(ResearchArtifactError::InvalidReviewChain("invalid revision one").into());
    }
    OfficialUnreviewedTier::new(
        row.tier_id,
        tier_binding(&row)?,
        digest(row.source_locator_digest)?,
        digest(row.official_source_registry_digest)?,
        digest(row.receipt_sha256)?,
        row.created_at,
    )
    .map_err(Into::into)
}

fn decode_promoted_tier(
    row: ReviewTierDbRow,
    initial: &OfficialUnreviewedTier,
) -> Result<HumanPromotedTier, ResearchArtifactRepositoryError> {
    if row.revision != 2 || row.review_tier != "HUMAN_PROMOTED" {
        return Err(ResearchArtifactError::InvalidReviewChain("invalid revision two").into());
    }
    if required(row.predecessor_revision, "predecessor_revision")? != 1 {
        return Err(
            ResearchArtifactError::InvalidReviewChain("invalid predecessor revision").into(),
        );
    }
    let binding = tier_binding(&row)?;
    if &binding != initial.binding() {
        return Err(ResearchArtifactError::InvalidReviewChain(
            "promotion artifact binding changed",
        )
        .into());
    }
    HumanPromotedTier::new(
        row.tier_id,
        binding,
        ResearchClassification::parse(&row.reviewed_classification)?,
        digest(required(
            row.predecessor_receipt_sha256,
            "predecessor_receipt_sha256",
        )?)?,
        ReviewSourceUseBinding {
            agent_run_id: required(row.source_use_agent_run_id, "source_use_agent_run_id")?,
            source_use_id: required(row.source_use_id, "source_use_id")?,
            source_use_sha256: digest(required(row.source_use_sha256, "source_use_sha256")?)?,
        },
        digest(row.source_locator_digest)?,
        digest(row.official_source_registry_digest)?,
        PromotionBinding {
            promotion_id: required(row.promotion_id, "promotion_id")?,
            promotion_receipt_sha256: digest(required(
                row.promotion_receipt_sha256,
                "promotion_receipt_sha256",
            )?)?,
            reviewed_by: required(row.reviewed_by, "reviewed_by")?,
            reviewed_at: required(row.reviewed_at, "reviewed_at")?,
        },
        digest(row.receipt_sha256)?,
        row.created_at,
    )
    .map_err(Into::into)
}

fn tier_binding(row: &ReviewTierDbRow) -> Result<ResearchArtifactBinding, ResearchArtifactError> {
    Ok(ResearchArtifactBinding {
        research_artifact_id: row.research_artifact_id,
        asset_id: row.research_asset_id,
        asset_revision: unsigned(row.research_asset_revision, "asset_revision")?,
        artifact_sha256: digest(row.research_artifact_sha256.clone())?,
        content_sha256: digest(row.research_content_sha256.clone())?,
    })
}

pub(super) fn digest(value: String) -> Result<Sha256Digest, ResearchArtifactError> {
    Sha256Digest::parse(value)
}

fn unsigned(value: i64, field: &'static str) -> Result<u64, ResearchArtifactError> {
    u64::try_from(value).map_err(|_| ResearchArtifactError::InvalidField(field))
}

fn required<T>(
    value: Option<T>,
    field: &'static str,
) -> Result<T, ResearchArtifactRepositoryError> {
    value.ok_or_else(|| ResearchArtifactError::InvalidReviewChain(field).into())
}
