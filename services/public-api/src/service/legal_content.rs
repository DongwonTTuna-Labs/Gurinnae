const GENERATED_LEGAL_CONTENT: &str =
    include_str!("../../../../verification/generated-legal-content.json");

#[derive(Clone, Copy)]
enum LegalDocumentKind {
    Privacy,
    Terms,
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct LegalContentCatalog {
    privacy: LegalDocument,
    terms: LegalDocument,
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct LegalDocument {
    status: String,
    sections: Vec<LegalSection>,
}

#[derive(serde::Deserialize, serde::Serialize)]
#[serde(deny_unknown_fields)]
struct LegalSection {
    id: String,
    heading: String,
    body: String,
}

#[derive(sqlx::FromRow)]
struct ActiveApprovedRetentionScheduleRow {
    record_class: String,
    purpose: String,
    lawful_basis: String,
    trigger_kind: String,
    active_duration_seconds: Option<i64>,
    backup_duration_seconds: Option<i64>,
    terminal_action: String,
    effective_at: OffsetDateTime,
    review_expires_at: OffsetDateTime,
    schedule_digest: String,
}

async fn legal_content(pool: &PgPool, kind: LegalDocumentKind) -> Result<Value, ServiceError> {
    let document = published_legal_document(kind)?;
    let schedule_rows = approved_retention_schedule_rows(pool).await?;
    render_legal_document(kind, document, &schedule_rows, OffsetDateTime::now_utc())
}

fn render_legal_document(
    kind: LegalDocumentKind,
    document: LegalDocument,
    schedule_rows: &[ActiveApprovedRetentionScheduleRow],
    observed_at: OffsetDateTime,
) -> Result<Value, ServiceError> {
    let schedules = retention_schedule_values(schedule_rows, observed_at)?;
    match kind {
        LegalDocumentKind::Privacy => render_privacy_document(document, schedules),
        LegalDocumentKind::Terms => render_terms_document(document, schedules),
    }
}

fn published_legal_document(kind: LegalDocumentKind) -> Result<LegalDocument, ServiceError> {
    let catalog: LegalContentCatalog =
        serde_json::from_str(GENERATED_LEGAL_CONTENT).map_err(|_| ServiceError::Persistence)?;
    let (document, canonical_ids) = match kind {
        LegalDocumentKind::Privacy => (
            catalog.privacy,
            &[
                "controller",
                "categories",
                "purposes",
                "retention",
                "processors",
                "rights",
                "security",
                "history",
            ][..],
        ),
        LegalDocumentKind::Terms => (
            catalog.terms,
            &[
                "service",
                "content",
                "data",
                "prohibited",
                "liability",
                "changes",
            ][..],
        ),
    };
    validate_legal_document(&document, canonical_ids)?;
    if document.status != "PUBLISHED" {
        return Err(ServiceError::Persistence);
    }
    Ok(document)
}

async fn approved_retention_schedule_rows(
    pool: &PgPool,
) -> Result<Vec<ActiveApprovedRetentionScheduleRow>, ServiceError> {
    // The security-barrier projection is the only public-api grant. Reading the
    // underlying ops ledger here would bypass approval and expiry filtering.
    sqlx::query_as::<_, ActiveApprovedRetentionScheduleRow>(
        "SELECT record_class,purpose,lawful_basis,trigger_kind,active_duration_seconds,backup_duration_seconds,terminal_action,effective_at,review_expires_at,schedule_digest FROM public.approved_record_class_schedules ORDER BY record_class",
    )
    .fetch_all(pool)
    .await
    .map_err(db)
}

fn retention_schedule_values(
    rows: &[ActiveApprovedRetentionScheduleRow],
    observed_at: OffsetDateTime,
) -> Result<Vec<Value>, ServiceError> {
    if rows.is_empty()
        || rows
            .windows(2)
            .any(|pair| pair[0].record_class >= pair[1].record_class)
    {
        return Err(ServiceError::Persistence);
    }
    rows.iter()
        .map(|row| retention_schedule_value(row, observed_at))
        .collect()
}

fn retention_schedule_value(
    row: &ActiveApprovedRetentionScheduleRow,
    observed_at: OffsetDateTime,
) -> Result<Value, ServiceError> {
    if [
        row.record_class.as_str(),
        row.purpose.as_str(),
        row.lawful_basis.as_str(),
        row.trigger_kind.as_str(),
    ]
    .into_iter()
    .any(|value| value.trim().is_empty())
        || !matches!(
            row.terminal_action.as_str(),
            "DELETE"
                | "ANONYMIZE"
                | "CRYPTO_ERASE"
                | "PRESERVE_PUBLIC_REVISION"
                | "PRESERVE_REFERENCED_REVISION"
                | "PRESERVE_IDENTITY_GRAPH"
                | "PRESERVE_WITH_PARENT"
        )
        || row.active_duration_seconds.is_some_and(|value| value < 0)
        || row.backup_duration_seconds.is_some_and(|value| value < 0)
        || row.effective_at > observed_at
        || row.review_expires_at <= observed_at
        || !lower_sha256(&row.schedule_digest)
    {
        return Err(ServiceError::Persistence);
    }
    Ok(json!({
        "recordClass": row.record_class,
        "purpose": row.purpose,
        "lawfulBasis": row.lawful_basis,
        "triggerKind": row.trigger_kind,
        "activeDurationSeconds": row.active_duration_seconds,
        "backupDurationSeconds": row.backup_duration_seconds,
        "terminalAction": row.terminal_action,
        "effectiveAt": timestamp(row.effective_at)?,
        "reviewExpiresAt": timestamp(row.review_expires_at)?,
        "scheduleDigest": row.schedule_digest,
    }))
}

fn lower_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn render_privacy_document(
    document: LegalDocument,
    retention_schedules: Vec<Value>,
) -> Result<Value, ServiceError> {
    if retention_schedules.is_empty() {
        return Err(ServiceError::Persistence);
    }
    Ok(json!({
        "id": {"id":"privacy","status":document.status,"version":1},
        "version": 1,
        "status": document.status,
        "data": {
            "status": document.status,
            "sections": document.sections,
            "retentionSchedules": retention_schedules,
        },
        "links": [],
    }))
}

fn render_terms_document(
    document: LegalDocument,
    retention_schedules: Vec<Value>,
) -> Result<Value, ServiceError> {
    if retention_schedules.is_empty() {
        return Err(ServiceError::Persistence);
    }
    Ok(json!({
        "id": {"id":"terms","status":document.status,"version":1},
        "version": 1,
        "status": document.status,
        "data": {
            "status": document.status,
            "sections": document.sections,
            "retentionSchedules": retention_schedules,
        },
        "links": [],
    }))
}

fn validate_legal_document(
    document: &LegalDocument,
    canonical_ids: &[&str],
) -> Result<(), ServiceError> {
    if document.status.trim().is_empty()
        || document.sections.len() != canonical_ids.len()
        || document
            .sections
            .iter()
            .zip(canonical_ids)
            .any(|(section, expected_id)| {
                section.id != *expected_id
                    || section.heading.trim().is_empty()
                    || section.body.trim().is_empty()
            })
    {
        return Err(ServiceError::Persistence);
    }
    Ok(())
}

#[cfg(test)]
include!("legal_content_tests.rs");
