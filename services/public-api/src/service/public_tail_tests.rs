#[cfg(test)]
mod tests {
    use super::{
        CaseCardRow, OffsetDateTime, PUBLIC_CASE_RESPONSE_FIELDS, PageNoticeAuthority, Query,
        ServiceError, Value, case_card, case_seo_description, non_conclusion,
        normalize_public_case, page_seo_description, region_filters,
        retain_fields, revision_non_conclusion_state, search_result_notices,
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
        let expected =
            non_conclusion("PUBLISHED_ANOMALY", &serde_json::Map::new()).expect("closed state");
        assert_eq!(
            object.get("nonConclusion").and_then(Value::as_str),
            Some(expected.as_str())
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
            payload: json!({
                "correctionNotice": {
                    "appliedAt": "2026-07-31T01:02:03Z",
                    "reason": "계약 금액 표기 오류",
                    "impactSummary": "비교 배수 하향",
                    "revision": 2
                }
            }),
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
    fn public_case_projection_does_not_expose_authority_or_internal_linkage() {
        let mut value = json!({
            "slug":"case-1",
            "title":"공개 사건",
            "officialConfirmation":{"sourceDigest":"secret-proof"},
            "correctionNotice":{"reason":"internal authority"},
            "agencyId":"00000000-0000-4000-8000-000000000001",
            "nonConclusion":"비확정 고지"
        });
        let object = value.as_object_mut().expect("object fixture");
        retain_fields(object, PUBLIC_CASE_RESPONSE_FIELDS);
        assert_eq!(object.get("slug").and_then(Value::as_str), Some("case-1"));
        assert!(!object.contains_key("officialConfirmation"));
        assert!(!object.contains_key("correctionNotice"));
        assert!(!object.contains_key("agencyId"));
    }

    #[test]
    fn non_conclusion_maps_all_public_states() {
        let authority = json!({
            "officialConfirmation": {
                "institution": "가상감사원",
                "documentType": "감사 결과",
                "documentDate": "2026-07-30",
                "confirmedScope": "계약 절차 위반 여부",
                "sourceLocator": "official:report:2026-001",
                "sourceDigest": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            },
            "correctionNotice": {
                "appliedAt": "2026-07-31T01:02:03Z",
                "reason": "계약 금액 표기 오류",
                "impactSummary": "비교 배수 하향",
                "revision": 2
            }
        });
        let authority = authority.as_object().expect("authority object");
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
                "가상감사원의 감사 결과·2026-07-30에서 계약 절차 위반 여부가 확인됐습니다. 구린네의 자체 판단이 아니라 해당 공식 결과를 요약합니다.",
            ),
            (
                "CORRECTED",
                "이 페이지는 2026-07-31에 정정됐습니다. 계약 금액 표기 오류와 비교 배수 하향을 아래 정정 기록에서 확인할 수 있습니다.",
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
                non_conclusion(state, authority).expect("closed public state"),
                copy,
                "state {state}"
            );
        }
    }

    #[test]
    fn evidence_dependent_notices_fail_closed_without_exact_authority() {
        for state in ["OFFICIALLY_CONFIRMED", "CORRECTED"] {
            assert!(matches!(
                non_conclusion(state, &serde_json::Map::new()),
                Err(ServiceError::Persistence)
            ));
        }
        let mut incomplete = serde_json::Map::new();
        incomplete.insert(
            "officialConfirmation".to_owned(),
            json!({
                "institution":"가상감사원",
                "documentType":"감사 결과",
                "documentDate":"2026-07-30",
                "confirmedScope":"계약 절차 위반",
                "sourceLocator":"official:report:2026-001"
            }),
        );
        assert!(matches!(
            non_conclusion("OFFICIALLY_CONFIRMED", &incomplete),
            Err(ServiceError::Persistence)
        ));
    }

