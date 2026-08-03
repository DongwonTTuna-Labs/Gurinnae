use super::*;

pub(super) async fn publication_payload(
    case_id: Uuid,
    snapshot_id: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<Value, ServiceError> {
    let row = sqlx::query!(
        "SELECT c.public_slug,c.title,c.summary,s.snapshot_payload,CASE \
           WHEN c.publication_state='NEVER_PUBLISHED' AND c.resolution_code='EXPLAINED' \
             THEN 'PUBLISHED_EXPLAINED' \
           WHEN c.publication_state='NEVER_PUBLISHED' THEN 'PUBLISHED_ANOMALY' \
           ELSE c.publication_state::text \
         END \"public_state!\" \
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
    let relations = publication_relations(case_id, tx).await?;
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
        "nonConclusion":publication_non_conclusion(&row.public_state)?,
        "agencyId":relations.agency_id,
        "agencyName":relations.agency_name,
        "contractName":relations.contract_name,
        "amount":relations.amount,
        "agencyIds":relations.agency_ids,
        "supplierIds":relations.supplier_ids,
        "ruleIds":relations.rule_ids,
        "claims":claims,
        "evidence":evidence,
        "responses":responses,
        "sourceFreshness":source_freshness,
    }))
}

fn publication_non_conclusion(state: &str) -> Result<&'static str, ServiceError> {
    match state {
        "PUBLISHED_ANOMALY" => Ok(
            "공개자료 비교에서 설명이 필요한 차이가 확인됐습니다. 현재 자료만으로 위법성이나 부패 여부를 판단할 수 없습니다.",
        ),
        "PUBLISHED_EXPLAINED" => Ok(
            "처음 탐지된 차이는 추가 자료에서 확인된 구성·서비스·조건의 차이로 설명됩니다. 탐지와 검증 과정을 함께 공개합니다.",
        ),
        "OFFICIALLY_CONFIRMED" => Ok(
            "구린네의 자체 판단이 아니라 공식 기관·법원의 확인 결과를 공개된 범위에서 요약합니다.",
        ),
        "CORRECTED" => Ok(
            "이 페이지는 정정됐습니다. 잘못된 내용과 결론에 미친 영향은 아래 정정 기록에서 확인할 수 있습니다.",
        ),
        "RETRACTED" => Ok(
            "핵심 근거의 오류로 이 게시물을 철회했습니다. 원래 주장은 더 이상 유효하지 않습니다. 오류 원인과 후속 조치를 공개합니다.",
        ),
        "TEMPORARILY_RESTRICTED" => Ok(
            "법적 사유, 권리 보호 또는 안전을 위해 공개를 일시 제한했습니다. 이 제한은 위법성이나 부패 여부에 대한 판단이 아닙니다.",
        ),
        _ => Err(ServiceError::InvalidRequest),
    }
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
        "SELECT e.id,e.title,e.evidence_type,e.document_title,e.publisher,e.published_at, \
         e.source_url,e.page_anchor,e.source_locator,e.content_sha256, \
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
            "documentTitle":item.document_title,
            "publisher":item.publisher,
            "publishedAt":item.published_at.map(format_time).transpose()?,
            "sourceUrl":item.source_url,
            "pageAnchor":item.page_anchor,
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

struct PublicationRelations {
    agency_id: Option<Uuid>,
    agency_name: Option<String>,
    contract_name: Option<String>,
    amount: Option<Value>,
    agency_ids: Vec<Uuid>,
    supplier_ids: Vec<Uuid>,
    rule_ids: Vec<String>,
}

