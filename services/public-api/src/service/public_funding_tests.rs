#[cfg(test)]
mod public_funding_tests {
    use super::*;

    fn fixture_report() -> Value {
        json!({
            "schemaVersion":1,
            "disclosureId":"00000000-0000-4000-8000-000000000010",
            "revision":1,
            "fiscalYear":2026,
            "fiscalQuarter":1,
            "periodStart":"2026-01-01",
            "periodEnd":"2026-04-01",
            "reportingCurrency":"KRW",
            "concentrationBand":"UNKNOWN",
            "caveat":"승인된 분모가 없어 집중도를 산출하지 않습니다.",
            "purpose":"독립 승인된 테스트 공개 재원",
            "policyRequests":{"total":0,"accepted":0,"partiallyAccepted":0,"rejected":0,"withdrawn":0,"pending":0,"outcomeDigest":"1".repeat(64)},
            "sources":["https://example.test/public-funding-evidence"],
            "entries":[{
                "ordinal":1,
                "identityDisclosureMode":"CATEGORY_ONLY",
                "publicDisplayName":null,
                "withholdingPublicExplanation":"명명 기준 미만 범주 공개",
                "counterpartyCategory":"개인 후원",
                "fundingSourceKind":"DONATION",
                "amountBandLower":"10000.000000",
                "amountBandUpper":"50000.000000",
                "reportingCurrency":"KRW",
                "concentrationBand":"UNKNOWN",
                "denominatorUnknownReason":"APPROVAL_MISSING",
                "groupingDisputeReason":null,
                "concentrationUnknownReason":"DENOMINATOR_UNKNOWN",
                "publicCaveatText":"승인된 분모가 없습니다.",
                "purpose":"공익 플랫폼 운영",
                "conflictDisclosure":"조사 우선순위와 분리",
                "mitigationSummary":"독립 검토와 공개",
                "governmentRelated":false,
                "politicalPartyRelated":false,
                "procurementSupplierRelated":false,
                "investigatedSubjectRelated":false,
                "relatedParty":false,
                "publicCaseRefs":[],
                "publicSourceLinks":["https://example.test/public-funding-evidence"],
                "entryDigest":"2".repeat(64)
            }],
            "effectiveAt":"2026-04-02T00:00:00Z",
            "publishedAt":"2026-04-02T00:00:00Z",
            "supersedesRevision":null,
            "sourceRevisionDigest":"3".repeat(64),
            "publicContentDigest":"4".repeat(64)
        })
    }

    fn fixture_row() -> FundingReportRow {
        let mut row = FundingReportRow {
            id: Uuid::from_u128(1),
            period_start: parse_date("2026-01-01").unwrap_or(Date::MIN),
            period_end: parse_date("2026-04-01").unwrap_or(Date::MIN),
            title: "2026년 1분기 재원 공개".to_owned(),
            summary: "승인된 재원 공개 개정본".to_owned(),
            report: fixture_report(),
            published_at: parse_timestamp("2026-04-02T00:00:00Z")
                .unwrap_or(OffsetDateTime::UNIX_EPOCH),
            report_kind: FUNDING_REPORT_KIND.to_owned(),
            source_revision_id: Some(Uuid::from_u128(2)),
            source_disclosure_id: Some(
                Uuid::parse_str("00000000-0000-4000-8000-000000000010").unwrap_or(Uuid::nil()),
            ),
            source_revision: Some(1),
            source_revision_digest: Some("3".repeat(64)),
            supersedes_report_id: None,
            report_schema_version: Some(1),
            projection_digest: None,
            projected_at: Some(
                parse_timestamp("2026-04-02T00:00:01Z").unwrap_or(OffsetDateTime::UNIX_EPOCH),
            ),
            supersedes_binding_valid: true,
        };
        let digest = funding_projection_digest(
            &row,
            row.source_revision_id.unwrap_or(Uuid::nil()),
            row.source_disclosure_id.unwrap_or(Uuid::nil()),
            row.source_revision.unwrap_or_default(),
            row.source_revision_digest.as_deref().unwrap_or_default(),
        )
        .unwrap_or_default();
        row.projection_digest = Some(digest);
        row
    }

