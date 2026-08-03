fn validate_disclosure(report: &FundingDisclosurePublicV1) -> Result<(), ServiceError> {
    let policy = &report.policy_requests;
    if report.fiscal_year <= 0
        || !(1..=4).contains(&report.fiscal_quarter)
        || report.reporting_currency.len() != 3
        || !report
            .reporting_currency
            .bytes()
            .all(|byte| byte.is_ascii_uppercase())
        || !funding_band(&report.concentration_band)
        || report.purpose.trim().is_empty()
        || !funding_sha256(&report.source_revision_digest)
        || !funding_sha256(&report.public_content_digest)
        || parse_date(&report.period_start)? >= parse_date(&report.period_end)?
        || parse_timestamp(&report.effective_at)? > parse_timestamp(&report.published_at)?
        || report.sources.iter().any(|link| !safe_public_link(link))
        || !strictly_sorted_unique(&report.sources)
        || [
            policy.total,
            policy.accepted,
            policy.partially_accepted,
            policy.rejected,
            policy.withdrawn,
            policy.pending,
        ]
        .into_iter()
        .any(|value| value < 0)
        || policy.total
            != policy.accepted
                + policy.partially_accepted
                + policy.rejected
                + policy.withdrawn
                + policy.pending
        || !funding_sha256(&policy.outcome_digest)
        || !valid_caveat(&report.concentration_band, report.caveat.as_deref())
        || !valid_revision_predecessor(report.revision, report.supersedes_revision)
    {
        return Err(ServiceError::Persistence);
    }
    for (index, entry) in report.entries.iter().enumerate() {
        if entry.ordinal != i32::try_from(index + 1).map_err(|_| ServiceError::Persistence)? {
            return Err(ServiceError::Persistence);
        }
        validate_disclosure_entry(entry)?;
    }
    Ok(())
}

fn validate_disclosure_entry(entry: &FundingDisclosurePublicEntryV1) -> Result<(), ServiceError> {
    let lower = entry
        .amount_band_lower
        .parse::<Decimal>()
        .map_err(|_| ServiceError::Persistence)?;
    let upper = entry
        .amount_band_upper
        .as_deref()
        .map(str::parse::<Decimal>)
        .transpose()
        .map_err(|_| ServiceError::Persistence)?;
    let valid_identity = match entry.identity_disclosure_mode.as_str() {
        "NAMED" => {
            entry
                .public_display_name
                .as_deref()
                .is_some_and(|value| !value.trim().is_empty())
                && entry.withholding_public_explanation.is_none()
        }
        "CATEGORY_ONLY" | "WITHHELD_LEGAL" => {
            entry.public_display_name.is_none()
                && entry
                    .withholding_public_explanation
                    .as_deref()
                    .is_some_and(|value| !value.trim().is_empty())
        }
        _ => false,
    };
    if !valid_identity
        || entry.counterparty_category.trim().is_empty()
        || !matches!(
            entry.funding_source_kind.as_str(),
            "DONATION"
                | "GRANT"
                | "INSTITUTIONAL_CUSTOMER_REVENUE"
                | "COMMERCIAL_CUSTOMER_REVENUE"
                | "SPONSORSHIP"
                | "OTHER_REVIEWED"
                | "MIXED"
        )
        || lower.is_sign_negative()
        || upper.is_some_and(|value| value <= lower)
        || entry.reporting_currency.len() != 3
        || !entry
            .reporting_currency
            .bytes()
            .all(|byte| byte.is_ascii_uppercase())
        || !funding_band(&entry.concentration_band)
        || !valid_entry_unknown_fields(entry)
        || [
            entry.purpose.as_str(),
            entry.conflict_disclosure.as_str(),
            entry.mitigation_summary.as_str(),
        ]
        .into_iter()
        .any(|value| value.trim().is_empty())
        || !funding_sha256(&entry.entry_digest)
        || entry.public_case_refs.iter().any(|reference| {
            reference.trim().is_empty()
                || reference.len() > 256
                || Uuid::parse_str(reference).is_ok()
        })
        || !strictly_sorted_unique(&entry.public_case_refs)
        || entry
            .public_source_links
            .iter()
            .any(|link| !safe_public_link(link))
        || !strictly_sorted_unique(&entry.public_source_links)
    {
        return Err(ServiceError::Persistence);
    }
    Ok(())
}

fn valid_entry_unknown_fields(entry: &FundingDisclosurePublicEntryV1) -> bool {
    match entry.concentration_band.as_str() {
        "UNKNOWN" => {
            entry
                .public_caveat_text
                .as_deref()
                .is_some_and(|value| !value.trim().is_empty())
                && match entry.concentration_unknown_reason.as_deref() {
                    Some("DENOMINATOR_UNKNOWN") => {
                        matches!(
                            entry.denominator_unknown_reason.as_deref(),
                            Some("MISSING" | "ZERO" | "APPROVAL_MISSING" | "APPROVAL_STALE")
                        ) && entry.grouping_dispute_reason.is_none()
                    }
                    Some("GROUPING_DISPUTED") => matches!(
                        entry.grouping_dispute_reason.as_deref(),
                        Some(
                            "IDENTITY_AMBIGUOUS"
                                | "MEMBER_SET_DISPUTED"
                                | "RELATED_PARTY_STATUS_DISPUTED"
                                | "AUTHORITATIVE_SOURCE_CONFLICT"
                        )
                    ),
                    _ => false,
                }
        }
        _ => {
            entry.denominator_unknown_reason.is_none()
                && entry.grouping_dispute_reason.is_none()
                && entry.concentration_unknown_reason.is_none()
                && entry.public_caveat_text.is_none()
        }
    }
}
