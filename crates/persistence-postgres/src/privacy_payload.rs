use base64::{Engine as _, engine::general_purpose::STANDARD};
use gurine_application::privacy::{CreatePrivacyRequest, PrivacyIdentityProofClaim};
use serde_json::{Value, json};

use crate::privacy::PrivacyRepositoryError;

const CREATE_OWNER_FIELDS: [&str; 25] = [
    "communicationEndpointAadDigest",
    "communicationEndpointChannel",
    "communicationEndpointCiphertextBase64",
    "communicationEndpointEncryptionKeyId",
    "communicationEndpointHmac",
    "communicationEndpointHmacKeyVersion",
    "communicationEndpointId",
    "communicationSubjectHmacKeyVersion",
    "communicationSubjectId",
    "communicationSubjectLocale",
    "encryptionKeyId",
    "explicitVoiceConsentReceiptId",
    "identityProof",
    "jurisdiction",
    "privacyRequestId",
    "receiptTokenHmac",
    "receiptTokenKeyVersion",
    "receiptTokenSha256",
    "requestType",
    "scope",
    "scopeAadDigest",
    "scopeCiphertextBase64",
    "statementAadDigest",
    "statementCiphertextBase64",
    "statementSha256",
];

pub(crate) fn create_owner_payload(
    request: &CreatePrivacyRequest,
) -> Result<Value, PrivacyRepositoryError> {
    let payload = json!({
        "privacyRequestId": request.privacy_request_id,
        "requestType": request.request_type.as_str(),
        "jurisdiction": &request.jurisdiction,
        "identityProof": identity_proof_payload(&request.identity_proof),
        "scope": &request.scope,
        "scopeCiphertextBase64": STANDARD.encode(request.encrypted_scope.ciphertext()),
        "scopeAadDigest": request.encrypted_scope.aad_digest().as_str(),
        "statementCiphertextBase64": STANDARD.encode(request.encrypted_statement.ciphertext()),
        "statementSha256": request.encrypted_statement.digest().as_str(),
        "statementAadDigest": request.encrypted_statement.aad_digest().as_str(),
        "encryptionKeyId": request.encrypted_scope.encryption_key_id(),
        "communicationSubjectId": request.communication_subject_id,
        "communicationSubjectHmacKeyVersion": &request.communication_subject_hmac_key_version,
        "communicationSubjectLocale": &request.contact.locale,
        "communicationEndpointId": request.contact.endpoint_id,
        "communicationEndpointChannel": request.contact.channel.persistence_channel(),
        "communicationEndpointHmac": request.contact.endpoint_hmac.as_str(),
        "communicationEndpointHmacKeyVersion": &request.contact.hmac_key_version,
        "communicationEndpointCiphertextBase64": STANDARD.encode(&request.contact.endpoint_ciphertext),
        "communicationEndpointEncryptionKeyId": &request.contact.encryption_key_id,
        "communicationEndpointAadDigest": request.contact.endpoint_aad_digest.as_str(),
        "explicitVoiceConsentReceiptId": request.contact.explicit_voice_consent_receipt_id,
        "receiptTokenHmac": request.receipt_token_hmac.as_str(),
        "receiptTokenSha256": request.receipt_token_sha256.as_str(),
        "receiptTokenKeyVersion": &request.receipt_token_key_version,
    });
    if payload.as_object().is_some_and(|object| {
        object.len() == CREATE_OWNER_FIELDS.len()
            && object
                .keys()
                .all(|field| CREATE_OWNER_FIELDS.contains(&field.as_str()))
    }) {
        Ok(payload)
    } else {
        Err(PrivacyRepositoryError::InvalidOwnerResult)
    }
}

fn identity_proof_payload(proof: &PrivacyIdentityProofClaim) -> Value {
    match proof {
        PrivacyIdentityProofClaim::ResponseReceipt {
            receipt_id,
            possession_token_hmac,
        } => json!({
            "kind": "RESPONSE_RECEIPT",
            "receiptId": receipt_id,
            "possessionTokenHmac": possession_token_hmac.as_str(),
        }),
        PrivacyIdentityProofClaim::VerifiedEndpoint {
            endpoint_challenge_id,
            proof_kind,
            proof_verifier_hmac,
            provider,
        } => json!({
            "kind": "VERIFIED_ENDPOINT",
            "challengeId": endpoint_challenge_id,
            "proofKind": proof_kind.as_str(),
            "proofVerifierHmac": proof_verifier_hmac.as_str(),
            "provider": provider.map(|value| value.as_str()),
        }),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use gurine_application::privacy::{EndpointProofKind, PrivacyIdentityProofClaim};
    use gurine_domain::privacy::PrivacyDigest;
    use uuid::Uuid;

    use super::{CREATE_OWNER_FIELDS, identity_proof_payload};

    const SHA: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    #[test]
    fn create_payload_field_set_stays_closed() {
        let expected = BTreeSet::from(CREATE_OWNER_FIELDS);
        assert_eq!(expected.len(), 25);
        assert!(!expected.contains("subjectProofHash"));
        assert!(!expected.contains("scopeSha256"));
        assert!(!expected.contains("subjectScopeDigest"));
    }

    #[test]
    fn identity_proof_payload_contains_only_digest_authority() {
        let proof = PrivacyIdentityProofClaim::VerifiedEndpoint {
            endpoint_challenge_id: Uuid::from_u128(1),
            proof_kind: EndpointProofKind::EmailLink,
            proof_verifier_hmac: PrivacyDigest::try_new(SHA)
                .unwrap_or_else(|error| panic!("digest: {error}")),
            provider: None,
        };
        let payload = identity_proof_payload(&proof);
        let keys = payload
            .as_object()
            .map(|object| object.keys().map(String::as_str).collect::<BTreeSet<_>>())
            .unwrap_or_else(|| panic!("identity proof must be an object"));
        assert_eq!(
            keys,
            BTreeSet::from([
                "challengeId",
                "kind",
                "proofKind",
                "proofVerifierHmac",
                "provider",
            ])
        );
        assert!(!payload.to_string().contains("token"));
    }
}