    fn funding_download_query(values: &[(&str, &[&str])]) -> Query {
        let values = values
            .iter()
            .map(|(name, values)| {
                (
                    (*name).to_owned(),
                    values.iter().map(|value| (*value).to_owned()).collect(),
                )
            })
            .collect();
        Query {
            values,
            offset: 0,
            limit: 20,
        }
    }

    fn parsed_query(uri: &str) -> Result<Query, ServiceError> {
        Query::parse(&actix_web::test::TestRequest::with_uri(uri).to_http_request())
    }

    #[test]
    fn approved_public_report_round_trips_exact_binding() {
        let row = fixture_row();
        assert!(exact_object_keys(&row.report, FUNDING_REPORT_FIELDS));
        let disclosure = serde_json::from_value::<FundingDisclosurePublicV1>(row.report.clone());
        assert!(disclosure.as_ref().is_ok());
        if let Ok(disclosure) = disclosure {
            assert!(validate_disclosure(&disclosure).is_ok());
        }
        let report = verify_funding_report(row);
        assert!(report.as_ref().is_ok_and(|report| {
            report.disclosure.entries.len() == 1
                && report.disclosure.entries[0].funding_source_kind == "DONATION"
                && report.source_revision_digest == "3".repeat(64)
        }));
    }

    #[test]
    fn malformed_or_digest_mismatched_reports_fail_closed() {
        let mut digest_mismatch = fixture_row();
        digest_mismatch.projection_digest = Some("0".repeat(64));
        assert!(matches!(
            verify_funding_report(digest_mismatch),
            Err(ServiceError::Persistence)
        ));

        let mut source_mismatch = fixture_row();
        source_mismatch.report["sourceRevisionDigest"] = json!("9".repeat(64));
        assert!(matches!(
            verify_funding_report(source_mismatch),
            Err(ServiceError::Persistence)
        ));

        let mut broken_predecessor = fixture_row();
        broken_predecessor.supersedes_binding_valid = false;
        assert!(matches!(
            verify_funding_report(broken_predecessor),
            Err(ServiceError::Persistence)
        ));

        let mut private_field = fixture_row();
        private_field.report["entries"][0]["providerPaymentId"] = json!("private");
        assert!(matches!(
            verify_funding_report(private_field),
            Err(ServiceError::Persistence)
        ));
    }

    #[test]
    fn outer_projection_digest_binds_every_opaque_inner_digest() {
        let mut public_content = fixture_row();
        public_content.report["publicContentDigest"] = json!("8".repeat(64));
        let mut policy_outcome = fixture_row();
        policy_outcome.report["policyRequests"]["outcomeDigest"] = json!("8".repeat(64));
        let mut entry = fixture_row();
        entry.report["entries"][0]["entryDigest"] = json!("8".repeat(64));
        for candidate in [public_content, policy_outcome, entry] {
            assert!(matches!(
                verify_funding_report(candidate),
                Err(ServiceError::Persistence)
            ));
        }
    }

    #[test]
    fn raw_internal_identifiers_and_unsafe_links_are_rejected() {
        let mut raw_case_id = fixture_row();
        raw_case_id.report["entries"][0]["publicCaseRefs"] =
            json!(["00000000-0000-4000-8000-000000000099"]);
        raw_case_id.projection_digest = Some(
            funding_projection_digest(
                &raw_case_id,
                raw_case_id.source_revision_id.unwrap_or(Uuid::nil()),
                raw_case_id.source_disclosure_id.unwrap_or(Uuid::nil()),
                raw_case_id.source_revision.unwrap_or_default(),
                raw_case_id
                    .source_revision_digest
                    .as_deref()
                    .unwrap_or_default(),
            )
            .unwrap_or_default(),
        );
        assert!(matches!(
            verify_funding_report(raw_case_id),
            Err(ServiceError::Persistence)
        ));

        let mut credentialed_link = fixture_row();
        credentialed_link.report["sources"] = json!(["https://user:secret@example.test/source"]);
        credentialed_link.projection_digest = Some(
            funding_projection_digest(
                &credentialed_link,
                credentialed_link.source_revision_id.unwrap_or(Uuid::nil()),
                credentialed_link
                    .source_disclosure_id
                    .unwrap_or(Uuid::nil()),
                credentialed_link.source_revision.unwrap_or_default(),
                credentialed_link
                    .source_revision_digest
                    .as_deref()
                    .unwrap_or_default(),
            )
            .unwrap_or_default(),
        );
        assert!(matches!(
            verify_funding_report(credentialed_link),
            Err(ServiceError::Persistence)
        ));
    }