    #[test]
    fn evidence_dependent_notices_reject_extra_and_malformed_authority() {
        for authority in [
            json!({"officialConfirmation":{
                "institution":"가상감사원",
                "documentType":"감사 결과",
                "documentDate":"2026-07-30",
                "confirmedScope":"계약 절차 위반",
                "sourceLocator":"official:report:2026-001",
                "sourceDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "unexpected":"not public authority"
            }}),
            json!({"officialConfirmation":{
                "institution":"가상감사원",
                "documentType":"감사 결과",
                "documentDate":"2026-02-30",
                "confirmedScope":"계약 절차 위반",
                "sourceLocator":"official:report:2026-001",
                "sourceDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            }}),
            json!({"officialConfirmation":{
                "institution":"가상감사원",
                "documentType":"감사 결과",
                "documentDate":"2026-07-30",
                "confirmedScope":"계약 절차 위반",
                "sourceLocator":"official:report:2026-001",
                "sourceDigest":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            }}),
        ] {
            assert!(matches!(
                non_conclusion(
                    "OFFICIALLY_CONFIRMED",
                    authority.as_object().expect("authority object")
                ),
                Err(ServiceError::Persistence)
            ));
        }
        for authority in [
            json!({"correctionNotice":{
                "appliedAt":"not-a-timestamp",
                "reason":"계약 금액 표기 오류",
                "impactSummary":"비교 배수 하향",
                "revision":2
            }}),
            json!({"correctionNotice":{
                "appliedAt":"2026-07-31T01:02:03Z",
                "reason":"계약 금액 표기 오류",
                "impactSummary":"비교 배수 하향",
                "revision":0
            }}),
            json!({"correctionNotice":{
                "appliedAt":"2026-07-31T01:02:03Z",
                "reason":"계약 금액 표기 오류",
                "impactSummary":"비교 배수 하향",
                "revision":2,
                "unexpected":true
            }}),
        ] {
            assert!(matches!(
                non_conclusion(
                    "CORRECTED",
                    authority.as_object().expect("authority object")
                ),
                Err(ServiceError::Persistence)
            ));
        }
    }

    #[test]
    fn non_conclusion_rejects_non_public_states() {
        assert!(matches!(
            non_conclusion("NEVER_PUBLISHED", &serde_json::Map::new()),
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
    fn page_seo_uses_unique_notices_in_canonical_state_and_kind_order() {
        let anomaly = "공개자료 비교에서 설명이 필요한 차이가 확인됐습니다. 현재 자료만으로 위법성이나 부패 여부를 판단할 수 없습니다.";
        let retracted = "핵심 근거의 오류로 이 게시물을 철회했습니다. 원래 주장은 더 이상 유효하지 않습니다. 오류 원인과 후속 조치를 공개합니다.";
        let operational = super::OPERATIONAL_INTERPRETATION_NOTICE;
        let items = vec![
            json!({"resultType":"SUPPLIER","nonConclusion":null,"interpretationNotice":operational}),
            json!({"resultType":"SOURCE","nonConclusion":null,"interpretationNotice":operational}),
            json!({"resultType":"CASE","status":"RETRACTED","nonConclusion":retracted,"interpretationNotice":null}),
            json!({"resultType":"CASE","status":"PUBLISHED_ANOMALY","nonConclusion":anomaly,"interpretationNotice":null}),
            json!({"resultType":"CASE","status":"PUBLISHED_ANOMALY","nonConclusion":anomaly,"interpretationNotice":null}),
        ];
        assert_eq!(
            page_seo_description("검색", &items, PageNoticeAuthority::SearchCollection)
                .expect("closed search result types and notices"),
            format!("검색 · {anomaly} · {retracted} · {operational}")
        );
    }

    #[test]
    fn source_search_results_require_the_operational_interpretation_notice() {
        assert_eq!(
            search_result_notices("SOURCE", Some("CURRENT"), None)
                .expect("SOURCE is an operational public result"),
            (None, Some(super::OPERATIONAL_INTERPRETATION_NOTICE))
        );
    }
}