async fn publication_relations(
    case_id: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<PublicationRelations, ServiceError> {
    let rows = sqlx::query!(
        "SELECT v.rule_id,upper(s.target_type) target_type,s.target_id, \
           COALESCE(c.agency_id,lc.agency_id,cc.agency_id) agency_id, \
           COALESCE(c.supplier_id,lc.supplier_id,cc.supplier_id) supplier_id, \
           a.id \"direct_agency_id?\",u.id \"direct_supplier_id?\", \
           COALESCE(a.canonical_name,ra.canonical_name) \"agency_name?\", \
           COALESCE(c.id,lc.id,cc.id) \"contract_id?\", \
           COALESCE(c.title,lc.title,cc.title) \"contract_name?\", \
           COALESCE(c.current_amount,c.original_amount,lc.current_amount,lc.original_amount, \
                    cc.current_amount,cc.original_amount) \"contract_amount?\", \
           COALESCE(c.currency,lc.currency,cc.currency) \"contract_currency?\" \
         FROM editorial.case_signals cs \
         JOIN core.anomaly_signals s ON s.id=cs.signal_id \
         JOIN core.rule_versions v ON v.id=s.rule_version_id \
         LEFT JOIN core.contracts c ON upper(s.target_type)='CONTRACT' AND c.id=s.target_id \
         LEFT JOIN core.contract_line_items li ON upper(s.target_type) IN ('LINE_ITEM','CONTRACT_LINE_ITEM') AND li.id=s.target_id \
         LEFT JOIN core.contracts lc ON lc.id=li.contract_id \
         LEFT JOIN core.contract_changes ch ON upper(s.target_type)='CONTRACT_CHANGE' AND ch.id=s.target_id \
         LEFT JOIN core.contracts cc ON cc.id=ch.contract_id \
         LEFT JOIN core.agencies a ON upper(s.target_type)='AGENCY' AND a.id=s.target_id \
         LEFT JOIN core.agencies ra ON ra.id=COALESCE(c.agency_id,lc.agency_id,cc.agency_id) \
         LEFT JOIN core.suppliers u ON upper(s.target_type)='SUPPLIER' AND u.id=s.target_id \
         WHERE cs.case_id=$1 ORDER BY v.rule_id,s.id",
        case_id,
    )
    .fetch_all(&mut **tx)
    .await
    .map_err(db)?;
    let mut agencies = BTreeSet::new();
    let mut agency_names = BTreeMap::new();
    let mut contracts = BTreeMap::new();
    let mut suppliers = BTreeSet::new();
    let mut rules = BTreeSet::new();
    for row in rows {
        let target_type = row.target_type.ok_or(ServiceError::Persistence)?;
        let target_id = row.target_id;
        rules.insert(row.rule_id);
        match target_type.as_str() {
            "AGENCY" => {
                let agency_id = row.direct_agency_id.ok_or(ServiceError::InvalidRequest)?;
                agencies.insert(agency_id);
                if let Some(name) = row.agency_name {
                    agency_names.insert(agency_id, name);
                }
            }
            "SUPPLIER" => {
                suppliers.insert(row.direct_supplier_id.ok_or(ServiceError::InvalidRequest)?);
            }
            "CONTRACT" | "LINE_ITEM" | "CONTRACT_LINE_ITEM" | "CONTRACT_CHANGE" => {
                let agency_id = row.agency_id.ok_or(ServiceError::InvalidRequest)?;
                agencies.insert(agency_id);
                if let Some(name) = row.agency_name {
                    agency_names.insert(agency_id, name);
                }
                let contract_id = row.contract_id.ok_or(ServiceError::InvalidRequest)?;
                let contract_name = row.contract_name.ok_or(ServiceError::InvalidRequest)?;
                let amount = row.contract_amount.zip(row.contract_currency).map(
                    |(amount, currency)| {
                        json!({"amount":amount.to_string(),"currency":currency.trim()})
                    },
                );
                contracts.insert(contract_id, (contract_name, amount));
                if let Some(supplier) = row.supplier_id {
                    suppliers.insert(supplier);
                }
            }
            _ => {
                let _ = target_id;
            }
        }
    }
    let agency_id = (agencies.len() == 1)
        .then(|| agencies.first().copied())
        .flatten();
    let agency_name = agency_id.and_then(|id| agency_names.remove(&id));
    let (contract_name, amount) = if contracts.len() == 1 {
        contracts
            .into_values()
            .next()
            .map_or((None, None), |(name, amount)| (Some(name), amount))
    } else {
        (None, None)
    };
    Ok(PublicationRelations {
        agency_id,
        agency_name,
        contract_name,
        amount,
        agency_ids: agencies.into_iter().collect(),
        supplier_ids: suppliers.into_iter().collect(),
        rule_ids: rules.into_iter().collect(),
    })
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

#[cfg(test)]
mod tests {
    use super::{ServiceError, publication_non_conclusion};

    #[test]
    fn publication_non_conclusion_maps_all_public_states() {
        let expected = [
            (
                "PUBLISHED_ANOMALY",
                "공개자료 비교에서 설명이 필요한 차이가 확인됐습니다. 현재 자료만으로 위법성이나 부패 여부를 판단할 수 없습니다.",
            ),
            (
                "PUBLISHED_EXPLAINED",
                "처음 탐지된 차이는 추가 자료에서 확인된 구성·서비스·조건의 차이로 설명됩니다. 탐지와 검증 과정을 함께 공개합니다.",
            ),
            (
                "OFFICIALLY_CONFIRMED",
                "구린네의 자체 판단이 아니라 공식 기관·법원의 확인 결과를 공개된 범위에서 요약합니다.",
            ),
            (
                "CORRECTED",
                "이 페이지는 정정됐습니다. 잘못된 내용과 결론에 미친 영향은 아래 정정 기록에서 확인할 수 있습니다.",
            ),
            (
                "RETRACTED",
                "핵심 근거의 오류로 이 게시물을 철회했습니다. 원래 주장은 더 이상 유효하지 않습니다. 오류 원인과 후속 조치를 공개합니다.",
            ),
            (
                "TEMPORARILY_RESTRICTED",
                "법적 사유, 권리 보호 또는 안전을 위해 공개를 일시 제한했습니다. 이 제한은 위법성이나 부패 여부에 대한 판단이 아닙니다.",
            ),
        ];

        for (state, copy) in expected {
            assert_eq!(
                publication_non_conclusion(state).ok(),
                Some(copy),
                "state {state}"
            );
        }
    }

    #[test]
    fn publication_non_conclusion_rejects_never_published() {
        assert!(matches!(
            publication_non_conclusion("NEVER_PUBLISHED"),
            Err(ServiceError::InvalidRequest)
        ));
    }
}
