struct SearchFilters {
    q: String,
    pattern: String,
    types: Vec<String>,
    states: Vec<String>,
    date_from: Option<Date>,
    date_to: Option<Date>,
    agency_id: Option<Uuid>,
    sido_code: Option<String>,
    sigungu_code: Option<String>,
    sort: String,
}

fn search_filters(query: &Query) -> Result<SearchFilters, ServiceError> {
    let q = query
        .first("q")
        .filter(|value| value.trim().len() >= 2)
        .ok_or(ServiceError::InvalidRequest)?
        .to_owned();
    let types = query
        .many("types")
        .into_iter()
        .map(|value| value.to_ascii_uppercase())
        .collect();
    let states = query.many("publicationState");
    let date_from = optional_date(query, "dateFrom")?;
    let date_to = optional_date(query, "dateTo")?;
    validate_range(date_from.as_ref(), date_to.as_ref())?;
    let agency_id = optional_uuid(query, "agencyId")?;
    let (sido_code, sigungu_code) = region_filters(query)?;
    let sort = requested_sort(
        query,
        &["relevance", "updated_desc", "title_asc"],
        "relevance",
    )?
    .to_owned();
    Ok(SearchFilters {
        pattern: format!("%{q}%"),
        q,
        types,
        states,
        date_from,
        date_to,
        agency_id,
        sido_code,
        sigungu_code,
        sort,
    })
}

fn region_filters(query: &Query) -> Result<(Option<String>, Option<String>), ServiceError> {
    let sido = region_code(query, "sidoCode", 2)?;
    let sigungu = region_code(query, "sigunguCode", 5)?;
    if sido
        .as_deref()
        .zip(sigungu.as_deref())
        .is_some_and(|(sido, sigungu)| !sigungu.starts_with(sido))
    {
        return Err(ServiceError::InvalidRequest);
    }
    Ok((sido, sigungu))
}

fn region_code(query: &Query, name: &str, length: usize) -> Result<Option<String>, ServiceError> {
    query
        .first(name)
        .map(|value| {
            if value.len() == length && value.bytes().all(|byte| byte.is_ascii_digit()) {
                Ok(value.to_owned())
            } else {
                Err(ServiceError::InvalidRequest)
            }
        })
        .transpose()
}

const OPERATIONAL_INTERPRETATION_NOTICE: &str =
    "이 상태는 자료의 수집·공개·검토 상태이며 위법성이나 부패 여부에 대한 판단이 아닙니다.";
const EMPTY_PUBLICATION_NOTICE: &str = "현재 선택한 조건에서 공개된 사례가 없습니다. 이는 문제 없음이나 청렴성을 의미하지 않으며, 수집 범위와 검토 상태에 따라 결과가 달라질 수 있습니다.";
const PUBLIC_REDISTRIBUTION_NOTICE: &str = "이상 징후 기록이며 위법·부패의 확정이 아님";

fn non_conclusion(state: &str, authority: &Map<String, Value>) -> Result<String, ServiceError> {
    match state {
        "PUBLISHED_ANOMALY" => Ok("공개자료 비교에서 설명이 필요한 차이가 확인됐습니다. 현재 자료만으로 위법성이나 부패 여부를 판단할 수 없습니다.".to_owned()),
        "PUBLISHED_EXPLAINED" => Ok("처음 탐지된 차이는 추가 자료에서 확인된 구성·서비스·조건의 차이로 설명됩니다. 탐지와 검증 과정을 함께 공개합니다.".to_owned()),
        "OFFICIALLY_CONFIRMED" => official_confirmation_notice(authority),
        "CORRECTED" => correction_notice(authority),
        "RETRACTED" => Ok("핵심 근거의 오류로 이 게시물을 철회했습니다. 원래 주장은 더 이상 유효하지 않습니다. 오류 원인과 후속 조치를 공개합니다.".to_owned()),
        "TEMPORARILY_RESTRICTED" => Ok("법적 사유, 권리 보호 또는 안전을 위해 공개를 일시 제한했습니다. 이 제한은 위법성이나 부패 여부에 대한 판단이 아닙니다.".to_owned()),
        _ => Err(ServiceError::Persistence),
    }
}

