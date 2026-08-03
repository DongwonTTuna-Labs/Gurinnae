use super::*;

pub(super) async fn arm_createretractiondraft(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let publication =
        uuid_value(payload, &["publicationId"]).ok_or(ServiceError::InvalidRequest)?;
    let scope = match string_value(payload, "scope") {
        Some("full") | Some("FULL") => "FULL",
        Some("partial") | Some("PARTIAL") => "PARTIAL",
        _ => return Err(ServiceError::InvalidRequest),
    };
    let exists: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM editorial.publication_revisions WHERE id=$1)",
    )
    .bind(publication)
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?;
    if !exists {
        return Err(ServiceError::NotFound);
    }
    sqlx::query(
        "INSERT INTO editorial.retraction_drafts(id,publication_revision_id,scope, \
         affected_claim_ids,reason,status,created_by) VALUES($1,$2,$3,$4,$5,'DRAFT',$6)",
    )
    .bind(id)
    .bind(publication)
    .bind(scope)
    .bind(
        payload
            .get("affectedClaimIds")
            .cloned()
            .unwrap_or_else(|| json!([])),
    )
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_previewpublication(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
    let snapshot =
        uuid_value(payload, &["reviewSnapshotId"]).ok_or(ServiceError::InvalidRequest)?;
    let public_payload = publication_payload(case_id, snapshot, tx).await?;
    let digest =
        sha256(&serde_json::to_vec(&public_payload).map_err(|_| ServiceError::Persistence)?);
    sqlx::query(
        "INSERT INTO editorial.publication_previews(id,case_id,review_snapshot_id,locale, \
         preview_payload,preview_sha256,expires_at,created_by) \
         VALUES($1,$2,$3,$4,$5,$6,clock_timestamp()+interval '15 minutes',$7)",
    )
    .bind(id)
    .bind(case_id)
    .bind(snapshot)
    .bind(string_value(payload, "locale").ok_or(ServiceError::InvalidRequest)?)
    .bind(public_payload)
    .bind(digest)
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_publishcase(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
    let snapshot =
        uuid_value(payload, &["reviewSnapshotId"]).ok_or(ServiceError::InvalidRequest)?;
    let preview_hash = string_value(payload, "previewHash")
        .filter(|value| value.len() == 64)
        .ok_or(ServiceError::InvalidRequest)?;
    let snapshot_row = sqlx::query(
        "SELECT s.created_by,s.unresolved_blockers,c.current_review_snapshot_id, \
         c.legal_review_required,EXISTS(SELECT 1 FROM ops.kill_switches \
           WHERE state='ACTIVE' AND (expires_at IS NULL OR expires_at>clock_timestamp())) kill_switch \
         FROM editorial.review_snapshots s JOIN editorial.cases c ON c.id=s.case_id \
         WHERE s.id=$1 AND s.case_id=$2",
    )
    .bind(snapshot)
    .bind(case_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    let snapshot_creator: Uuid = snapshot_row.try_get("created_by").map_err(db)?;
    let unresolved: Value = snapshot_row.try_get("unresolved_blockers").map_err(db)?;
    let current: Option<Uuid> = snapshot_row
        .try_get("current_review_snapshot_id")
        .map_err(db)?;
    let legal_required: bool = snapshot_row.try_get("legal_review_required").map_err(db)?;
    let kill_switch: bool = snapshot_row.try_get("kill_switch").map_err(db)?;
    if current != Some(snapshot) || !unresolved.as_array().is_some_and(Vec::is_empty) || kill_switch
    {
        return Err(ServiceError::InvalidRequest);
    }
    let approval: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM editorial.review_decisions \
         WHERE review_snapshot_id=$1 AND decision='APPROVE' AND reviewer_id<>$2) \
         AND (NOT $3 OR EXISTS(SELECT 1 FROM editorial.review_decisions d \
           JOIN ops.user_roles ur ON ur.user_id=d.reviewer_id AND ur.revoked_at IS NULL \
           JOIN ops.roles r ON r.id=ur.role_id AND r.code='LEGAL_REVIEWER' \
           WHERE d.review_snapshot_id=$1 AND d.decision='APPROVE'))",
    )
    .bind(snapshot)
    .bind(snapshot_creator)
    .bind(legal_required)
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?;
    if !approval {
        return Err(ServiceError::InvalidRequest);
    }
    let preview: Value = sqlx::query_scalar(
        "SELECT preview_payload FROM editorial.publication_previews \
         WHERE case_id=$1 AND review_snapshot_id=$2 AND preview_sha256=$3 \
           AND expires_at>clock_timestamp() ORDER BY created_at DESC LIMIT 1",
    )
    .bind(case_id)
    .bind(snapshot)
    .bind(preview_hash)
    .fetch_optional(&mut **tx)
    .await
    .map_err(db)?
    .ok_or(ServiceError::InvalidRequest)?;
    let digest = sha256(&serde_json::to_vec(&preview).map_err(|_| ServiceError::Persistence)?);
    if digest != preview_hash {
        return Err(ServiceError::InvalidRequest);
    }
    persist_published_case(
        case_id,
        snapshot,
        preview_hash,
        preview,
        digest,
        actor,
        payload,
        tx,
    )
    .await?;
    Ok(())
}

#[expect(
    clippy::too_many_arguments,
    reason = "publication persistence binds case, snapshot, and receipt provenance"
)]
pub(super) async fn persist_published_case(
    case_id: Uuid,
    snapshot: Uuid,
    preview_hash: &str,
    preview: Value,
    digest: String,
    actor: Uuid,
    payload: &Map<String, Value>,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let row = sqlx::query(
        "SELECT CASE \
           WHEN c.publication_state='NEVER_PUBLISHED' AND c.resolution_code='EXPLAINED' \
             THEN 'PUBLISHED_EXPLAINED' \
           WHEN c.publication_state='NEVER_PUBLISHED' THEN 'PUBLISHED_ANOMALY' \
           ELSE c.publication_state::text \
         END publication_state, \
         GREATEST(COALESCE(c.current_publication_revision,0), \
           COALESCE((SELECT max(r.revision) FROM editorial.publication_revisions r \
                     WHERE r.case_id=c.id),0))+1 revision, \
         NULLIF(GREATEST(COALESCE(c.current_publication_revision,0), \
           COALESCE((SELECT max(r.revision) FROM editorial.publication_revisions r \
                     WHERE r.case_id=c.id),0)),0) current_publication_revision \
         FROM editorial.cases c WHERE c.id=$1 FOR UPDATE OF c",
    )
    .bind(case_id)
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?;
    let revision: i32 = row.try_get("revision").map_err(db)?;
    let state: String = row.try_get("publication_state").map_err(db)?;
    let supersedes: Option<i32> = row.try_get("current_publication_revision").map_err(db)?;
    sqlx::query(
        "INSERT INTO editorial.publication_revisions(case_id,revision,state,review_snapshot_id, \
         public_payload,public_payload_sha256,preview_sha256,published_by,supersedes_revision,reason) \
         VALUES($1,$2,$3::editorial.publication_state,$4,$5,$6,$7,$8,$9,$10)",
    )
    .bind(case_id)
    .bind(revision)
    .bind(&state)
    .bind(snapshot)
    .bind(preview)
    .bind(&digest)
    .bind(preview_hash)
    .bind(actor)
    .bind(supersedes)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    sqlx::query(
        "UPDATE editorial.cases SET current_review_snapshot_id=$2, \
         current_publication_revision=$3, \
         publication_state=$4::editorial.publication_state WHERE id=$1",
    )
    .bind(case_id)
    .bind(snapshot)
    .bind(revision)
    .bind(&state)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}
