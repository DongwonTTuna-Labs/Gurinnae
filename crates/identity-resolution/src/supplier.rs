use uuid::Uuid;

use crate::{aliases::exact_alias_match, confidence::Confidence};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum StrongIdentifierScheme {
    KoreanBusinessNumber,
    OpenDartCorpCode,
    KonepsPartyKey,
}

impl StrongIdentifierScheme {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::KoreanBusinessNumber => "KOREAN_BUSINESS_NUMBER",
            Self::OpenDartCorpCode => "OPEN_DART_CORP_CODE",
            Self::KonepsPartyKey => "KONEPS_PARTY_KEY",
        }
    }

    /// Old rows keep their original scheme spelling, but they are never
    /// upgraded to proven facts merely because the spelling can be mapped.
    pub fn from_persisted(value: &str) -> Option<Self> {
        match value {
            "KOREAN_BUSINESS_NUMBER" | "BUSINESS_NUMBER" => Some(Self::KoreanBusinessNumber),
            "OPEN_DART_CORP_CODE" | "DART_CORP_CODE" => Some(Self::OpenDartCorpCode),
            "KONEPS_PARTY_KEY" => Some(Self::KonepsPartyKey),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ObservedStrongIdentifier<'a> {
    pub scheme: StrongIdentifierScheme,
    pub value_hmac: &'a str,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SupplierIdentifierFact<'a> {
    pub persisted_scheme: &'a str,
    pub value_hmac: &'a str,
    pub verification_status: &'a str,
    pub proof_state: &'a str,
}

impl SupplierIdentifierFact<'_> {
    fn proves(&self, observation: ObservedStrongIdentifier<'_>) -> bool {
        self.verification_status == "VERIFIED"
            && self.proof_state == "PROVEN_V1"
            && StrongIdentifierScheme::from_persisted(self.persisted_scheme)
                == Some(observation.scheme)
            && self.value_hmac == observation.value_hmac
    }
}

pub struct SupplierCandidate<'a> {
    pub id: Uuid,
    pub canonical_name: &'a str,
    pub aliases: &'a [&'a str],
    pub identifier_facts: &'a [SupplierIdentifierFact<'a>],
}

pub struct SupplierObservation<'a> {
    pub name: &'a str,
    pub strong_identifier: Option<ObservedStrongIdentifier<'a>>,
}

pub fn score(
    candidate: &SupplierCandidate<'_>,
    observation: &SupplierObservation<'_>,
) -> Confidence {
    let identifier_match = observation.strong_identifier.is_some_and(|identifier| {
        candidate
            .identifier_facts
            .iter()
            .any(|fact| fact.proves(identifier))
    });
    let basis_points = if identifier_match {
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

#[cfg(test)]
mod tests {
    use super::{
        ObservedStrongIdentifier, StrongIdentifierScheme, SupplierCandidate,
        SupplierIdentifierFact, SupplierObservation, score,
    };
    use uuid::Uuid;

    const NO_ALIASES: &[&str] = &[];
    const NO_FACTS: &[SupplierIdentifierFact<'_>] = &[];

    fn candidate<'a>(
        id: Uuid,
        name: &'a str,
        facts: &'a [SupplierIdentifierFact<'a>],
    ) -> SupplierCandidate<'a> {
        SupplierCandidate {
            id,
            canonical_name: name,
            aliases: NO_ALIASES,
            identifier_facts: facts,
        }
    }

    #[test]
    fn name_equality_scores_for_review_but_never_auto_resolves() {
        let id = Uuid::new_v4();
        let candidates = [candidate(id, "가상 공급사", NO_FACTS)];
        let observation = SupplierObservation {
            name: "가상 공급사",
            strong_identifier: None,
        };

        assert_eq!(score(&candidates[0], &observation).basis_points(), 9_000);
    }

    #[test]
    fn one_proven_strong_identifier_is_a_top_scored_suggestion_only() {
        let id = Uuid::new_v4();
        let facts = [SupplierIdentifierFact {
            persisted_scheme: "KOREAN_BUSINESS_NUMBER",
            value_hmac: "digest-a",
            verification_status: "VERIFIED",
            proof_state: "PROVEN_V1",
        }];
        let candidates = [candidate(id, "이름 변경 전", &facts)];
        let observation = SupplierObservation {
            name: "이름 변경 후",
            strong_identifier: Some(ObservedStrongIdentifier {
                scheme: StrongIdentifierScheme::KoreanBusinessNumber,
                value_hmac: "digest-a",
            }),
        };

        assert_eq!(score(&candidates[0], &observation).basis_points(), 10_000);
    }

    #[test]
    fn legacy_scheme_spelling_maps_explicitly_but_still_requires_proof() {
        let id = Uuid::new_v4();
        let proven = [SupplierIdentifierFact {
            persisted_scheme: "DART_CORP_CODE",
            value_hmac: "digest-b",
            verification_status: "VERIFIED",
            proof_state: "PROVEN_V1",
        }];
        let unproven = [SupplierIdentifierFact {
            proof_state: "LEGACY_UNPROVEN",
            ..proven[0]
        }];
        let observation = SupplierObservation {
            name: "가상 법인",
            strong_identifier: Some(ObservedStrongIdentifier {
                scheme: StrongIdentifierScheme::OpenDartCorpCode,
                value_hmac: "digest-b",
            }),
        };

        assert_eq!(
            score(&candidate(id, "다른 이름", &proven), &observation).basis_points(),
            10_000
        );
        assert_eq!(
            score(&candidate(id, "다른 이름", &unproven), &observation).basis_points(),
            0
        );
    }

    #[test]
    fn ambiguous_strong_matches_remain_independent_suggestions() {
        let facts = [SupplierIdentifierFact {
            persisted_scheme: "KONEPS_PARTY_KEY",
            value_hmac: "digest-c",
            verification_status: "VERIFIED",
            proof_state: "PROVEN_V1",
        }];
        let observation = SupplierObservation {
            name: "관찰 이름",
            strong_identifier: Some(ObservedStrongIdentifier {
                scheme: StrongIdentifierScheme::KonepsPartyKey,
                value_hmac: "digest-c",
            }),
        };
        let candidates = [
            candidate(Uuid::new_v4(), "후보 하나", &facts),
            candidate(Uuid::new_v4(), "후보 둘", &facts),
        ];

        assert_eq!(score(&candidates[0], &observation).basis_points(), 10_000);
        assert_eq!(score(&candidates[1], &observation).basis_points(), 10_000);
    }
}
