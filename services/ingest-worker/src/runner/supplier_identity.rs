use std::collections::BTreeSet;

use gurine_identity_resolution::supplier::{
    ObservedStrongIdentifier, StrongIdentifierScheme, SupplierCandidate, SupplierIdentifierFact,
    SupplierObservation, score,
};
use hmac::{Hmac, Mac};
use serde_json::{Value, json};
use sha2::Sha256;
use sqlx::{Postgres, Transaction};
use uuid::Uuid;

use super::{Failure, database};

type HmacSha256 = Hmac<Sha256>;
const CERTAIN_SCORE_BASIS_POINTS: u16 = 10_000;
const PROPOSAL_SCHEMA_VERSION: &str = "supplier-identity-candidate-proposal.request.v1";

#[derive(Clone, Copy)]
pub(super) struct IncomingSupplierIdentifier<'a> {
    pub scheme: StrongIdentifierScheme,
    pub raw_value: &'a str,
}

pub(super) struct IncomingSupplier<'a> {
    pub name: &'a str,
    pub identifier: Option<IncomingSupplierIdentifier<'a>>,
    pub source_document_id: Uuid,
    pub parsed_record_id: Uuid,
    pub record_index: i32,
}

struct SafeIdentifier {
    scheme: StrongIdentifierScheme,
    value_hmac: String,
}

#[derive(Debug, Eq, Ord, PartialEq, PartialOrd)]
struct StrongIdentifierSuggestion {
    target_supplier_id: Uuid,
    identifier_fact_digest: String,
}

#[derive(Clone, Copy)]
struct PersistedIdentifierFact<'a> {
    target_supplier_id: Uuid,
    persisted_scheme: &'a str,
    value_hmac: &'a str,
    verification_status: &'a str,
    proof_state: &'a str,
    identifier_fact_digest: &'a str,
}

pub(super) async fn resolve_supplier(
    tx: &mut Transaction<'_, Postgres>,
    hmac_key: &[u8],
    incoming: IncomingSupplier<'_>,
) -> Result<(), Failure> {
    let Some(identifier) = incoming.identifier else {
        return Ok(());
    };
    let safe_identifier = protect_identifier(hmac_key, identifier)
        .map_err(|code| Failure::Terminal(code, "supplier identifier protection".to_owned()))?;
    let observation = SupplierObservation {
        name: incoming.name,
        strong_identifier: Some(ObservedStrongIdentifier {
            scheme: safe_identifier.scheme,
            value_hmac: &safe_identifier.value_hmac,
        }),
    };
    let suggestions = proven_identifier_suggestions(tx, &observation).await?;
    for suggestion in &suggestions {
        record_suggestion(tx, &incoming, &safe_identifier, suggestion).await?;
    }
    tracing::debug!(
        strong_identifier_suggestion_count = suggestions.len(),
        "strong supplier identity matches retained for human review only"
    );
    Ok(())
}

async fn proven_identifier_suggestions(
    tx: &mut Transaction<'_, Postgres>,
    observation: &SupplierObservation<'_>,
) -> Result<BTreeSet<StrongIdentifierSuggestion>, Failure> {
    let Some(identifier) = observation.strong_identifier else {
        return Ok(BTreeSet::new());
    };
    let rows = sqlx::query!(
        "SELECT i.supplier_id,i.scheme,btrim(i.value_hash) AS \"value_hmac!\", \
                i.verification_status,i.proof_state, \
                btrim(i.identifier_fact_digest) AS \"identifier_fact_digest!\" \
         FROM core.supplier_identifiers i \
         WHERE i.value_hash=$1 AND i.verification_status='VERIFIED' \
           AND i.proof_state='PROVEN_V1' \
           AND i.identifier_fact_digest IS NOT NULL \
           AND i.scheme IN ('KOREAN_BUSINESS_NUMBER','OPEN_DART_CORP_CODE','KONEPS_PARTY_KEY') \
         ORDER BY i.supplier_id,i.scheme,i.identifier_fact_digest",
        identifier.value_hmac,
    )
    .fetch_all(&mut **tx)
    .await
    .map_err(database)?;
    let mut matches = BTreeSet::new();
    for row in rows {
        let fact = PersistedIdentifierFact {
            target_supplier_id: row.supplier_id,
            persisted_scheme: &row.scheme,
            value_hmac: &row.value_hmac,
            verification_status: &row.verification_status,
            proof_state: &row.proof_state,
            identifier_fact_digest: &row.identifier_fact_digest,
        };
        if let Some(suggestion) = retain_certain_suggestion(&fact, observation) {
            matches.insert(suggestion);
        }
    }
    Ok(matches)
}

