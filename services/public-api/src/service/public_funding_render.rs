fn render_funding_content(report: VerifiedFundingReport) -> Result<Value, ServiceError> {
    let updated_at = timestamp(report.projected_at)?;
    let disclosure_band = concentration_band_label(&report.disclosure.concentration_band)?;
    let entry_summary = report
        .disclosure
        .entries
        .iter()
        .map(|entry| -> Result<String, ServiceError> {
            let label = entry
                .public_display_name
                .as_deref()
                .unwrap_or(&entry.counterparty_category);
            Ok(format!(
                "{label} · {} · {} {} · 집중도 {}",
                funding_source_kind_label(&entry.funding_source_kind)?,
                amount_band(entry),
                entry.reporting_currency,
                concentration_band_label(&entry.concentration_band)?,
            ))
        })
        .collect::<Result<Vec<_>, _>>()?
        .join(" / ");
    let donor_body = if entry_summary.is_empty() {
        "승인된 공개 개정본에 공개 대상 재원 항목이 없습니다.".to_owned()
    } else {
        entry_summary
    };
    let caveat = report.disclosure.caveat.as_deref().unwrap_or("해당 없음");
    let source_links = funding_source_links(&report.disclosure);
    let sections = vec![
        json!({"id":"principles","heading":"독립성 원칙","body":FUNDING_INDEPENDENCE_NOTICE,"links":[{"rel":"policy","href":"/about/governance","label":"거버넌스와 독립성"}],"updatedAt":updated_at}),
        json!({"id":"income","heading":"재원","body":format!("{} · 집중도 {disclosure_band} · 주의사항 {caveat}",report.disclosure.purpose),"links":source_links.clone(),"updatedAt":updated_at}),
        json!({"id":"expenses","heading":"비용","body":PUBLIC_FUNDING_EXPENSE_AUTHORITY_NOTICE,"links":[],"updatedAt":updated_at}),
        json!({"id":"donors","heading":"공개 기준","body":donor_body,"links":source_links.clone(),"updatedAt":updated_at}),
        json!({"id":"conflicts","heading":"이해상충","body":format!("집중도 {disclosure_band} · {caveat}. {FUNDING_INDEPENDENCE_NOTICE}"),"links":[{"rel":"policy","href":"/about/governance","label":"역할 분리와 이해상충"}],"updatedAt":updated_at}),
        json!({"id":"reports","heading":"보고서","body":format!("{}년 {}분기 · 개정본 {}",report.disclosure.fiscal_year,report.disclosure.fiscal_quarter,report.disclosure.revision),"links":[{"rel":"download","href":format!("/v1/transparency-reports/{}/download",report.row.id),"label":"투명성 보고서 다운로드"}],"updatedAt":updated_at}),
    ];
    Ok(json!({
        "id":{"id":"funding","status":"PUBLISHED","version":report.disclosure.revision},
        "version":report.disclosure.revision,
        "status":"AVAILABLE",
        "updatedAt":updated_at,
        "title":"재원 공개",
        "summary":funding_revision_summary(report.disclosure.revision),
        "data":{"version":"1.0","title":"재원 공개","updatedAt":updated_at,"sections":sections,"sourceLinks":source_links},
        "links":[{"rel":"self","href":"/v1/content/funding"},{"rel":"reports","href":"/v1/transparency-reports"}],
    }))
}

fn render_unknown_funding_content() -> Result<Value, ServiceError> {
    let updated_at = now()?;
    let sections = vec![
        json!({"id":"principles","heading":"독립성 원칙","body":FUNDING_INDEPENDENCE_NOTICE,"links":[{"rel":"policy","href":"/about/governance","label":"거버넌스와 독립성"}],"updatedAt":updated_at}),
        json!({"id":"income","heading":"재원","body":"승인 개정본이 없어 재원 상태를 확인할 수 없습니다.","links":[],"updatedAt":updated_at}),
        json!({"id":"expenses","heading":"비용","body":PUBLIC_FUNDING_EXPENSE_AUTHORITY_NOTICE,"links":[],"updatedAt":updated_at}),
        json!({"id":"donors","heading":"공개 기준","body":"승인 개정본이 없어 후원 공개 상태를 확인할 수 없습니다.","links":[],"updatedAt":updated_at}),
        json!({"id":"conflicts","heading":"이해상충","body":"공개 개정본이 없어 이해상충 상태를 확인할 수 없습니다.","links":[{"rel":"policy","href":"/about/governance","label":"역할 분리와 이해상충"}],"updatedAt":updated_at}),
        json!({"id":"reports","heading":"보고서","body":"승인 보고서가 없습니다.","links":[],"updatedAt":updated_at}),
    ];
    Ok(json!({
        "id":{"id":"funding","status":"UNKNOWN","version":1},"version":1,"status":"UNKNOWN",
        "updatedAt":updated_at,"title":"재원 공개","summary":"승인된 공개 재원 개정본을 기다리고 있습니다.",
        "data":{"version":"1.0","title":"재원 공개","updatedAt":updated_at,"sections":sections,"sourceLinks":[]},
        "links":[{"rel":"self","href":"/v1/content/funding"},{"rel":"reports","href":"/v1/transparency-reports"}],
    }))
}