fn official_confirmation_notice(authority: &Map<String, Value>) -> Result<String, ServiceError> {
    let confirmation = exact_object(
        authority,
        "officialConfirmation",
        &[
            "institution",
            "documentType",
            "documentDate",
            "confirmedScope",
            "sourceLocator",
            "sourceDigest",
        ],
    )?;
    let institution = required_text(confirmation, "institution")?;
    let document_type = required_text(confirmation, "documentType")?;
    let document_date = required_text(confirmation, "documentDate")?;
    validate_iso_date(document_date)?;
    let confirmed_scope = required_text(confirmation, "confirmedScope")?;
    let _source_locator = required_text(confirmation, "sourceLocator")?;
    let source_digest = required_text(confirmation, "sourceDigest")?;
    if source_digest.len() != 64
        || !source_digest
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(ServiceError::Persistence);
    }
    Ok(format!(
        "{institution}의 {document_type}·{document_date}에서 {confirmed_scope}가 확인됐습니다. 구린네의 자체 판단이 아니라 해당 공식 결과를 요약합니다."
    ))
}

fn correction_notice(authority: &Map<String, Value>) -> Result<String, ServiceError> {
    let correction = exact_object(
        authority,
        "correctionNotice",
        &["appliedAt", "reason", "impactSummary", "revision"],
    )?;
    let applied_at = required_text(correction, "appliedAt")?;
    let applied_date = OffsetDateTime::parse(applied_at, &Rfc3339)
        .map_err(|_| ServiceError::Persistence)?
        .date();
    let reason = required_text(correction, "reason")?;
    let impact_summary = required_text(correction, "impactSummary")?;
    if correction
        .get("revision")
        .and_then(Value::as_i64)
        .is_none_or(|revision| revision < 1)
    {
        return Err(ServiceError::Persistence);
    }
    Ok(format!(
        "이 페이지는 {applied_date}에 정정됐습니다. {reason}와 {impact_summary}을 아래 정정 기록에서 확인할 수 있습니다."
    ))
}

fn exact_object<'a>(
    parent: &'a Map<String, Value>,
    key: &str,
    keys: &[&str],
) -> Result<&'a Map<String, Value>, ServiceError> {
    let object = parent
        .get(key)
        .and_then(Value::as_object)
        .ok_or(ServiceError::Persistence)?;
    if object.len() != keys.len() || keys.iter().any(|key| !object.contains_key(*key)) {
        return Err(ServiceError::Persistence);
    }
    Ok(object)
}

fn required_text<'a>(object: &'a Map<String, Value>, key: &str) -> Result<&'a str, ServiceError> {
    object
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or(ServiceError::Persistence)
}

fn validate_iso_date(value: &str) -> Result<(), ServiceError> {
    let format = time::format_description::parse("[year]-[month]-[day]")
        .map_err(|_| ServiceError::Persistence)?;
    Date::parse(value, &format)
        .map(|_| ())
        .map_err(|_| ServiceError::Persistence)
}

fn revision_non_conclusion_state<'a>(case_state: &'a str, revision_state: &'a str) -> &'a str {
    if case_state == "TEMPORARILY_RESTRICTED" {
        case_state
    } else {
        revision_state
    }
}

fn normalize_public_case(
    object: &mut Map<String, Value>,
    public_state: &str,
) -> Result<(), ServiceError> {
    let notice = non_conclusion(public_state, object)?;
    normalize_public_case_with_notice(object, notice)
}

fn normalize_public_case_with_authority(
    object: &mut Map<String, Value>,
    public_state: &str,
    authority: &Map<String, Value>,
) -> Result<(), ServiceError> {
    let notice = non_conclusion(public_state, authority)?;
    normalize_public_case_with_notice(object, notice)
}

fn normalize_public_case_with_notice(
    object: &mut Map<String, Value>,
    notice: String,
) -> Result<(), ServiceError> {
    for key in ["agencyName", "contractName", "amount"] {
        object.entry(key).or_insert(Value::Null);
    }
    if let Some(case) = object.get_mut("case") {
        let case = case.as_object_mut().ok_or(ServiceError::Persistence)?;
        case.insert("nonConclusion".into(), Value::String(notice.clone()));
        retain_fields(case, CASE_CARD_FIELDS);
    }
    object.insert("nonConclusion".into(), Value::String(notice));
    if let Some(Value::Array(evidence)) = object.get_mut("evidence") {
        for item in evidence {
            let Some(item) = item.as_object_mut() else {
                return Err(ServiceError::Persistence);
            };
            for key in [
                "documentTitle",
                "publisher",
                "publishedAt",
                "sourceUrl",
                "pageAnchor",
            ] {
                item.entry(key).or_insert(Value::Null);
            }
        }
    }
    Ok(())
}

