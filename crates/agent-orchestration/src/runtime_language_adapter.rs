use super::*;
use gurine_publication_policy::language::{
    LANGUAGE_POLICY_VERSION, LanguageRuleCode, evaluate_public_language, language_policy_sha256,
};

pub(super) fn claim_language_check(
    value: &ClaimLanguageCheckRequest,
) -> Result<ToolResponse, DispatchError> {
    validate_request(value)?;
    let checked_text_utf16_length = u32::try_from(value.draft_text.encode_utf16().count())
        .map_err(|_| DispatchError::RequestInvalid)?;
    let mut findings = evaluate_public_language(&value.draft_text)
        .findings
        .into_iter()
        .map(|finding| map_finding(value, finding))
        .collect::<Result<Vec<_>, DispatchError>>()?;
    let total_findings =
        u32::try_from(findings.len()).map_err(|_| DispatchError::RequestInvalid)?;
    findings.truncate(usize::from(value.max_findings));
    let truncated = total_findings > u32::from(value.max_findings);
    let decision = if total_findings == 0 {
        LanguageDecision::Pass
    } else {
        LanguageDecision::Block
    };
    let decision_sha256 = decision_sha256(
        value,
        checked_text_utf16_length,
        decision,
        &findings,
        total_findings,
        truncated,
    )?;
    Ok(ToolResponse::ClaimLanguageCheck(LanguageCheckResponse {
        schema_version: "claim.language_check.response.v2".to_owned(),
        checked_text_sha256: value.draft_text_sha256.clone(),
        checked_text_utf16_length,
        decision,
        findings,
        finding_limit: value.max_findings,
        total_findings,
        truncated,
        language_decision_sha256: decision_sha256,
    }))
}

fn validate_request(value: &ClaimLanguageCheckRequest) -> Result<(), DispatchError> {
    let citations = value
        .allowed_citation_ids
        .iter()
        .collect::<std::collections::BTreeSet<_>>();
    if value.draft_text.trim().is_empty()
        || value.draft_text.len() > 10_000
        || value.draft_text_sha256 != digest(value.draft_text.as_bytes())
        || value.language_policy_version != LANGUAGE_POLICY_VERSION
        || value.language_policy_sha256 != language_policy_sha256()
        || !(1..=50).contains(&value.max_findings)
        || value.allowed_citation_ids.len() > 100
        || citations.len() != value.allowed_citation_ids.len()
    {
        return Err(DispatchError::RequestInvalid);
    }
    Ok(())
}

fn map_finding(
    value: &ClaimLanguageCheckRequest,
    finding: gurine_publication_policy::language::LanguageFinding,
) -> Result<Finding, DispatchError> {
    let start_utf16 =
        u32::try_from(finding.start_utf16).map_err(|_| DispatchError::RequestInvalid)?;
    let end_utf16 = u32::try_from(finding.end_utf16).map_err(|_| DispatchError::RequestInvalid)?;
    let code = match finding.code {
        LanguageRuleCode::UnsupportedCertainty => LanguageFindingCode::UnsupportedCertainty,
        LanguageRuleCode::CrimeOrCorruptionAssertion | LanguageRuleCode::CorruptionRanking => {
            LanguageFindingCode::CrimeOrCorruptionAssertion
        }
        LanguageRuleCode::NoResponseAsAdmission => LanguageFindingCode::NoResponseAsAdmission,
    };
    Ok(Finding {
        finding_id: stable_finding_id(&value.draft_text_sha256, code, start_utf16, end_utf16),
        code,
        severity: LanguageFindingSeverity::Blocking,
        start_utf16,
        end_utf16,
        length_utf16: end_utf16.saturating_sub(start_utf16),
        message: finding.message.to_owned(),
        suggested_replacement: finding.suggested_replacement.map(str::to_owned),
        citation_ids: Vec::new(),
    })
}

fn decision_sha256(
    value: &ClaimLanguageCheckRequest,
    checked_text_utf16_length: u32,
    decision: LanguageDecision,
    findings: &[Finding],
    total_findings: u32,
    truncated: bool,
) -> Result<String, DispatchError> {
    let allowed_citation_ids_digest = digest(
        &serde_json::to_vec(&value.allowed_citation_ids)
            .map_err(|_| DispatchError::RequestInvalid)?,
    );
    let projection = serde_json::json!({
        "allowedCitationIdsDigest": allowed_citation_ids_digest,
        "checkedTextSha256": value.draft_text_sha256,
        "checkedTextUtf16Length": checked_text_utf16_length,
        "decision": decision,
        "findingLimit": value.max_findings,
        "findings": findings,
        "languagePolicySha256": value.language_policy_sha256,
        "languagePolicyVersion": value.language_policy_version,
        "totalFindings": total_findings,
        "truncated": truncated,
    });
    serde_json::to_vec(&projection)
        .map(|bytes| digest(&bytes))
        .map_err(|_| DispatchError::RequestInvalid)
}

fn stable_finding_id(
    text_sha256: &str,
    code: LanguageFindingCode,
    start_utf16: u32,
    end_utf16: u32,
) -> Uuid {
    let bytes = Sha256::digest(
        format!("language-finding:{text_sha256}:{code:?}:{start_utf16}:{end_utf16}").as_bytes(),
    );
    let mut uuid_bytes = [0_u8; 16];
    uuid_bytes.copy_from_slice(&bytes[..16]);
    uuid_bytes[6] = (uuid_bytes[6] & 0x0f) | 0x50;
    uuid_bytes[8] = (uuid_bytes[8] & 0x3f) | 0x80;
    Uuid::from_bytes(uuid_bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn findings_bind_utf16_offsets_policy_and_decision_digest() {
        let request = request("📌 무응답은 인정이며 부패 랭킹이다");
        let first = claim_language_check(&request).expect("language result");
        let second = claim_language_check(&request).expect("stable language result");
        assert_eq!(first, second);
        let ToolResponse::ClaimLanguageCheck(response) = first else {
            assert!(false, "closed response variant");
            return;
        };
        assert_eq!(response.decision, LanguageDecision::Block);
        assert_eq!(response.total_findings, 2);
        assert_eq!(response.findings[0].start_utf16, 3);
        assert_eq!(response.findings[0].length_utf16, 7);
        assert_eq!(response.language_decision_sha256.len(), 64);
    }

    #[test]
    fn policy_digest_drift_is_rejected() {
        let mut request = request("확인된 기록");
        request.language_policy_sha256 = "0".repeat(64);
        assert_eq!(
            claim_language_check(&request),
            Err(DispatchError::RequestInvalid)
        );
    }

    fn request(text: &str) -> ClaimLanguageCheckRequest {
        ClaimLanguageCheckRequest {
            binding: SnapshotBinding {
                run_id: Uuid::from_u128(1),
                input_snapshot_id: Uuid::from_u128(2),
                input_snapshot_sha256: "a".repeat(64),
            },
            draft_text: text.to_owned(),
            draft_text_sha256: digest(text.as_bytes()),
            claim_type: ClaimType::Fact,
            locale: ClaimLocale::KoKr,
            allowed_citation_ids: Vec::new(),
            language_policy_version: LANGUAGE_POLICY_VERSION.to_owned(),
            language_policy_sha256: language_policy_sha256(),
            max_findings: 50,
        }
    }
}
