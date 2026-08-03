fn verified_test_funding_report(row: FundingReportRow) -> Option<VerifiedFundingReport> {
    let result = verify_funding_report(row);
    assert!(result.is_ok(), "fixture report must validate");
    result.ok()
}

fn rendered_test_funding_download(
    report: &VerifiedFundingReport,
    format: FundingDownloadFormat,
) -> Option<Value> {
    let result = render_funding_report_download(report, format);
    assert!(result.is_ok(), "download envelope must render");
    result.ok()
}

fn decoded_test_funding_download(envelope: &Value) -> Option<Vec<u8>> {
    let encoded = envelope["contentBase64"].as_str();
    assert!(encoded.is_some(), "base64 field must exist");
    let decoded = base64::engine::general_purpose::STANDARD.decode(encoded?);
    assert!(decoded.is_ok(), "base64 must decode");
    decoded.ok()
}

#[test]
fn report_download_is_deterministic_and_bound_to_public_digests() {
    let Some(report) = verified_test_funding_report(fixture_row()) else {
        return;
    };
    let first = render_funding_report_download(&report, FundingDownloadFormat::Json);
    let second = render_funding_report_download(&report, FundingDownloadFormat::Json);
    assert_eq!(first.as_ref().ok(), second.as_ref().ok());
    assert!(first.is_ok(), "download envelope must render");
    let Some(envelope) = first.ok() else {
        return;
    };
    let Some(bytes) = decoded_test_funding_download(&envelope) else {
        return;
    };
    assert_eq!(envelope["byteLength"], bytes.len());
    assert_eq!(envelope["contentSha256"], hex(&Sha256::digest(&bytes)));
    assert_eq!(
        envelope["filename"],
        "gurine-funding-transparency-00000000-0000-0000-0000-000000000001.json"
    );
    assert_eq!(envelope["reportKind"], FUNDING_REPORT_KIND);
    assert_eq!(envelope["revision"], 1);
    assert_eq!(envelope["notice"], PUBLIC_REDISTRIBUTION_NOTICE);
    assert_eq!(envelope["format"], "JSON");
    assert_eq!(envelope["rowCount"], 1);
    assert!(exact_object_keys(
        &envelope,
        &[
            "reportId",
            "status",
            "reportKind",
            "revision",
            "notice",
            "filename",
            "mediaType",
            "byteLength",
            "contentSha256",
            "contentBase64",
            "format",
            "rowCount",
            "sourceRevisionDigest",
            "projectionDigest",
            "publicContentDigest",
            "generatedAt",
        ]
    ));
    assert!(envelope.get("id").is_none());
    assert!(envelope.get("sourceRevision").is_none());
    assert!(envelope.get("bytes").is_none());
    let artifact: Result<Value, _> = serde_json::from_slice(&bytes);
    assert!(artifact.as_ref().is_ok_and(|artifact| {
        artifact["reportId"] == envelope["reportId"]
            && artifact["sourceRevisionDigest"] == envelope["sourceRevisionDigest"]
            && artifact["projectionDigest"] == envelope["projectionDigest"]
    }));
    let text = String::from_utf8_lossy(&bytes);
    assert!(text.contains(FUNDING_INDEPENDENCE_NOTICE));
    for forbidden in ["billingKey", "providerPaymentId", "donorId", "customerId"] {
        assert!(!text.contains(forbidden));
    }
}

#[test]
fn csv_download_is_deterministic_and_contains_only_approved_public_fields() {
    let Some(report) = verified_test_funding_report(fixture_row()) else {
        return;
    };
    let Some(envelope) = rendered_test_funding_download(&report, FundingDownloadFormat::Csv) else {
        return;
    };
    let Some(bytes) = decoded_test_funding_download(&envelope) else {
        return;
    };
    assert_eq!(envelope["mediaType"], "text/csv");
    assert_eq!(envelope["format"], "CSV");
    assert_eq!(envelope["rowCount"], 1);
    assert!(bytes.starts_with(FUNDING_INDEPENDENCE_NOTICE.as_bytes()));
    let text = String::from_utf8_lossy(&bytes);
    for field in [
        "reportId",
        "sourceRevisionDigest",
        "projectionDigest",
        "publicContentDigest",
    ] {
        let value = envelope[field].as_str();
        assert!(value.is_some(), "binding field must be a string");
        if let Some(value) = value {
            assert!(text.contains(value));
        }
    }
    for forbidden in ["providerPaymentId", "billingKey", "donorId", "customerId"] {
        assert!(!text.contains(forbidden));
    }
}

#[test]
fn report_list_item_uses_only_the_closed_schema_and_canonical_download_href() {
    let Some(report) = verified_test_funding_report(fixture_row()) else {
        return;
    };
    let item = funding_report_item(report);
    assert!(item.is_ok(), "report list item must render");
    let Some(item) = item.ok() else {
        return;
    };
    assert!(exact_object_keys(
        &item,
        &[
            "id",
            "periodStart",
            "periodEnd",
            "title",
            "summary",
            "publishedAt",
            "href",
        ]
    ));
    assert_eq!(
        item["href"],
        "/v1/transparency-reports/00000000-0000-0000-0000-000000000001/download"
    );
}

