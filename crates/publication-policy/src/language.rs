use sha2::{Digest, Sha256};

pub const LANGUAGE_POLICY_VERSION: &str = "ko-public-claims-v1";

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum LanguageRuleCode {
    UnsupportedCertainty,
    CrimeOrCorruptionAssertion,
    NoResponseAsAdmission,
    CorruptionRanking,
}

impl LanguageRuleCode {
    pub const fn wire_name(self) -> &'static str {
        match self {
            Self::UnsupportedCertainty => "UNSUPPORTED_CERTAINTY",
            Self::CrimeOrCorruptionAssertion => "CRIME_OR_CORRUPTION_ASSERTION",
            Self::NoResponseAsAdmission => "NO_RESPONSE_AS_ADMISSION",
            Self::CorruptionRanking => "CORRUPTION_RANKING",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LanguageFinding {
    pub code: LanguageRuleCode,
    pub start_utf16: usize,
    pub end_utf16: usize,
    pub message: &'static str,
    pub suggested_replacement: Option<&'static str>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LanguageAssessment {
    pub policy_version: &'static str,
    pub policy_sha256: String,
    pub findings: Vec<LanguageFinding>,
}

#[derive(Clone, Copy)]
struct LanguageRule {
    code: LanguageRuleCode,
    patterns: &'static [&'static str],
    message: &'static str,
    replacement: Option<&'static str>,
}

const LANGUAGE_RULES: &[LanguageRule] = &[
    LanguageRule {
        code: LanguageRuleCode::UnsupportedCertainty,
        patterns: &["확실한 사실", "의심의 여지 없이", "틀림없이", "확정적으로"],
        message: "근거 범위를 넘는 확정 표현",
        replacement: Some("확인된 근거 범위에서는"),
    },
    LanguageRule {
        code: LanguageRuleCode::CrimeOrCorruptionAssertion,
        patterns: &[
            "비리로 확정",
            "범죄로 확인",
            "범죄임이 확정",
            "부패 기관",
            "부패로 확인",
            "비리 사실이다",
            "corrupt institution",
        ],
        message: "범죄·부패를 확정하는 표현",
        replacement: Some("확인이 필요한 이상 징후"),
    },
    LanguageRule {
        code: LanguageRuleCode::NoResponseAsAdmission,
        patterns: &[
            "무응답은 인정",
            "답변하지 않아 사실로",
            "답변이 없으므로 인정",
            "침묵은 인정",
            "silence confirms",
        ],
        message: "무응답을 사실 인정으로 해석하는 표현",
        replacement: Some("답변을 받지 못함"),
    },
    LanguageRule {
        code: LanguageRuleCode::CorruptionRanking,
        patterns: &[
            "비리 순위",
            "부패 순위",
            "부패 랭킹",
            "비리 랭킹",
            "corruption ranking",
        ],
        message: "사람·기관을 부패 순위로 평가하는 표현",
        replacement: Some("이상 징후 관측 건수"),
    },
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LanguageViolation {
    UnsupportedCertainty,
    CrimeAssertion,
    NoResponseAsAdmission,
    RankingLanguage,
}

pub fn language_policy_sha256() -> String {
    let mut preimage = String::from(LANGUAGE_POLICY_VERSION);
    for rule in LANGUAGE_RULES {
        preimage.push('\u{1e}');
        preimage.push_str(rule.code.wire_name());
        preimage.push('\u{1f}');
        preimage.push_str(&rule.patterns.join("\u{1f}"));
        preimage.push('\u{1f}');
        preimage.push_str(rule.message);
        preimage.push('\u{1f}');
        preimage.push_str(rule.replacement.unwrap_or_default());
    }
    Sha256::digest(preimage.as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

pub fn evaluate_public_language(text: &str) -> LanguageAssessment {
    let normalized = LowercaseText::new(text);
    let mut findings = LANGUAGE_RULES
        .iter()
        .flat_map(|rule| {
            rule.patterns.iter().flat_map(|pattern| {
                normalized
                    .value
                    .match_indices(pattern)
                    .filter_map(|(start, matched)| {
                        normalized.original_span(start, start + matched.len()).map(
                            |(original_start, original_end)| LanguageFinding {
                                code: rule.code,
                                start_utf16: text[..original_start].encode_utf16().count(),
                                end_utf16: text[..original_end].encode_utf16().count(),
                                message: rule.message,
                                suggested_replacement: rule.replacement,
                            },
                        )
                    })
            })
        })
        .collect::<Vec<_>>();
    findings.sort_by_key(|finding| (finding.start_utf16, finding.end_utf16, finding.code));
    findings.dedup_by_key(|finding| (finding.start_utf16, finding.end_utf16, finding.code));
    LanguageAssessment {
        policy_version: LANGUAGE_POLICY_VERSION,
        policy_sha256: language_policy_sha256(),
        findings,
    }
}

struct LowercaseText {
    value: String,
    spans: Vec<(usize, usize, usize, usize)>,
}

impl LowercaseText {
    fn new(text: &str) -> Self {
        let mut value = String::new();
        let mut spans = Vec::new();
        for (original_start, character) in text.char_indices() {
            let original_end = original_start + character.len_utf8();
            for lowered in character.to_lowercase() {
                let normalized_start = value.len();
                value.push(lowered);
                spans.push((normalized_start, value.len(), original_start, original_end));
            }
        }
        Self { value, spans }
    }

    fn original_span(&self, start: usize, end: usize) -> Option<(usize, usize)> {
        let first = self.spans.iter().find(|span| span.0 == start)?;
        let last = self.spans.iter().find(|span| span.1 == end)?;
        Some((first.2, last.3))
    }
}

pub fn validate_public_language(text: &str) -> Result<(), LanguageViolation> {
    let Some(finding) = evaluate_public_language(text).findings.into_iter().next() else {
        return Ok(());
    };
    Err(match finding.code {
        LanguageRuleCode::UnsupportedCertainty => LanguageViolation::UnsupportedCertainty,
        LanguageRuleCode::CrimeOrCorruptionAssertion => LanguageViolation::CrimeAssertion,
        LanguageRuleCode::NoResponseAsAdmission => LanguageViolation::NoResponseAsAdmission,
        LanguageRuleCode::CorruptionRanking => LanguageViolation::RankingLanguage,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn korean_rules_report_exact_utf16_offsets_and_stable_policy() {
        let text = "📌 무응답은 인정이라는 표현";
        let assessment = evaluate_public_language(text);
        assert_eq!(assessment.policy_version, LANGUAGE_POLICY_VERSION);
        assert_eq!(
            assessment.policy_sha256,
            "6766a275b7d9a3ef0157bbd42d57245f8309f3ec15f2ee6cd515d6397ee4bc4e"
        );
        assert_eq!(assessment.findings.len(), 1);
        let finding = &assessment.findings[0];
        assert_eq!(finding.code, LanguageRuleCode::NoResponseAsAdmission);
        assert_eq!(
            &text["📌 ".len()..][.."무응답은 인정".len()],
            "무응답은 인정"
        );
        assert_eq!(finding.start_utf16, 3);
        assert_eq!(finding.end_utf16 - finding.start_utf16, 7);
    }

    #[test]
    fn legacy_public_gate_uses_the_versioned_rule_source() {
        assert_eq!(
            validate_public_language("부패 랭킹을 공개한다"),
            Err(LanguageViolation::RankingLanguage)
        );
        assert!(validate_public_language("확인된 사실과 미확인 사항을 나눠 기록한다").is_ok());
    }

    #[test]
    fn lowercase_expansion_keeps_original_utf16_span() {
        let text = "İ무응답은 인정";
        let assessment = evaluate_public_language(text);
        assert_eq!(assessment.findings.len(), 1);
        assert_eq!(assessment.findings[0].start_utf16, 1);
        assert_eq!(assessment.findings[0].end_utf16, 8);
    }
}
