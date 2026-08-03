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

fn non_conclusion(state: &str) -> Result<&'static str, ServiceError> {
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
        _ => Err(ServiceError::Persistence),
    }
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
    for key in ["agencyName", "contractName", "amount"] {
        object.entry(key).or_insert(Value::Null);
    }
    object.insert(
        "nonConclusion".into(),
        Value::String(non_conclusion(public_state)?.to_owned()),
    );
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

async fn list_reports(pool: &PgPool, query: &Query) -> Result<Value, ServiceError> {
    let period_from = optional_date(query, "periodFrom")?;
    let period_to = optional_date(query, "periodTo")?;
    validate_range(period_from.as_ref(), period_to.as_ref())?;
    let sort = requested_sort(query, &["published_desc", "period_desc"], "published_desc")?;
    let rows = sqlx::query!(
        "SELECT id,period_start,period_end,title,summary,report,published_at FROM public.transparency_reports WHERE ($1::date IS NULL OR period_end >= $1) AND ($2::date IS NULL OR period_start <= $2) ORDER BY CASE WHEN $3='published_desc' THEN published_at END DESC,CASE WHEN $3='period_desc' THEN period_end END DESC,CASE WHEN $3='period_desc' THEN period_start END DESC,id LIMIT $4 OFFSET $5",
        period_from,
        period_to,
        sort,
        query.limit + 1,
        query.offset,
    )
    .fetch_all(pool)
    .await
    .map_err(db)?;
    let mut items = Vec::new();
    for r in rows {
        let id = r.id;
        let summary = r.summary;
        let report = r.report;
        let detail = ["income", "expenses", "donors", "conflicts", "thresholds"]
            .into_iter()
            .filter_map(|key| {
                report
                    .get(key)
                    .and_then(|value| public_report_scalar(key, value))
            })
            .collect::<Vec<_>>();
        let summary = if detail.is_empty() {
            summary
        } else {
            format!("{summary} · {}", detail.join(" · "))
        };
        items.push(json!({"id":id,"periodStart":r.period_start.to_string(),"periodEnd":r.period_end.to_string(),"title":r.title,"summary":summary,"publishedAt":timestamp(r.published_at)?,"href":format!("/transparency-reports/{id}")}));
    }
    let mut filters = Map::new();
    for name in ["periodFrom", "periodTo"] {
        if let Some(value) = query.first(name) {
            filters.insert(name.into(), json!(value));
        }
    }
    page(items, query, Value::Object(filters))
}