fn retain_certain_suggestion(
    persisted: &PersistedIdentifierFact<'_>,
    observation: &SupplierObservation<'_>,
) -> Option<StrongIdentifierSuggestion> {
    let facts = [SupplierIdentifierFact {
        persisted_scheme: persisted.persisted_scheme,
        value_hmac: persisted.value_hmac,
        verification_status: persisted.verification_status,
        proof_state: persisted.proof_state,
    }];
    let candidate = SupplierCandidate {
        id: persisted.target_supplier_id,
        canonical_name: observation.name,
        aliases: &[],
        identifier_facts: &facts,
    };
    (score(&candidate, observation).basis_points() == CERTAIN_SCORE_BASIS_POINTS).then(|| {
        StrongIdentifierSuggestion {
            target_supplier_id: persisted.target_supplier_id,
            identifier_fact_digest: persisted.identifier_fact_digest.to_owned(),
        }
    })
}

async fn record_suggestion(
    tx: &mut Transaction<'_, Postgres>,
    incoming: &IncomingSupplier<'_>,
    identifier: &SafeIdentifier,
    suggestion: &StrongIdentifierSuggestion,
) -> Result<(), Failure> {
    let request = proposal_request(incoming, identifier, suggestion);
    let result = sqlx::query!(
        "SELECT candidate_id,merge_decision_id,disposition,recorded \
         FROM core.record_supplier_identity_candidate_v1($1)",
        request,
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(database)?;
    if result.candidate_id.is_none()
        || result.merge_decision_id.is_some()
        || result.disposition.as_deref() != Some("PENDING_HUMAN")
        || result.recorded != Some(true)
    {
        return Err(Failure::Terminal(
            "SUPPLIER_IDENTITY_PROPOSAL_CONTRACT_MISMATCH",
            "candidate proposal writer returned an invalid disposition".to_owned(),
        ));
    }
    Ok(())
}

fn proposal_request(
    incoming: &IncomingSupplier<'_>,
    identifier: &SafeIdentifier,
    suggestion: &StrongIdentifierSuggestion,
) -> Value {
    json!({
        "schemaVersion": PROPOSAL_SCHEMA_VERSION,
        "sourceDocumentId": incoming.source_document_id,
        "parsedRecordId": incoming.parsed_record_id,
        "recordIndex": incoming.record_index,
        "normalizedName": incoming.name,
        "observedScheme": identifier.scheme.as_str(),
        "observedValueHmac": identifier.value_hmac,
        "targetSupplierId": suggestion.target_supplier_id,
        "identifierFactDigest": suggestion.identifier_fact_digest,
        "scoreBasisPoints": CERTAIN_SCORE_BASIS_POINTS,
    })
}

fn protect_identifier(
    key: &[u8],
    identifier: IncomingSupplierIdentifier<'_>,
) -> Result<SafeIdentifier, &'static str> {
    let mut mac = HmacSha256::new_from_slice(key)
        .map_err(|_| "SUPPLIER_IDENTIFIER_HMAC_CONFIGURATION_INVALID")?;
    mac.update(identifier.raw_value.trim().as_bytes());
    let value_hmac = encode_hex(&mac.finalize().into_bytes());
    Ok(SafeIdentifier {
        scheme: identifier.scheme,
        value_hmac,
    })
}