fn funding_report_item(report: VerifiedFundingReport) -> Result<Value, ServiceError> {
    let download_href = format!("/v1/transparency-reports/{}/download", report.row.id);
    Ok(json!({
        "id":report.row.id,
        "periodStart":report.row.period_start.to_string(),
        "periodEnd":report.row.period_end.to_string(),
        "title":report.row.title,
        "summary":funding_revision_summary(report.disclosure.revision),
        "publishedAt":timestamp(report.row.published_at)?,
        "href":download_href,
    }))
}

fn render_funding_report_download(
    report: &VerifiedFundingReport,
    format: FundingDownloadFormat,
) -> Result<Value, ServiceError> {
    let source_revision = report
        .row
        .source_revision
        .ok_or(ServiceError::Persistence)?;
    let artifact = FundingReportDownloadV1 {
        schema_version: FUNDING_REPORT_SCHEMA_VERSION,
        notice: FUNDING_INDEPENDENCE_NOTICE,
        report_id: report.row.id,
        source_revision,
        source_revision_digest: &report.source_revision_digest,
        projection_digest: &report.projection_digest,
        report: &report.disclosure,
    };
    let (bytes, row_count) = match format {
        FundingDownloadFormat::Json => (
            canonical_json_bytes(
                &serde_json::to_value(artifact).map_err(|_| ServiceError::Persistence)?,
            )?,
            1_usize,
        ),
        FundingDownloadFormat::Csv => render_funding_report_csv(report),
    };
    let content_sha256 = hex(&Sha256::digest(&bytes));
    Ok(json!({
        "reportId":report.row.id,
        "status":"READY",
        "reportKind":FUNDING_REPORT_KIND,
        "revision":source_revision,
        "notice":PUBLIC_REDISTRIBUTION_NOTICE,
        "filename":format!("gurine-funding-transparency-{}.{}",report.row.id,format.extension()),
        "mediaType":format.media_type(),
        "byteLength":bytes.len(),
        "contentSha256":content_sha256,
        "contentBase64":base64::engine::general_purpose::STANDARD.encode(&bytes),
        "format":format.label(),
        "rowCount":row_count,
        "sourceRevisionDigest":report.source_revision_digest,
        "projectionDigest":report.projection_digest,
        "publicContentDigest":report.disclosure.public_content_digest,
        "generatedAt":timestamp(report.projected_at)?,
    }))
}

fn render_funding_report_csv(report: &VerifiedFundingReport) -> (Vec<u8>, usize) {
    let mut output = String::new();
    output.push_str(
        &funding_csv_metadata_row(report)
            .iter()
            .map(|value| funding_csv_cell(value))
            .collect::<Vec<_>>()
            .join(","),
    );
    output.push_str("\r\n");
    output.push_str(
        &FUNDING_CSV_HEADERS
            .iter()
            .map(|heading| funding_csv_cell(heading))
            .collect::<Vec<_>>()
            .join(","),
    );
    output.push_str("\r\n");
    let rows = report
        .disclosure
        .entries
        .iter()
        .map(funding_csv_row)
        .collect::<Vec<_>>();
    for row in &rows {
        output.push_str(
            &row.iter()
                .map(|value| funding_csv_cell(value))
                .collect::<Vec<_>>()
                .join(","),
        );
        output.push_str("\r\n");
    }
    (output.into_bytes(), rows.len())
}

