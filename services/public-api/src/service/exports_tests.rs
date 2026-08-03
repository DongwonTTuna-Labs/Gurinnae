#[cfg(test)]
mod export_tests {
    use super::*;

    #[test]
    fn region_binding_excludes_array_only_and_missing_scalar_agencies() {
        let matching_agency = "11111111-1111-4111-8111-111111111111";
        let other_agency = "22222222-2222-4222-8222-222222222222";
        let scalar_agency = |payload: &Value| {
            payload
                .get("agencyId")
                .and_then(Value::as_str)
                .map(str::to_owned)
        };

        assert_eq!(
            scalar_agency(&json!({
                "agencyId": matching_agency,
                "agencyIds": [other_agency]
            })),
            Some(matching_agency.to_owned())
        );
        assert_eq!(
            scalar_agency(&json!({"agencyIds": [matching_agency, other_agency]})),
            None
        );
        assert_eq!(scalar_agency(&json!({})), None);
        assert_ne!(
            scalar_agency(&json!({
                "agencyId": other_agency,
                "agencyIds": [matching_agency]
            }))
            .as_deref(),
            Some(matching_agency)
        );

        let source = [
            include_str!("cases.rs"),
            include_str!("public_search.rs"),
            include_str!("exports.rs"),
        ]
        .concat();
        let scalar_region_predicate = [
            "EXISTS(SELECT 1 FROM public.agencies a WHERE r.payload->>'agency",
            "Id'=a.id::text AND",
        ]
        .concat();
        let legacy_array_region_predicate = [
            "EXISTS(SELECT 1 FROM public.agencies a WHERE (r.payload->>'agency",
            "Id'=a.id::text OR ",
            "COALESCE(r.payload->'agencyIds','[]'::jsonb) ? a.id::text)",
        ]
        .concat();
        assert_eq!(source.matches(&scalar_region_predicate).count(), 6);
        assert!(!source.contains(&legacy_array_region_predicate));
    }

    #[test]
    fn export_limit_is_inclusive_and_fails_closed_above_cap() {
        assert!(enforce_export_limit(5_000).is_ok());
        assert!(matches!(
            enforce_export_limit(5_001),
            Err(ServiceError::PreconditionFailed)
        ));
    }

    #[test]
    fn csv_is_crlf_delimited_and_escapes_each_logical_cell() {
        let rows = [json!({"title":"쉼표, 따옴표 \"와\"\n줄바꿈","count":2})];
        let bytes = render_csv(&[("title", "title"), ("count", "count")], &rows);
        let rendered = String::from_utf8(bytes).expect("CSV is UTF-8");
        assert_eq!(
            rendered,
            concat!(
                "이상 징후 기록이며 위법·부패의 확정이 아님\r\n",
                "title,count\r\n",
                "\"쉼표, 따옴표 \"\"와\"\"\n줄바꿈\",2\r\n"
            )
        );
    }