fn encode_hex(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(HEX[(byte >> 4) as usize] as char);
        output.push(HEX[(byte & 0x0f) as usize] as char);
    }
    output
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use gurine_identity_resolution::supplier::{
        ObservedStrongIdentifier, StrongIdentifierScheme, SupplierObservation,
    };
    use serde_json::Value;
    use uuid::Uuid;

    use super::{
        IncomingSupplier, IncomingSupplierIdentifier, PersistedIdentifierFact, SafeIdentifier,
        StrongIdentifierSuggestion, proposal_request, protect_identifier,
        retain_certain_suggestion,
    };

    #[test]
    fn no_automatic_supplier_binding_path_exists() {
        let module_source = include_str!("supplier_identity.rs");
        let production_source = module_source.split("#[cfg(test)]").next().unwrap_or("");
        assert!(!production_source.contains("record_supplier_identity_resolution_v1"));
        assert!(!production_source.contains("INSERT INTO core.suppliers"));
        assert!(!production_source.contains("INSERT INTO core.supplier_identifiers"));
        assert!(!production_source.contains("MappingActivation"));
        assert!(production_source.contains("record_supplier_identity_candidate_v1"));
    }

    #[test]
    fn ingest_has_no_name_only_canonical_supplier_creation_path() {
        let connector_source = include_str!("../ingest_connector.rs");
        assert!(!connector_source.contains("INSERT INTO core.suppliers"));
        assert!(!connector_source.contains("VALUES($1,$2,0.9,'VERIFIED')"));
        assert!(connector_source.contains("let supplier_id: Option<Uuid> = None"));
        assert!(!connector_source.contains("supplier_id=EXCLUDED.supplier_id"));
        let public_source = include_str!("../../../public-api/src/service/entities.rs");
        assert!(!public_source.contains("core.supplier_identifiers"));
        assert!(public_source.contains("\"identifiers\":[]"));
    }

    #[test]
    fn identifier_is_hmac_protected_without_raw_value_retention() {
        let raw_identifier = "1234567890";
        let safe = protect_identifier(
            b"01234567890123456789012345678901",
            IncomingSupplierIdentifier {
                scheme: StrongIdentifierScheme::KoreanBusinessNumber,
                raw_value: raw_identifier,
            },
        );
        assert!(safe.is_ok());
        assert!(safe.is_ok_and(|safe| {
            safe.value_hmac.len() == 64 && !safe.value_hmac.contains(raw_identifier)
        }));
    }

    #[test]
    fn only_verified_proven_strong_fact_becomes_a_writer_suggestion() {
        let target_supplier_id = Uuid::new_v4();
        let observation = SupplierObservation {
            name: "same name only earns a weak score",
            strong_identifier: Some(ObservedStrongIdentifier {
                scheme: StrongIdentifierScheme::KoreanBusinessNumber,
                value_hmac: "observed-hmac",
            }),
        };
        let accepted = PersistedIdentifierFact {
            target_supplier_id,
            persisted_scheme: "KOREAN_BUSINESS_NUMBER",
            value_hmac: "observed-hmac",
            verification_status: "VERIFIED",
            proof_state: "PROVEN_V1",
            identifier_fact_digest: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        };
        let rejected = [
            PersistedIdentifierFact {
                proof_state: "LEGACY_UNPROVEN",
                ..accepted
            },
            PersistedIdentifierFact {
                verification_status: "UNVERIFIED",
                ..accepted
            },
            PersistedIdentifierFact {
                value_hmac: "different-hmac",
                ..accepted
            },
        ];

        assert!(retain_certain_suggestion(&accepted, &observation).is_some());
        assert!(
            rejected
                .iter()
                .all(|fact| retain_certain_suggestion(fact, &observation).is_none())
        );
        let name_only = SupplierObservation {
            name: observation.name,
            strong_identifier: None,
        };
        assert!(retain_certain_suggestion(&accepted, &name_only).is_none());
    }

    #[test]
    fn legacy_scheme_spelling_maps_but_legacy_unproven_never_suggests() {
        let observation = SupplierObservation {
            name: "supplier",
            strong_identifier: Some(ObservedStrongIdentifier {
                scheme: StrongIdentifierScheme::OpenDartCorpCode,
                value_hmac: "observed-hmac",
            }),
        };
        let legacy = PersistedIdentifierFact {
            target_supplier_id: Uuid::new_v4(),
            persisted_scheme: "DART_CORP_CODE",
            value_hmac: "observed-hmac",
            verification_status: "VERIFIED",
            proof_state: "LEGACY_UNPROVEN",
            identifier_fact_digest: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        };

        assert_eq!(
            StrongIdentifierScheme::from_persisted(legacy.persisted_scheme),
            Some(StrongIdentifierScheme::OpenDartCorpCode)
        );
        assert!(retain_certain_suggestion(&legacy, &observation).is_none());
    }

    #[test]
    fn writer_request_contains_only_hmac_and_current_record_coordinates() {
        let raw_identifier = "1234567890";
        let safe = protect_identifier(
            b"01234567890123456789012345678901",
            IncomingSupplierIdentifier {
                scheme: StrongIdentifierScheme::KoreanBusinessNumber,
                raw_value: raw_identifier,
            },
        );
        assert!(safe.is_ok());
        let safe = safe.unwrap_or(SafeIdentifier {
            scheme: StrongIdentifierScheme::KoreanBusinessNumber,
            value_hmac: String::new(),
        });
        let request = proposal_request(
            &IncomingSupplier {
                name: "supplier",
                identifier: None,
                source_document_id: Uuid::new_v4(),
                parsed_record_id: Uuid::new_v4(),
                record_index: 7,
            },
            &safe,
            &StrongIdentifierSuggestion {
                target_supplier_id: Uuid::new_v4(),
                identifier_fact_digest:
                    "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc".to_owned(),
            },
        );
        let keys = request
            .as_object()
            .map(|object| object.keys().map(String::as_str).collect::<BTreeSet<_>>());

        assert_eq!(
            keys,
            Some(BTreeSet::from([
                "identifierFactDigest",
                "normalizedName",
                "observedScheme",
                "observedValueHmac",
                "parsedRecordId",
                "recordIndex",
                "schemaVersion",
                "scoreBasisPoints",
                "sourceDocumentId",
                "targetSupplierId",
            ]))
        );
        assert!(!request.to_string().contains(raw_identifier));
        assert_eq!(
            request.get("scoreBasisPoints").and_then(Value::as_u64),
            Some(10_000)
        );
    }
}
