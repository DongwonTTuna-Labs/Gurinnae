use uuid::Uuid;

use crate::{aliases::exact_alias_match, confidence::Confidence};

pub struct SupplierCandidate<'a> {
    pub id: Uuid,
    pub canonical_name: &'a str,
    pub aliases: &'a [&'a str],
    pub registration_number_hash: Option<&'a str>,
}

pub struct SupplierObservation<'a> {
    pub name: &'a str,
    pub registration_number_hash: Option<&'a str>,
}

pub fn score(
    candidate: &SupplierCandidate<'_>,
    observation: &SupplierObservation<'_>,
) -> Confidence {
    let basis_points = if candidate.registration_number_hash.is_some()
        && candidate.registration_number_hash == observation.registration_number_hash
    {
        10_000
    } else if exact_alias_match(candidate.canonical_name, observation.name)
        || candidate
            .aliases
            .iter()
            .any(|alias| exact_alias_match(alias, observation.name))
    {
        9_000
    } else {
        0
    };
    Confidence::from_basis_points(basis_points).unwrap_or(Confidence::ZERO)
}