fn funding_csv_metadata_row(report: &VerifiedFundingReport) -> [String; 11] {
    [
        FUNDING_INDEPENDENCE_NOTICE.to_owned(),
        "reportId".to_owned(),
        report.row.id.to_string(),
        "revision".to_owned(),
        report.disclosure.revision.to_string(),
        "sourceRevisionDigest".to_owned(),
        report.source_revision_digest.clone(),
        "projectionDigest".to_owned(),
        report.projection_digest.clone(),
        "publicContentDigest".to_owned(),
        report.disclosure.public_content_digest.clone(),
    ]
}

const FUNDING_CSV_HEADERS: [&str; 20] = [
    "ordinal",
    "publicDisplay",
    "counterpartyCategory",
    "fundingSourceKind",
    "amountBandLower",
    "amountBandUpper",
    "reportingCurrency",
    "concentrationBand",
    "publicCaveat",
    "purpose",
    "conflictDisclosure",
    "mitigationSummary",
    "governmentRelated",
    "politicalPartyRelated",
    "procurementSupplierRelated",
    "investigatedSubjectRelated",
    "relatedParty",
    "publicCaseRefs",
    "publicSourceLinks",
    "entryDigest",
];

fn funding_csv_row(entry: &FundingDisclosurePublicEntryV1) -> [String; 20] {
    [
        entry.ordinal.to_string(),
        entry
            .public_display_name
            .as_deref()
            .unwrap_or(&entry.counterparty_category)
            .to_owned(),
        entry.counterparty_category.clone(),
        entry.funding_source_kind.clone(),
        entry.amount_band_lower.clone(),
        entry.amount_band_upper.clone().unwrap_or_default(),
        entry.reporting_currency.clone(),
        entry.concentration_band.clone(),
        entry.public_caveat_text.clone().unwrap_or_default(),
        entry.purpose.clone(),
        entry.conflict_disclosure.clone(),
        entry.mitigation_summary.clone(),
        entry.government_related.to_string(),
        entry.political_party_related.to_string(),
        entry.procurement_supplier_related.to_string(),
        entry.investigated_subject_related.to_string(),
        entry.related_party.to_string(),
        entry.public_case_refs.join("|"),
        entry.public_source_links.join("|"),
        entry.entry_digest.clone(),
    ]
}

fn funding_source_links(report: &FundingDisclosurePublicV1) -> Vec<Value> {
    let links = report
        .sources
        .iter()
        .chain(
            report
                .entries
                .iter()
                .flat_map(|entry| entry.public_source_links.iter()),
        )
        .collect::<BTreeSet<_>>();
    links
        .into_iter()
        .enumerate()
        .map(|(index, href)| {
            json!({"rel":"source","href":href,"label":format!("승인 공개 근거 {}",index + 1)})
        })
        .collect()
}

fn amount_band(entry: &FundingDisclosurePublicEntryV1) -> String {
    entry.amount_band_upper.as_ref().map_or_else(
        || format!("{} 이상", entry.amount_band_lower),
        |upper| format!("{} 이상 {} 미만", entry.amount_band_lower, upper),
    )
}

fn concentration_band_label(value: &str) -> Result<&'static str, ServiceError> {
    match value {
        "UNKNOWN" => Ok("확인 불가"),
        "LE_5_PERCENT" => Ok("5% 이하"),
        "GT_5_TO_15_PERCENT" => Ok("5% 초과 15% 이하"),
        "GT_15_TO_25_PERCENT" => Ok("15% 초과 25% 이하"),
        "GT_25_PERCENT" => Ok("25% 초과"),
        _ => Err(ServiceError::Persistence),
    }
}

fn funding_source_kind_label(value: &str) -> Result<&'static str, ServiceError> {
    match value {
        "DONATION" => Ok("후원"),
        "GRANT" => Ok("지원금"),
        "INSTITUTIONAL_CUSTOMER_REVENUE" => Ok("기관 고객 수익"),
        "COMMERCIAL_CUSTOMER_REVENUE" => Ok("상용 고객 수익"),
        "SPONSORSHIP" => Ok("협찬"),
        "OTHER_REVIEWED" => Ok("기타 검토 승인 재원"),
        "MIXED" => Ok("혼합 재원"),
        _ => Err(ServiceError::Persistence),
    }
}

fn funding_revision_summary(revision: i64) -> String {
    format!("승인된 공개 재원 개정본 {revision}")
}

