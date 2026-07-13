use uuid::Uuid;

use crate::{aliases::exact_alias_match, confidence::Confidence};

pub struct AgencyCandidate<'a> {
    pub id: Uuid,
    pub canonical_name: &'a str,
    pub aliases: &'a [&'a str],
    pub government_code: Option<&'a str>,
}

pub struct AgencyObservation<'a> {
    pub name: &'a str,
    pub government_code: Option<&'a str>,
}

pub fn score(candidate: &AgencyCandidate<'_>, observation: &AgencyObservation<'_>) -> Confidence {
    if candidate.government_code.is_some()
        && candidate.government_code == observation.government_code
    {
        return Confidence::CERTAIN;
    }
    if exact_alias_match(candidate.canonical_name, observation.name)
        || candidate
            .aliases
            .iter()
            .any(|alias| exact_alias_match(alias, observation.name))
    {
        return Confidence::from_basis_points(9_000).unwrap_or(Confidence::ZERO);
    }
    Confidence::ZERO
}