#[test]
fn non_funding_report_download_fails_with_precondition_error() {
    let mut row = fixture_row();
    row.report_kind = "GENERAL".to_owned();
    assert!(matches!(
        ensure_funding_report_kind(&row),
        Err(ServiceError::ReportPreconditionFailed)
    ));
}

#[test]
fn malformed_funding_report_download_fails_without_a_partial_envelope() {
    let mut row = fixture_row();
    row.projection_digest = Some("0".repeat(64));
    assert!(matches!(
        verify_ready_funding_report(row),
        Err(ServiceError::ReportPreconditionFailed)
    ));
}

#[test]
fn download_query_rejects_unknown_duplicate_or_empty_parameters() {
    assert!(matches!(
        FundingDownloadFormat::parse(&funding_download_query(&[])),
        Ok(FundingDownloadFormat::Json)
    ));
    assert!(matches!(
        FundingDownloadFormat::parse(&funding_download_query(&[("format", &["CSV"])])),
        Ok(FundingDownloadFormat::Csv)
    ));
    for query in [
        funding_download_query(&[("unexpected", &["value"])]),
        funding_download_query(&[("format", &["JSON", "CSV"])]),
        funding_download_query(&[("format", &[])]),
    ] {
        assert!(matches!(
            FundingDownloadFormat::parse(&query),
            Err(ServiceError::InvalidRequest)
        ));
    }
    for uri in [
        "/download?format=CSV&format=JSON",
        "/download?format=CSV&format=",
        "/download?format=CSV,",
        "/download?unexpected=value",
    ] {
        let query = parsed_query(uri).and_then(|query| FundingDownloadFormat::parse(&query));
        assert!(matches!(query, Err(ServiceError::InvalidRequest)));
    }
}

#[test]
fn transparency_list_query_is_closed_and_honors_the_contract_limit() {
    for uri in [
        "/v1/transparency-reports?sort=published_desc&sort=period_desc",
        "/v1/transparency-reports?periodFrom=",
        "/v1/transparency-reports?unexpected=value",
        "/v1/transparency-reports?limit=101",
    ] {
        let query = parsed_query(uri).and_then(|query| {
            validate_funding_list_query(&query)?;
            Ok(query)
        });
        assert!(matches!(query, Err(ServiceError::InvalidRequest)));
    }
    let valid = parsed_query(
        "/v1/transparency-reports?limit=100&periodFrom=2026-01-01&periodTo=2026-12-31&sort=period_desc",
    );
    assert!(
        valid
            .as_ref()
            .is_ok_and(|query| validate_funding_list_query(query).is_ok())
    );
}

#[test]
fn csv_download_neutralizes_spreadsheet_formula_prefixes() {
    let mut row = fixture_row();
    row.report["entries"][0]["counterpartyCategory"] = json!("\t=1+1");
    row.projection_digest = Some(
        funding_projection_digest(
            &row,
            row.source_revision_id.unwrap_or(Uuid::nil()),
            row.source_disclosure_id.unwrap_or(Uuid::nil()),
            row.source_revision.unwrap_or_default(),
            row.source_revision_digest.as_deref().unwrap_or_default(),
        )
        .unwrap_or_default(),
    );
    let Some(report) = verified_test_funding_report(row) else {
        return;
    };
    let Some(envelope) = rendered_test_funding_download(&report, FundingDownloadFormat::Csv) else {
        return;
    };
    let Some(bytes) = decoded_test_funding_download(&envelope) else {
        return;
    };
    let text = String::from_utf8_lossy(&bytes);
    assert!(text.contains("'\t=1+1"));
    for value in ["=1+1", "+1+1", "-1+1", "@SUM(A1:A2)", "  =1+1"] {
        assert!(funding_csv_cell(value).starts_with('\''));
    }
}

#[test]
fn empty_public_entry_set_is_not_materialized_as_a_fake_csv_row() {
    let mut row = fixture_row();
    row.report["entries"] = json!([]);
    row.projection_digest = Some(
        funding_projection_digest(
            &row,
            row.source_revision_id.unwrap_or(Uuid::nil()),
            row.source_disclosure_id.unwrap_or(Uuid::nil()),
            row.source_revision.unwrap_or_default(),
            row.source_revision_digest.as_deref().unwrap_or_default(),
        )
        .unwrap_or_default(),
    );
    let Some(report) = verified_test_funding_report(row) else {
        return;
    };
    let Some(envelope) = rendered_test_funding_download(&report, FundingDownloadFormat::Csv) else {
        return;
    };
    let Some(bytes) = decoded_test_funding_download(&envelope) else {
        return;
    };
    assert_eq!(envelope["rowCount"], 0);
    assert_eq!(String::from_utf8_lossy(&bytes).lines().count(), 2);
}
