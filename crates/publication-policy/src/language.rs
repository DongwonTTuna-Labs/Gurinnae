#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LanguageViolation {
    CrimeAssertion,
    NoResponseAsAdmission,
    RankingLanguage,
}

const CRIME_ASSERTIONS: &[&str] = &[
    "비리로 확정",
    "범죄로 확인",
    "부패 기관",
    "corrupt institution",
];
const ADMISSION_ASSERTIONS: &[&str] =
    &["무응답은 인정", "답변하지 않아 사실로", "silence confirms"];
const RANKING_ASSERTIONS: &[&str] = &["비리 순위", "부패 랭킹", "corruption ranking"];

pub fn validate_public_language(text: &str) -> Result<(), LanguageViolation> {
    let normalized = text.to_lowercase();
    if CRIME_ASSERTIONS
        .iter()
        .any(|phrase| normalized.contains(phrase))
    {
        return Err(LanguageViolation::CrimeAssertion);
    }
    if ADMISSION_ASSERTIONS
        .iter()
        .any(|phrase| normalized.contains(phrase))
    {
        return Err(LanguageViolation::NoResponseAsAdmission);
    }
    if RANKING_ASSERTIONS
        .iter()
        .any(|phrase| normalized.contains(phrase))
    {
        return Err(LanguageViolation::RankingLanguage);
    }
    Ok(())
}