    #[test]
    fn expense_projection_remains_unavailable_without_public_authority() {
        let report = verify_funding_report(fixture_row());
        assert!(report.is_ok(), "fixture report must validate");
        let Some(report) = report.ok() else {
            return;
        };
        let content = render_funding_content(report);
        assert!(content.as_ref().is_ok_and(|value| {
            value["data"]["sections"]
                .as_array()
                .and_then(|sections| sections.iter().find(|section| section["id"] == "expenses"))
                .and_then(|section| section["body"].as_str())
                == Some(PUBLIC_FUNDING_EXPENSE_AUTHORITY_NOTICE)
        }));
    }

    #[test]
    fn human_funding_labels_are_closed_and_korean() {
        for (raw, label) in [
            ("UNKNOWN", "확인 불가"),
            ("LE_5_PERCENT", "5% 이하"),
            ("GT_5_TO_15_PERCENT", "5% 초과 15% 이하"),
            ("GT_15_TO_25_PERCENT", "15% 초과 25% 이하"),
            ("GT_25_PERCENT", "25% 초과"),
        ] {
            assert_eq!(concentration_band_label(raw).ok(), Some(label));
        }
        for (raw, label) in [
            ("DONATION", "후원"),
            ("GRANT", "지원금"),
            ("INSTITUTIONAL_CUSTOMER_REVENUE", "기관 고객 수익"),
            ("COMMERCIAL_CUSTOMER_REVENUE", "상용 고객 수익"),
            ("SPONSORSHIP", "협찬"),
            ("OTHER_REVIEWED", "기타 검토 승인 재원"),
            ("MIXED", "혼합 재원"),
        ] {
            assert_eq!(funding_source_kind_label(raw).ok(), Some(label));
        }
        assert!(concentration_band_label("NEW_BAND").is_err());
        assert!(funding_source_kind_label("NEW_SOURCE").is_err());
    }

    #[test]
    fn public_funding_copy_hides_machine_tokens_and_preserves_independence_notice() {
        let report = verify_funding_report(fixture_row());
        assert!(report.is_ok(), "fixture report must validate");
        let Some(report) = report.ok() else {
            return;
        };
        let content = render_funding_content(report);
        assert!(content.is_ok(), "funding content must render");
        let Some(content) = content.ok() else {
            return;
        };
        let sections = content["data"]["sections"].as_array();
        assert!(sections.is_some(), "sections must be present");
        let copy = sections
            .into_iter()
            .flatten()
            .filter_map(|section| section["body"].as_str())
            .chain(content["summary"].as_str())
            .collect::<Vec<_>>()
            .join("\n");
        for forbidden in [
            "UNKNOWN",
            "UNAVAILABLE",
            "disclosure",
            "projection",
            "revision",
            "API/SaaS",
            "grant",
        ] {
            assert!(
                !copy.contains(forbidden),
                "leaked public token: {forbidden}"
            );
        }
        assert_eq!(
            sections
                .and_then(|sections| sections.first())
                .and_then(|section| section["body"].as_str()),
            Some(FUNDING_INDEPENDENCE_NOTICE)
        );

        let unknown = render_unknown_funding_content();
        assert!(unknown.is_ok(), "unknown funding content must render");
        let Some(unknown) = unknown.ok() else {
            return;
        };
        let unknown_copy = unknown["data"]["sections"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|section| section["body"].as_str())
            .chain(unknown["summary"].as_str())
            .collect::<Vec<_>>()
            .join("\n");
        for forbidden in [
            "UNKNOWN",
            "UNAVAILABLE",
            "disclosure",
            "projection",
            "revision",
            "API/SaaS",
            "grant",
        ] {
            assert!(
                !unknown_copy.contains(forbidden),
                "leaked unknown-state public token: {forbidden}"
            );
        }
    }

    include!("public_funding_download_tests.rs");
}
