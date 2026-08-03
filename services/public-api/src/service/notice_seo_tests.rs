#[cfg(test)]
mod notice_seo_tests {
    use super::{
        EMPTY_PUBLICATION_NOTICE, OPERATIONAL_INTERPRETATION_NOTICE, PageNoticeAuthority,
        Query, ServiceError, Value, non_conclusion, page_seo_description, page_with_notice_seo,
        search_result_notices,
    };
    use serde_json::json;

    fn empty_page(authority: PageNoticeAuthority) -> Value {
        page_with_notice_seo(
            Vec::new(),
            &Query::default(),
            json!({}),
            "공개 대장",
            "/ledger".to_owned(),
            authority,
        )
        .expect("empty collection has an operation-level notice authority")
    }

    #[test]
    fn empty_publication_and_search_pages_bind_the_canonical_empty_notice_to_seo_and_og() {
        for authority in [
            PageNoticeAuthority::PublicationCollection,
            PageNoticeAuthority::SearchCollection,
        ] {
            let page = empty_page(authority);
            let expected = format!("공개 대장 · {EMPTY_PUBLICATION_NOTICE}");

            assert_eq!(page["seo"]["description"], expected);
            assert_eq!(page["seo"]["openGraphDescription"], expected);
        }
    }

    #[test]
    fn empty_operational_page_binds_the_interpretation_notice_to_seo_and_og() {
        let page = empty_page(PageNoticeAuthority::OperationalCollection);
        let expected = format!("공개 대장 · {OPERATIONAL_INTERPRETATION_NOTICE}");

        assert_eq!(page["seo"]["description"], expected);
        assert_eq!(page["seo"]["openGraphDescription"], expected);
    }

    #[test]
    fn empty_dataset_page_binds_the_redistribution_notice_to_seo_and_og() {
        let page = empty_page(PageNoticeAuthority::RedistributionCollection);
        let expected = format!("공개 대장 · {}", super::PUBLIC_REDISTRIBUTION_NOTICE);

        assert_eq!(page["seo"]["description"], expected);
        assert_eq!(page["seo"]["openGraphDescription"], expected);
    }

    #[test]
    fn operational_only_search_results_keep_their_notice_without_a_case_result() {
        let items = [json!({
            "resultType": "SOURCE",
            "nonConclusion": null,
            "interpretationNotice": OPERATIONAL_INTERPRETATION_NOTICE
        })];

        assert_eq!(
            page_seo_description("검색", &items, PageNoticeAuthority::SearchCollection)
                .expect("known operational-only search result"),
            format!("검색 · {OPERATIONAL_INTERPRETATION_NOTICE}")
        );
    }

    #[test]
    fn rule_and_dataset_are_the_only_search_results_with_no_legal_notice() {
        for result_type in ["RULE", "DATASET"] {
            let item = json!({
                "resultType": result_type,
                "nonConclusion": null,
                "interpretationNotice": null
            });
            assert_eq!(
                page_seo_description(
                    "검색",
                    &[item],
                    PageNoticeAuthority::SearchCollection
                )
                .expect("explicit non-notice search result type"),
                "검색"
            );
            assert_eq!(
                search_result_notices(result_type, Some("ACTIVE"), None)
                    .expect("explicit non-notice result type"),
                (None, None)
            );
        }
    }

    #[test]
    fn unknown_search_result_types_fail_closed() {
        let unknown = json!({
            "resultType": "FUTURE_TYPE",
            "nonConclusion": null,
            "interpretationNotice": null
        });

        assert!(matches!(
            search_result_notices("FUTURE_TYPE", Some("ACTIVE"), None),
            Err(ServiceError::Persistence)
        ));
        assert!(matches!(
            page_seo_description(
                "검색",
                &[unknown],
                PageNoticeAuthority::SearchCollection
            ),
            Err(ServiceError::Persistence)
        ));
    }

    #[test]
    fn nonempty_pages_reject_missing_authoritative_notices() {
        assert!(matches!(
            page_seo_description(
                "기관 대장",
                &[json!({"agencyType":"CENTRAL"})],
                PageNoticeAuthority::OperationalCollection
            ),
            Err(ServiceError::Persistence)
        ));
        assert!(matches!(
            page_seo_description(
                "기관 대장",
                &[json!({
                    "agencyType":"CENTRAL",
                    "interpretationNotice":"상태 값은 단순 참고입니다."
                })],
                PageNoticeAuthority::OperationalCollection
            ),
            Err(ServiceError::Persistence)
        ));
        assert!(matches!(
            page_seo_description(
                "공개 사건",
                &[json!({"publicState":"PUBLISHED_ANOMALY"})],
                PageNoticeAuthority::PublicationCollection
            ),
            Err(ServiceError::Persistence)
        ));
    }

    #[test]
    fn seo_uses_only_rows_returned_in_the_current_page() {
        let authority = serde_json::Map::new();
        let anomaly = non_conclusion("PUBLISHED_ANOMALY", &authority)
            .expect("evidence-independent anomaly notice");
        let retracted = non_conclusion("RETRACTED", &authority)
            .expect("evidence-independent retraction notice");
        let query = Query {
            limit: 1,
            ..Query::default()
        };
        let page = page_with_notice_seo(
            vec![
                json!({"publicState":"PUBLISHED_ANOMALY","nonConclusion":&anomaly}),
                json!({"publicState":"RETRACTED","nonConclusion":&retracted}),
            ],
            &query,
            json!({}),
            "공개 사건",
            "/cases".to_owned(),
            PageNoticeAuthority::PublicationCollection,
        )
        .expect("bounded public page");

        assert_eq!(page["items"].as_array().map(Vec::len), Some(1));
        assert_eq!(page["seo"]["description"], format!("공개 사건 · {anomaly}"));
        assert!(!page["seo"]["description"]
            .as_str()
            .is_some_and(|description| description.contains(&retracted)));
    }
}
