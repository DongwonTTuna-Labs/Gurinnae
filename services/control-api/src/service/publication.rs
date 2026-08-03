use super::*;

pub(super) async fn publication_payload(
    case_id: Uuid,
    snapshot_id: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<Value, ServiceError> {
    let row = sqlx::query!(
        "SELECT c.public_slug,c.title,c.summary,s.snapshot_payload \
         FROM editorial.cases c JOIN editorial.review_snapshots s ON s.case_id=c.id \
         WHERE c.id=$1 AND s.id=$2",
        case_id,
        snapshot_id,
    )
    .fetch_optional(&mut **tx)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    let snapshot = row.snapshot_payload;
    let snapshot = snapshot.as_object().ok_or(ServiceError::Persistence)?;
    let claim_ids = optional_uuid_array(snapshot, "claimIds")?;
    let evidence_ids = optional_uuid_array(snapshot, "evidenceIds")?;
    let response_ids = optional_uuid_array(snapshot, "responseIds")?;
    let (agency_ids, supplier_ids, rule_ids) = publication_relations(case_id, tx).await?;
    let claims = load_publication_claims(case_id, &claim_ids, tx).await?;
    let evidence = load_publication_evidence(case_id, &evidence_ids, tx).await?;
    let responses = load_publication_responses(case_id, &response_ids, tx).await?;
    let source_freshness = snapshot
        .get("sourceFreshness")
        .cloned()
        .unwrap_or_else(|| json!({}));
    if !source_freshness.is_object() {
        return Err(ServiceError::Persistence);
    }

    Ok(json!({
        "caseId":case_id,
        "reviewSnapshotId":snapshot_id,
        "slug":row.public_slug.unwrap_or_else(|| format!("case-{case_id}")),
        "title":row.title,
        "summary":row.summary.unwrap_or_default(),
        "agencyIds":agency_ids,
        "supplierIds":supplier_ids,
        "ruleIds":rule_ids,
        "claims":claims,
        "evidence":evidence,
        "responses":responses,
        "sourceFreshness":source_freshness,
    }))
}

pub(super) async fn load_publication_claims(
    case_id: Uuid,
    claim_ids: &[Uuid],
    tx: &mut Transaction<'_, Postgres>,
) -> Result<Vec<Value>, ServiceError> {
    let claim_rows = sqlx::query!(
        "SELECT c.id,c.claim_type::text claim_type,c.text,c.limitations, \
         COALESCE((SELECT jsonb_agg(ce.evidence_id ORDER BY ce.citation_order) \
                   FROM editorial.claim_evidence ce WHERE ce.claim_id=c.id),'[]'::jsonb) evidence_ids, \
         COALESCE((SELECT jsonb_agg(cr.response_id ORDER BY cr.response_id) \
                   FROM editorial.claim_responses cr WHERE cr.claim_id=c.id),'[]'::jsonb) response_ids \
         FROM editorial.claims c WHERE c.case_id=$1 AND c.id=ANY($2::uuid[]) \
         ORDER BY array_position($2::uuid[],c.id)",
        case_id,
        claim_ids,
    )
    .fetch_all(&mut **tx)
    .await
    .map_err(db)?;
    if claim_rows.len() != claim_ids.len() {
        return Err(ServiceError::InvalidRequest);
    }
    let mut claims = Vec::with_capacity(claim_rows.len());
    for claim in claim_rows {
        let limitations = claim.limitations;
        let claim_type = claim.claim_type.ok_or(ServiceError::Persistence)?;
        let evidence_ids = claim.evidence_ids.ok_or(ServiceError::Persistence)?;
        let response_ids = claim.response_ids.ok_or(ServiceError::Persistence)?;
        if !limitations
            .as_array()
            .is_some_and(|items| items.iter().all(Value::is_string))
        {
            return Err(ServiceError::InvalidRequest);
        }
        claims.push(json!({
            "id":claim.id,
            "claimType":claim_type,
            "text":claim.text,
            "evidenceIds":evidence_ids,
            "responseIds":response_ids,
            "limitations":limitations,
        }));
    }
    Ok(claims)
}

pub(super) async fn load_publication_evidence(
    case_id: Uuid,
    evidence_ids: &[Uuid],
    tx: &mut Transaction<'_, Postgres>,
) -> Result<Vec<Value>, ServiceError> {
    let evidence_rows = sqlx::query!(
        "SELECT e.id,e.title,e.evidence_type,e.source_url,e.source_locator,e.content_sha256, \
         e.redacted_public_excerpt,e.classification::text classification,e.verification_status \
         FROM editorial.evidence e WHERE e.case_id=$1 AND e.id=ANY($2::uuid[]) \
         ORDER BY array_position($2::uuid[],e.id)",
        case_id,
        evidence_ids,
    )
    .fetch_all(&mut **tx)
    .await
    .map_err(db)?;
    if evidence_rows.len() != evidence_ids.len() {
        return Err(ServiceError::InvalidRequest);
    }
    let mut evidence = Vec::with_capacity(evidence_rows.len());
    for item in evidence_rows {
        let classification = item.classification.ok_or(ServiceError::Persistence)?;
        let verification_status = item.verification_status;
        if classification != "PUBLIC" || verification_status != "VERIFIED" {
            return Err(ServiceError::InvalidRequest);
        }
        evidence.push(json!({
            "id":item.id,
            "title":item.title,
            "evidenceType":item.evidence_type,
            "sourceUrl":item.source_url,
            "sourceLocator":item.source_locator,
            "contentSha256":item.content_sha256.trim(),
            "publicExcerpt":item.redacted_public_excerpt,
            "restriction":Value::Null,
        }));
    }
    Ok(evidence)
}

pub(super) async fn load_publication_responses(
    case_id: Uuid,
    response_ids: &[Uuid],
    tx: &mut Transaction<'_, Postgres>,
) -> Result<Vec<Value>, ServiceError> {
    let response_rows = sqlx::query!(
        "SELECT r.id,r.party_name,r.submitted_at,r.public_excerpt,r.publication_consent, \
         r.editorial_status FROM editorial.responses r \
         WHERE r.case_id=$1 AND r.id=ANY($2::uuid[]) \
         ORDER BY array_position($2::uuid[],r.id)",
        case_id,
        response_ids,
    )
    .fetch_all(&mut **tx)
    .await
    .map_err(db)?;
    if response_rows.len() != response_ids.len() {
        return Err(ServiceError::InvalidRequest);
    }
    let mut responses = Vec::with_capacity(response_rows.len());
    for response in response_rows {
        let status = response.editorial_status;
        if !matches!(status.as_str(), "ACCEPTED" | "PARTIAL" | "PUBLISHED") {
            return Err(ServiceError::InvalidRequest);
        }
        responses.push(json!({
            "id":response.id,
            "partyName":response.party_name,
            "status":status,
            "submittedAt":format_time(response.submitted_at)?,
            "excerpt":response.public_excerpt,
            "attachmentCount":0,
            "publicationConsent":response.publication_consent,
        }));
    }
    Ok(responses)
}

pub(super) async fn publication_relations(
    case_id: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(Vec<Uuid>, Vec<Uuid>, Vec<String>), ServiceError> {
    let rows = sqlx::query!(
        "SELECT v.rule_id,upper(s.target_type) target_type,s.target_id, \
           COALESCE(c.agency_id,lc.agency_id,cc.agency_id) agency_id, \
           COALESCE(c.supplier_id,lc.supplier_id,cc.supplier_id) supplier_id, \
           a.id \"direct_agency_id?\",u.id \"direct_supplier_id?\" \
         FROM editorial.case_signals cs \
         JOIN core.anomaly_signals s ON s.id=cs.signal_id \
         JOIN core.rule_versions v ON v.id=s.rule_version_id \
         LEFT JOIN core.contracts c ON upper(s.target_type)='CONTRACT' AND c.id=s.target_id \
         LEFT JOIN core.contract_line_items li ON upper(s.target_type) IN ('LINE_ITEM','CONTRACT_LINE_ITEM') AND li.id=s.target_id \
         LEFT JOIN core.contracts lc ON lc.id=li.contract_id \
         LEFT JOIN core.contract_changes ch ON upper(s.target_type)='CONTRACT_CHANGE' AND ch.id=s.target_id \
         LEFT JOIN core.contracts cc ON cc.id=ch.contract_id \
         LEFT JOIN core.agencies a ON upper(s.target_type)='AGENCY' AND a.id=s.target_id \
         LEFT JOIN core.suppliers u ON upper(s.target_type)='SUPPLIER' AND u.id=s.target_id \
         WHERE cs.case_id=$1 ORDER BY v.rule_id,s.id",
        case_id,
    )
    .fetch_all(&mut **tx)
    .await
    .map_err(db)?;
    let mut agencies = BTreeSet::new();
    let mut suppliers = BTreeSet::new();
    let mut rules = BTreeSet::new();
    for row in rows {
        let target_type = row.target_type.ok_or(ServiceError::Persistence)?;
        let target_id = row.target_id;
        rules.insert(row.rule_id);
        match target_type.as_str() {
            "AGENCY" => {
                agencies.insert(row.direct_agency_id.ok_or(ServiceError::InvalidRequest)?);
            }
            "SUPPLIER" => {
                suppliers.insert(row.direct_supplier_id.ok_or(ServiceError::InvalidRequest)?);
            }
            "CONTRACT" | "LINE_ITEM" | "CONTRACT_LINE_ITEM" | "CONTRACT_CHANGE" => {
                agencies.insert(row.agency_id.ok_or(ServiceError::InvalidRequest)?);
                if let Some(supplier) = row.supplier_id {
                    suppliers.insert(supplier);
                }
            }
            _ => {
                let _ = target_id;
            }
        }
    }
    Ok((
        agencies.into_iter().collect(),
        suppliers.into_iter().collect(),
        rules.into_iter().collect(),
    ))
}

pub(super) fn optional_uuid_array(
    payload: &Map<String, Value>,
    key: &str,
) -> Result<Vec<Uuid>, ServiceError> {
    match payload.get(key) {
        None => Ok(Vec::new()),
        Some(Value::Array(values)) => values
            .iter()
            .map(|value| {
                value
                    .as_str()
                    .and_then(|value| Uuid::parse_str(value).ok())
                    .ok_or(ServiceError::Persistence)
            })
            .collect(),
        Some(_) => Err(ServiceError::Persistence),
    }
}