fn funding_csv_cell(value: &str) -> String {
    let formula_candidate = value.trim_start();
    let neutralized = if formula_candidate.starts_with(['=', '+', '-', '@']) {
        format!("'{value}")
    } else {
        value.to_owned()
    };
    csv_cell(&neutralized)
}

fn canonical_json_bytes(value: &Value) -> Result<Vec<u8>, ServiceError> {
    fn write(value: &Value, output: &mut String) -> Result<(), ServiceError> {
        match value {
            Value::Null => output.push_str("null"),
            Value::Bool(value) => output.push_str(if *value { "true" } else { "false" }),
            Value::Number(value) if value.is_i64() || value.is_u64() => {
                output.push_str(&value.to_string());
            }
            Value::Number(_) => return Err(ServiceError::Persistence),
            Value::String(value) => output
                .push_str(&serde_json::to_string(value).map_err(|_| ServiceError::Persistence)?),
            Value::Array(values) => {
                output.push('[');
                for (index, value) in values.iter().enumerate() {
                    if index > 0 {
                        output.push(',');
                    }
                    write(value, output)?;
                }
                output.push(']');
            }
            Value::Object(values) => {
                let mut keys = values.keys().collect::<Vec<_>>();
                keys.sort_by(|left, right| left.encode_utf16().cmp(right.encode_utf16()));
                output.push('{');
                for (index, key) in keys.iter().enumerate() {
                    if index > 0 {
                        output.push(',');
                    }
                    output.push_str(
                        &serde_json::to_string(key).map_err(|_| ServiceError::Persistence)?,
                    );
                    output.push(':');
                    write(values.get(*key).ok_or(ServiceError::Persistence)?, output)?;
                }
                output.push('}');
            }
        }
        Ok(())
    }
    let mut output = String::new();
    write(value, &mut output)?;
    Ok(output.into_bytes())
}

fn safe_public_link(value: &str) -> bool {
    if value.is_empty() || value.len() > 2048 || value.contains(['\\', '\r', '\n']) {
        return false;
    }
    if value.starts_with('/') {
        return !value.starts_with("//");
    }
    url::Url::parse(value).is_ok_and(|url| {
        url.scheme() == "https"
            && url.username().is_empty()
            && url.password().is_none()
            && url.host_str().is_some()
    })
}

fn parse_date(value: &str) -> Result<Date, ServiceError> {
    let format = time::format_description::parse("[year]-[month]-[day]")
        .map_err(|_| ServiceError::Persistence)?;
    Date::parse(value, &format).map_err(|_| ServiceError::Persistence)
}

fn parse_timestamp(value: &str) -> Result<OffsetDateTime, ServiceError> {
    OffsetDateTime::parse(value, &Rfc3339).map_err(|_| ServiceError::Persistence)
}

fn exact_object_keys(value: &Value, expected: &[&str]) -> bool {
    value.as_object().is_some_and(|object| {
        object.keys().map(String::as_str).collect::<BTreeSet<_>>()
            == expected.iter().copied().collect::<BTreeSet<_>>()
    })
}

fn strictly_sorted_unique(values: &[String]) -> bool {
    values.windows(2).all(|pair| pair[0] < pair[1])
}

fn funding_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn funding_band(value: &str) -> bool {
    matches!(
        value,
        "UNKNOWN" | "LE_5_PERCENT" | "GT_5_TO_15_PERCENT" | "GT_15_TO_25_PERCENT" | "GT_25_PERCENT"
    )
}

fn valid_caveat(band: &str, caveat: Option<&str>) -> bool {
    if band == "UNKNOWN" {
        caveat.is_some_and(|value| !value.trim().is_empty())
    } else {
        caveat.is_none()
    }
}

fn valid_revision_predecessor(revision: i64, supersedes: Option<i64>) -> bool {
    (revision == 1 && supersedes.is_none()) || (revision > 1 && supersedes == Some(revision - 1))
}

const FUNDING_REPORT_FIELDS: &[&str] = &[
    "schemaVersion",
    "disclosureId",
    "revision",
    "fiscalYear",
    "fiscalQuarter",
    "periodStart",
    "periodEnd",
    "reportingCurrency",
    "concentrationBand",
    "caveat",
    "purpose",
    "policyRequests",
    "sources",
    "entries",
    "effectiveAt",
    "publishedAt",
    "supersedesRevision",
    "sourceRevisionDigest",
    "publicContentDigest",
];