const CASE_CARD_FIELDS: &[&str] = &[
    "slug",
    "title",
    "publicState",
    "summary",
    "revision",
    "updatedAt",
    "responseStatus",
    "correctionStatus",
    "nonConclusion",
    "href",
];

const PUBLIC_CASE_RESPONSE_FIELDS: &[&str] = &[
    "slug",
    "title",
    "publicState",
    "revision",
    "publishedAt",
    "updatedAt",
    "summary",
    "agencyName",
    "contractName",
    "amount",
    "nonConclusion",
    "confirmedFacts",
    "criticalUnknowns",
    "partyResponses",
    "signals",
    "comparison",
    "counterEvidence",
    "claims",
    "evidence",
    "timeline",
    "corrections",
    "freshness",
    "limitations",
    "seo",
];

const PUBLIC_CASE_SNAPSHOT_FIELDS: &[&str] = &[
    "case",
    "agencyName",
    "contractName",
    "amount",
    "nonConclusion",
    "confirmedFacts",
    "criticalUnknowns",
    "partyResponses",
    "signals",
    "comparison",
    "counterEvidence",
    "claims",
    "evidence",
    "timeline",
    "corrections",
    "freshness",
    "limitations",
];

const CASE_REPRODUCIBILITY_FIELDS: &[&str] = &[
    "caseSlug",
    "ruleId",
    "ruleVersion",
    "inputDigest",
    "resultDigest",
    "formula",
    "roundingPolicy",
    "target",
    "includedCohort",
    "excludedCohort",
    "result",
    "limitations",
    "nonConclusion",
    "seo",
];

fn retain_fields(object: &mut Map<String, Value>, allowed: &[&str]) {
    object.retain(|key, _| allowed.contains(&key.as_str()));
}

fn case_seo_description(summary: &str, case: &Map<String, Value>) -> String {
    let mut parts = vec![summary.to_owned()];
    for key in ["agencyName", "contractName"] {
        if let Some(value) = case.get(key).and_then(Value::as_str) {
            parts.push(value.to_owned());
        }
    }
    if let Some(amount) = case.get("amount").and_then(Value::as_object)
        && let (Some(value), Some(currency)) = (
            amount.get("amount").and_then(Value::as_str),
            amount.get("currency").and_then(Value::as_str),
        )
    {
        parts.push(format!("{value} {currency}"));
    }
    if let Some(value) = case.get("nonConclusion").and_then(Value::as_str) {
        parts.push(value.to_owned());
    }
    parts.join(" · ")
}

fn seo_metadata(title: &str, description: String, canonical_url: String) -> Value {
    json!({
        "title": title,
        "description": description,
        "openGraphDescription": description,
        "canonicalUrl": canonical_url,
        "robots": "index,follow",
    })
}

fn operational_seo_description(summary: &str) -> String {
    format!("{summary} · {OPERATIONAL_INTERPRETATION_NOTICE}")
}

fn search_result_notices(
    result_type: &str,
    status: Option<&str>,
    authority: Option<&Map<String, Value>>,
) -> Result<(Option<String>, Option<&'static str>), ServiceError> {
    match result_type {
        "CASE" | "CORRECTION" => {
            let state = status.ok_or(ServiceError::Persistence)?;
            let authority = authority.ok_or(ServiceError::Persistence)?;
            Ok((Some(non_conclusion(state, authority)?), None))
        }
        "AGENCY" | "SUPPLIER" | "CONTRACT" | "SOURCE" => {
            Ok((None, Some(OPERATIONAL_INTERPRETATION_NOTICE)))
        }
        "RULE" | "DATASET" => Ok((None, None)),
        _ => Err(ServiceError::Persistence),
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn db(_: sqlx::Error) -> ServiceError {
    ServiceError::Persistence
}

#[cfg(test)]
include!("public_tail_tests.rs");
#[cfg(test)]
include!("notice_seo_tests.rs");