/// `public.transparency_reports.report` is JSONB for storage compatibility,
/// but it is not a permission boundary.  Only the closed, public summary keys
/// above may cross this API, and only scalar values are rendered.  Objects and
/// arrays are deliberately omitted until a signed disclosure schema gives them
/// a public projection; text values remain UNKNOWN until that schema exists,
/// preventing private contacts or internal notes from being stringified into an
/// anonymous response.
fn public_report_scalar(key: &str, value: &serde_json::Value) -> Option<String> {
    let rendered = match value {
        serde_json::Value::Bool(value) => value.to_string(),
        serde_json::Value::Number(value) => value.to_string(),
        _ => return None,
    };
    Some(format!("{key}: {rendered}"))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn db(_: sqlx::Error) -> ServiceError {
    ServiceError::Persistence
}

#[cfg(test)]
mod tests {
    use super::{
        CaseCardRow, OffsetDateTime, Query, ServiceError, Value, case_card, case_seo_description,
        non_conclusion, normalize_public_case, public_report_scalar, region_filters,
        revision_non_conclusion_state,
    };
    use serde_json::json;
    use std::collections::BTreeMap;

    #[test]
    fn region_filters_accept_only_consistent_administrative_codes() {
        let query = Query {
            values: BTreeMap::from([
                ("sidoCode".to_owned(), vec!["11".to_owned()]),
                ("sigunguCode".to_owned(), vec!["11110".to_owned()]),
            ]),
            ..Query::default()
        };
        assert_eq!(
            region_filters(&query).expect("valid administrative codes"),
            (Some("11".to_owned()), Some("11110".to_owned()))
        );
        let invalid = Query {
            values: BTreeMap::from([
                ("sidoCode".to_owned(), vec!["26".to_owned()]),
                ("sigunguCode".to_owned(), vec!["11110".to_owned()]),
            ]),
            ..Query::default()
        };
        assert!(matches!(
            region_filters(&invalid),
            Err(ServiceError::InvalidRequest)
        ));
    }

    #[test]
    fn public_case_normalization_closes_lead_and_evidence_fields() {
        let mut value = json!({"evidence":[{"id":"evidence"}]});
        let object = value.as_object_mut().expect("object fixture");
        normalize_public_case(object, "PUBLISHED_ANOMALY").expect("public state");
        assert_eq!(object.get("agencyName"), Some(&Value::Null));
        for key in [
            "documentTitle",
            "publisher",
            "publishedAt",
            "sourceUrl",
            "pageAnchor",
        ] {
            assert_eq!(object["evidence"][0][key], Value::Null, "field {key}");
        }
        assert_eq!(
            object.get("nonConclusion").and_then(Value::as_str),
            Some(non_conclusion("PUBLISHED_ANOMALY").expect("closed state"))
        );
        assert!(case_seo_description("요약", object).contains("위법성이나 부패 여부"));
    }

    #[test]
    fn public_case_normalization_preserves_projected_lead_fields() {
        let mut value = json!({
            "agencyName":"가상시청",
            "contractName":"공개 계약",
            "amount":{"amount":"1000","currency":"KRW"}
        });
        let object = value.as_object_mut().expect("object fixture");
        normalize_public_case(object, "PUBLISHED_ANOMALY").expect("public state");
        assert_eq!(object["agencyName"], "가상시청");
        assert_eq!(object["contractName"], "공개 계약");
        assert_eq!(object["amount"]["amount"], "1000");
    }

    #[test]
    fn case_card_serializes_projected_response_and_correction_statuses() {
        let card = case_card(CaseCardRow {
            slug: "case-1".to_owned(),
            title: "공개 사건".to_owned(),
            public_state: "CORRECTED".to_owned(),
            summary: "공개 요약".to_owned(),
            latest_revision: 2,
            updated_at: OffsetDateTime::UNIX_EPOCH,
            response_status: Some("RECEIVED".to_owned()),
            correction_status: Some("PUBLISHED".to_owned()),
        })
        .expect("case card");
        assert_eq!(card["responseStatus"], "RECEIVED");
        assert_eq!(card["correctionStatus"], "PUBLISHED");
    }

    #[test]
    fn public_case_normalization_preserves_frozen_evidence_metadata() {
        let evidence = json!({
            "id":"00000000-0000-4000-8000-000000000001",
            "documentTitle":"공공 조달 계약 원문",
            "publisher":"가상 중앙조달원",
            "publishedAt":"2026-07-30T09:15:00Z",
            "sourceUrl":"https://example.test/contracts/2026-001",
            "pageAnchor":"page=7"
        });
        let mut value = json!({"evidence":[evidence.clone()]});
        let object = value.as_object_mut().expect("object fixture");

        normalize_public_case(object, "PUBLISHED_ANOMALY").expect("public state");

        assert_eq!(object["evidence"][0], evidence);
    }

    #[test]
    fn non_conclusion_maps_all_public_states() {
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
            assert_eq!(non_conclusion(state).ok(), Some(copy), "state {state}");
        }
    }

    #[test]
    fn non_conclusion_rejects_non_public_states() {
        assert!(matches!(
            non_conclusion("NEVER_PUBLISHED"),
            Err(ServiceError::Persistence)
        ));
    }

    #[test]
    fn restricted_case_overrides_historical_revision_non_conclusion() {
        assert_eq!(
            revision_non_conclusion_state("TEMPORARILY_RESTRICTED", "PUBLISHED_ANOMALY"),
            "TEMPORARILY_RESTRICTED"
        );
        assert_eq!(
            revision_non_conclusion_state("PUBLISHED_EXPLAINED", "PUBLISHED_ANOMALY"),
            "PUBLISHED_ANOMALY"
        );
    }

    #[test]
    fn public_report_scalar_rejects_nested_private_shapes() {
        assert_eq!(
            public_report_scalar("income", &json!({"contact": "private@example.test"})),
            None
        );
        assert_eq!(
            public_report_scalar("income", &json!(["internal note"])),
            None
        );
    }

    #[test]
    fn public_report_scalar_keeps_bounded_public_primitives() {
        assert_eq!(
            public_report_scalar("thresholds", &json!(15)),
            Some("thresholds: 15".to_owned())
        );
        assert_eq!(
            public_report_scalar("conflicts", &json!("NONE_DECLARED")),
            None
        );
    }
}