    #[test]
    fn jsonl_starts_with_notice_and_keeps_one_object_per_line() {
        let rows = [json!({"id":"case-1"}), json!({"id":"case-2"})];
        let bytes = render_jsonl(&rows).expect("JSONL renders");
        let lines = std::str::from_utf8(&bytes)
            .expect("JSONL is UTF-8")
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).expect("valid JSON object"))
            .collect::<Vec<_>>();
        assert_eq!(lines.len(), 3);
        assert_eq!(lines[0], json!({"notice": PUBLIC_REDISTRIBUTION_NOTICE}));
        assert_eq!(lines[2], rows[1]);
    }

    #[test]
    fn exported_rows_keep_status_adjacent_notices() {
        let case = case_card(CaseCardRow {
            slug: "case-1".to_owned(),
            title: "공개 사건".to_owned(),
            public_state: "PUBLISHED_ANOMALY".to_owned(),
            summary: "공개 요약".to_owned(),
            latest_revision: 1,
            updated_at: OffsetDateTime::UNIX_EPOCH,
            response_status: None,
            correction_status: None,
            payload: json!({}),
        })
        .expect("case export row");
        assert_eq!(
            case["nonConclusion"],
            "공개자료 비교에서 설명이 필요한 차이가 확인됐습니다. 현재 자료만으로 위법성이나 부패 여부를 판단할 수 없습니다."
        );

        let search_row = search_export_value(SearchExportRow {
            result_type: "CONTRACT".to_owned(),
            id: "contract-1".to_owned(),
            title: "공개 계약".to_owned(),
            subtitle: None,
            status: Some("ACTIVE".to_owned()),
            summary: None,
            updated_at: None,
            href: "/contracts/contract-1".to_owned(),
            notice_payload: None,
        })
        .expect("search export row");
        assert_eq!(
            search_row["interpretationNotice"],
            OPERATIONAL_INTERPRETATION_NOTICE
        );

        let source_search_row = search_export_value(SearchExportRow {
            result_type: "SOURCE".to_owned(),
            id: "source-1".to_owned(),
            title: "공개 출처".to_owned(),
            subtitle: None,
            status: Some("CURRENT".to_owned()),
            summary: Some("정상 수집 중".to_owned()),
            updated_at: None,
            href: "/sources/source-1".to_owned(),
            notice_payload: None,
        })
        .expect("source search export row");
        assert_eq!(
            source_search_row["interpretationNotice"],
            OPERATIONAL_INTERPRETATION_NOTICE
        );

        let contract = contract_export_value(ContractSummaryRow {
            id: Uuid::nil(),
            contract_number: Some("G-001".to_owned()),
            title: "공개 계약".to_owned(),
            agency_id: Some(Uuid::nil()),
            supplier_id: None,
            status: "ACTIVE".to_owned(),
            signed_at: None,
            amount: None,
            agency_name: Some("가상 공공기관".to_owned()),
            supplier_name: None,
        })
        .expect("contract export row");
        assert_eq!(
            contract["interpretationNotice"],
            OPERATIONAL_INTERPRETATION_NOTICE
        );

        assert!(CASE_EXPORT_COLUMNS.contains(&("nonConclusion", "nonConclusion")));
        assert!(SEARCH_EXPORT_COLUMNS.contains(&("interpretationNotice", "interpretationNotice")));
        assert!(
            CONTRACT_EXPORT_COLUMNS.contains(&("interpretationNotice", "interpretationNotice"))
        );
    }

    #[test]
    fn envelope_metadata_keeps_non_conclusion_and_operational_notices_distinct() {
        let anomaly_notice = "공개자료 비교에서 설명이 필요한 차이가 확인됐습니다. 현재 자료만으로 위법성이나 부패 여부를 판단할 수 없습니다.";
        let explained_notice = "처음 탐지된 차이는 추가 자료에서 확인된 구성·서비스·조건의 차이로 설명됩니다. 탐지와 검증 과정을 함께 공개합니다.";
        let case_notices = export_envelope_notices(
            "public-cases",
            &[
                json!({"nonConclusion": anomaly_notice}),
                json!({"nonConclusion": anomaly_notice}),
                json!({"nonConclusion": explained_notice}),
            ],
        )
        .expect("case envelope notices");
        assert_eq!(
            case_notices.non_conclusion_notices,
            vec![anomaly_notice.to_owned(), explained_notice.to_owned()]
        );
        assert_eq!(case_notices.interpretation_notice, None);

        let contract_notices = export_envelope_notices("contracts", &[])
            .expect("empty contract export still has its operational notice");
        assert!(contract_notices.non_conclusion_notices.is_empty());
        assert_eq!(
            contract_notices.interpretation_notice,
            Some(OPERATIONAL_INTERPRETATION_NOTICE)
        );
        assert!(matches!(
            export_envelope_notices("contracts", &[json!({"interpretationNotice": "다른 문구"})],),
            Err(ServiceError::Persistence)
        ));

        let search_notices = export_envelope_notices(
            "public-search-records",
            &[
                json!({
                    "nonConclusion": anomaly_notice,
                    "interpretationNotice": null,
                }),
                json!({
                    "nonConclusion": null,
                    "interpretationNotice": OPERATIONAL_INTERPRETATION_NOTICE,
                }),
                json!({
                    "nonConclusion": anomaly_notice,
                    "interpretationNotice": OPERATIONAL_INTERPRETATION_NOTICE,
                }),
            ],
        )
        .expect("search envelope notices");
        assert_eq!(
            search_notices.non_conclusion_notices,
            vec![anomaly_notice.to_owned()]
        );
        assert_eq!(
            search_notices.interpretation_notice,
            Some(OPERATIONAL_INTERPRETATION_NOTICE)
        );
    }

    #[test]
    fn case_envelope_requires_nonempty_non_conclusion_on_every_data_row() {
        let empty = export_envelope_notices("public-cases", &[])
            .expect("an empty case export has no state notices");
        assert!(empty.non_conclusion_notices.is_empty());
        assert_eq!(empty.interpretation_notice, None);

        for (label, row) in [
            ("missing", json!({})),
            ("null", json!({"nonConclusion": null})),
            ("blank", json!({"nonConclusion": " \t\n "})),
            ("wrong type", json!({"nonConclusion": ["고지"]})),
        ] {
            assert!(
                matches!(
                    export_envelope_notices("public-cases", &[row]),
                    Err(ServiceError::Persistence)
                ),
                "case row with {label} nonConclusion must fail closed"
            );
        }
    }

    #[test]
    fn response_has_exact_fields_and_digest_covers_file_bytes() {
        let state_notice = "공개자료 비교에서 설명이 필요한 차이가 확인됐습니다. 현재 자료만으로 위법성이나 부패 여부를 판단할 수 없습니다.";
        let response = render_export(
            "public-cases",
            PublicExportFormat::Jsonl,
            &CASE_EXPORT_COLUMNS,
            &[json!({"slug":"case-1","nonConclusion":state_notice})],
            json!({"sort":"updated_desc"}),
        )
        .expect("export response");
        let object = response.as_object().expect("response object");
        let fields = object
            .keys()
            .map(String::as_str)
            .collect::<std::collections::BTreeSet<_>>();
        assert_eq!(
            fields,
            std::collections::BTreeSet::from([
                "appliedFilters",
                "byteLength",
                "contentBase64",
                "contentSha256",
                "filename",
                "format",
                "generatedAt",
                "id",
                "interpretationNotice",
                "mediaType",
                "nonConclusionNotices",
                "notice",
                "rowCount",
                "status",
                "version",
            ])
        );
        assert_eq!(response["notice"], PUBLIC_REDISTRIBUTION_NOTICE);
        assert_eq!(response["nonConclusionNotices"], json!([state_notice]));
        assert_eq!(response["interpretationNotice"], Value::Null);
        let content = base64::engine::general_purpose::STANDARD
            .decode(
                response
                    .get("contentBase64")
                    .and_then(Value::as_str)
                    .expect("base64 content"),
            )
            .expect("valid base64");
        assert_eq!(response["byteLength"], content.len());
        assert_eq!(response["contentSha256"], hex(&Sha256::digest(&content)));
        assert_eq!(response["rowCount"], 1);
        let records = std::str::from_utf8(&content)
            .expect("JSONL is UTF-8")
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).expect("valid JSONL record"))
            .collect::<Vec<_>>();
        assert_eq!(records[0], json!({"notice": PUBLIC_REDISTRIBUTION_NOTICE}));
        assert_eq!(records[1]["nonConclusion"], state_notice);
    }

    #[test]
    fn download_envelope_rejects_artifact_bytes_without_notice() {
        for (format, extension, bytes) in [
            ("CSV", "csv", b"slug\r\ncase-1\r\n".as_slice()),
            ("JSON", "json", br#"{"data":{"slug":"case-1"}}"#.as_slice()),
            ("JSONL", "jsonl", b"{\"slug\":\"case-1\"}\n".as_slice()),
        ] {
            assert!(matches!(
                render_download_bytes(
                    "public-cases",
                    format,
                    extension,
                    "application/octet-stream",
                    bytes.to_vec(),
                    1,
                    json!({}),
                ),
                Err(ServiceError::Persistence)
            ));
        }
    }
}
