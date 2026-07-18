use super::*;

pub(super) async fn arm_disableuser(
    _operation: &str,
    _payload: &Map<String, Value>,
    id: Uuid,
    _actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let changed = sqlx::query("UPDATE ops.users SET status='DISABLED' WHERE id=$1")
        .bind(id)
        .execute(&mut **tx)
        .await
        .map_err(db)?
        .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }
    sqlx::query(
        "UPDATE ops.sessions SET revoked_at=COALESCE(revoked_at,clock_timestamp()) \
         WHERE user_id=$1 AND revoked_at IS NULL",
    )
    .bind(id)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_grantrole(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let user = uuid_value(payload, &["userId"]).ok_or(ServiceError::InvalidRequest)?;
    let role = uuid_value(payload, &["roleId"]).ok_or(ServiceError::InvalidRequest)?;
    let role_exists: bool =
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM ops.roles WHERE id=$1)")
            .bind(role)
            .fetch_one(&mut **tx)
            .await
            .map_err(db)?;
    if !role_exists {
        return Err(ServiceError::NotFound);
    }
    sqlx::query(
        "INSERT INTO ops.user_roles(user_id,role_id,granted_by,reason,expires_at) \
         VALUES($1,$2,$3,$4,$5)",
    )
    .bind(user)
    .bind(role)
    .bind(actor)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .bind(timestamp_value(payload, "expiresAt")?)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_inviteuser(
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let email = string_value(payload, "email").ok_or(ServiceError::InvalidRequest)?;
    let display = string_value(payload, "displayName").ok_or(ServiceError::InvalidRequest)?;
    let oidc_subject = format!("invited:{}", sha256(email.to_ascii_lowercase().as_bytes()));
    sqlx::query(
        "INSERT INTO ops.users(id,oidc_subject,email,display_name,status) \
         VALUES($1,$2,$3,$4,'INVITED')",
    )
    .bind(id)
    .bind(oidc_subject)
    .bind(email)
    .bind(display)
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    for role in uuid_array(payload, "roleIds")? {
        let exists: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM ops.roles WHERE id=$1)")
            .bind(role)
            .fetch_one(&mut **tx)
            .await
            .map_err(db)?;
        if !exists {
            return Err(ServiceError::NotFound);
        }
        sqlx::query(
            "INSERT INTO ops.user_roles(user_id,role_id,granted_by,reason,expires_at) \
             VALUES($1,$2,$3,'initial invitation grant',$4)",
        )
        .bind(id)
        .bind(role)
        .bind(actor)
        .bind(timestamp_value(payload, "expiresAt")?)
        .execute(&mut **tx)
        .await
        .map_err(db)?;
    }

    Ok(())
}

pub(super) async fn arm_linkevidence(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let evidence = uuid_value(payload, &["evidenceId"]).ok_or(ServiceError::InvalidRequest)?;
    let target = uuid_value(payload, &["targetId"]).ok_or(ServiceError::InvalidRequest)?;
    sqlx::query(
        "INSERT INTO editorial.evidence_links(evidence_id,target_type,target_id,relation, \
         reason,created_by) VALUES($1,$2,$3,$4,$5,$6)",
    )
    .bind(evidence)
    .bind(string_value(payload, "targetType").ok_or(ServiceError::InvalidRequest)?)
    .bind(target)
    .bind(string_value(payload, "relation").ok_or(ServiceError::InvalidRequest)?)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_linksignaltocase(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
    let signal = uuid_value(payload, &["signalId"]).ok_or(ServiceError::InvalidRequest)?;
    sqlx::query(
        "INSERT INTO editorial.case_signals(case_id,signal_id,link_reason,linked_by) \
         VALUES($1,$2,$3,$4) ON CONFLICT(case_id,signal_id) DO NOTHING",
    )
    .bind(case_id)
    .bind(signal)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    sqlx::query("UPDATE core.anomaly_signals SET status='LINKED' WHERE id=$1")
        .bind(signal)
        .execute(&mut **tx)
        .await
        .map_err(db)?;

    Ok(())
}

pub(super) async fn arm_pausebackfill(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    _actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let run = uuid_value(payload, &["backfillRunId"]).ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query(
        "UPDATE ops.source_runs SET status='PAUSED',request_reason=$2 \
         WHERE id=$1 AND mode IN ('BACKFILL','DRY_RUN') AND status='RUNNING'",
    )
    .bind(run)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::VersionConflict);
    }

    Ok(())
}

pub(super) async fn arm_pausejobqueue(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let state = match string_value(payload, "mode") {
        Some("PAUSE_NEW") => "PAUSED_NEW",
        Some("PAUSE_AND_DRAIN") => "DRAINING",
        _ => return Err(ServiceError::InvalidRequest),
    };
    let queue = string_value(payload, "queueName").ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query(
        "UPDATE ops.queue_controls SET state=$2,reason=$3,changed_by=$4, \
         changed_at=clock_timestamp() WHERE queue_name=$1",
    )
    .bind(queue)
    .bind(state)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }

    Ok(())
}

pub(super) async fn arm_pausesource(
    _operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    _actor: Uuid,
    _session_id: Uuid,
    _field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let source = string_value(payload, "sourceId").ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query("UPDATE ops.source_registry SET enabled=false WHERE source_id=$1")
        .bind(source)
        .execute(&mut **tx)
        .await
        .map_err(db)?
        .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }

    Ok(())
}

pub(super) async fn arm_placetemporaryrestriction(
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
    let expires = timestamp_value(payload, "expiresAt")?.ok_or(ServiceError::InvalidRequest)?;
    if expires <= OffsetDateTime::now_utc() {
        return Err(ServiceError::InvalidRequest);
    }
    sqlx::query(
        "INSERT INTO editorial.publication_access_decisions(id,publication_revision_id, \
         scope,affected_ids,state,reason,expires_at,placed_by) \
         VALUES($1,$2,$3,$4,'ACTIVE',$5,$6,$7)",
    )
    .bind(id)
    .bind(publication)
    .bind(string_value(payload, "scope").ok_or(ServiceError::InvalidRequest)?)
    .bind(
        payload
            .get("affectedIds")
            .cloned()
            .unwrap_or_else(|| json!([])),
    )
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .bind(expires)
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

pub(super) async fn apply_specialized_group_3(
    operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    session_id: Uuid,
    field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    match operation {
        "disableUser" => {
            arm_disableuser(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "grantRole" => {
            arm_grantrole(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "inviteUser" => {
            arm_inviteuser(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "linkEvidence" => {
            arm_linkevidence(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "linkSignalToCase" => {
            arm_linksignaltocase(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "pauseBackfill" => {
            arm_pausebackfill(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "pauseJobQueue" => {
            arm_pausejobqueue(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "pauseSource" => {
            arm_pausesource(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        "placeTemporaryRestriction" => {
            arm_placetemporaryrestriction(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        "previewPublication" => {
            arm_previewpublication(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        "publishCase" => {
            arm_publishcase(operation, payload, id, actor, session_id, field_keys, tx).await?
        }
        _ => return Err(ServiceError::InvalidRequest),
    }
    Ok(())
}
