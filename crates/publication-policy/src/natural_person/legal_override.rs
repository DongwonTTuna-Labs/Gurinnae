use serde::Serialize;
use sha2::{Digest, Sha256};
use thiserror::Error;

use super::scanner::NaturalPersonAssessment;

pub const LEGAL_OVERRIDE_RECEIPT_VERSION: &str = "named-individual-legal-override-v1";

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum LegalOverrideReason {
    PublicFigure,
    OfficialDispositionQuote,
}

impl LegalOverrideReason {
    const fn wire_name(self) -> &'static str {
        match self {
            Self::PublicFigure => "PUBLIC_FIGURE",
            Self::OfficialDispositionQuote => "OFFICIAL_DISPOSITION_QUOTE",
        }
    }
}

pub struct LegalOverrideReceiptPreimage<'a> {
    pub public_text_sha256: &'a str,
    pub ruleset_version: &'a str,
    pub reason: LegalOverrideReason,
    pub official_source_locator: &'a str,
    pub official_source_sha256: &'a str,
    pub legal_reviewer_id: &'a str,
}

pub struct LegalOverrideReceipt<'a> {
    pub preimage: LegalOverrideReceiptPreimage<'a>,
    pub receipt_sha256: &'a str,
}

pub struct LegalReviewParties<'a> {
    pub publication_author_id: &'a str,
    pub editorial_reviewer_id: &'a str,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReceiptDerivedLegalReview {
    legal_reviewed: bool,
    receipt_sha256: String,
    public_text_sha256: String,
    ruleset_version: String,
}

impl ReceiptDerivedLegalReview {
    pub const fn legal_reviewed(&self) -> bool {
        self.legal_reviewed
    }

    pub fn receipt_sha256(&self) -> &str {
        &self.receipt_sha256
    }
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum NaturalPersonPublicationBlocker {
    #[error("named individual requires an exact legal-review override receipt")]
    LegalOverrideRequired,
    #[error("legal-review override receipt does not bind this publication text and ruleset")]
    LegalOverrideScopeMismatch,
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum LegalOverrideError {
    #[error("named-individual finding is absent")]
    FindingAbsent,
    #[error("legal override public-text digest does not match the exact publication text")]
    PublicTextDigestMismatch,
    #[error("legal override ruleset version does not match the scanner assessment")]
    RulesetVersionMismatch,
    #[error("legal override official source locator is absent")]
    OfficialSourceLocatorMissing,
    #[error("legal override source digest is invalid")]
    OfficialSourceDigestInvalid,
    #[error("legal review parties are incomplete")]
    ReviewPartiesIncomplete,
    #[error("legal reviewer is not independent")]
    ReviewerNotIndependent,
    #[error("legal override receipt digest is invalid")]
    ReceiptDigestInvalid,
}

pub fn legal_override_receipt_sha256(preimage: &LegalOverrideReceiptPreimage<'_>) -> String {
    let mut hasher = Sha256::new();
    for value in [
        LEGAL_OVERRIDE_RECEIPT_VERSION,
        preimage.public_text_sha256,
        preimage.ruleset_version,
        preimage.reason.wire_name(),
        preimage.official_source_locator,
        preimage.official_source_sha256,
        preimage.legal_reviewer_id,
    ] {
        hasher.update((value.len() as u64).to_be_bytes());
        hasher.update(value.as_bytes());
    }
    hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

pub fn verify_legal_override(
    assessment: &NaturalPersonAssessment,
    receipt: &LegalOverrideReceipt<'_>,
    parties: &LegalReviewParties<'_>,
) -> Result<ReceiptDerivedLegalReview, LegalOverrideError> {
    if assessment.findings.is_empty() {
        return Err(LegalOverrideError::FindingAbsent);
    }
    if receipt.preimage.public_text_sha256 != assessment.public_text_sha256 {
        return Err(LegalOverrideError::PublicTextDigestMismatch);
    }
    if receipt.preimage.ruleset_version != assessment.ruleset_version {
        return Err(LegalOverrideError::RulesetVersionMismatch);
    }
    if receipt.preimage.official_source_locator.trim().is_empty() {
        return Err(LegalOverrideError::OfficialSourceLocatorMissing);
    }
    if !is_sha256(receipt.preimage.official_source_sha256) {
        return Err(LegalOverrideError::OfficialSourceDigestInvalid);
    }
    if parties.publication_author_id.trim().is_empty()
        || parties.editorial_reviewer_id.trim().is_empty()
        || receipt.preimage.legal_reviewer_id.trim().is_empty()
    {
        return Err(LegalOverrideError::ReviewPartiesIncomplete);
    }
    if receipt.preimage.legal_reviewer_id == parties.publication_author_id
        || receipt.preimage.legal_reviewer_id == parties.editorial_reviewer_id
    {
        return Err(LegalOverrideError::ReviewerNotIndependent);
    }
    let expected_receipt = legal_override_receipt_sha256(&receipt.preimage);
    if !constant_time_hex_eq(receipt.receipt_sha256, &expected_receipt) {
        return Err(LegalOverrideError::ReceiptDigestInvalid);
    }
    Ok(ReceiptDerivedLegalReview {
        legal_reviewed: true,
        receipt_sha256: expected_receipt,
        public_text_sha256: assessment.public_text_sha256.clone(),
        ruleset_version: assessment.ruleset_version.to_owned(),
    })
}

pub fn enforce_natural_person_publication_gate(
    assessment: &NaturalPersonAssessment,
    legal_review: Option<&ReceiptDerivedLegalReview>,
) -> Result<(), NaturalPersonPublicationBlocker> {
    if !assessment.blocks_publication_without_override() {
        return Ok(());
    }
    let proof = legal_review.ok_or(NaturalPersonPublicationBlocker::LegalOverrideRequired)?;
    if proof.public_text_sha256 != assessment.public_text_sha256
        || proof.ruleset_version != assessment.ruleset_version
    {
        return Err(NaturalPersonPublicationBlocker::LegalOverrideScopeMismatch);
    }
    Ok(())
}

fn is_sha256(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn constant_time_hex_eq(left: &str, right: &str) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.bytes()
        .zip(right.bytes())
        .fold(0_u8, |difference, (left_byte, right_byte)| {
            difference | (left_byte.to_ascii_lowercase() ^ right_byte.to_ascii_lowercase())
        })
        == 0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::natural_person::{PublicTextNode, RegisteredPersonName, scan_public_text};

    fn assessment() -> NaturalPersonAssessment {
        let document = PublicTextNode::object(vec![(
            "summary",
            PublicTextNode::text("김민수 전 장관 관련 공식 처분"),
        )]);
        let registered = RegisteredPersonName::new("김민수").expect("valid test PERSON");
        scan_public_text(&document, &[registered]).expect("public text scan")
    }

    fn preimage<'a>(assessment: &'a NaturalPersonAssessment) -> LegalOverrideReceiptPreimage<'a> {
        LegalOverrideReceiptPreimage {
            public_text_sha256: &assessment.public_text_sha256,
            ruleset_version: assessment.ruleset_version,
            reason: LegalOverrideReason::OfficialDispositionQuote,
            official_source_locator: "https://official.example/dispositions/1",
            official_source_sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            legal_reviewer_id: "legal-reviewer",
        }
    }

    fn parties() -> LegalReviewParties<'static> {
        LegalReviewParties {
            publication_author_id: "author",
            editorial_reviewer_id: "editor",
        }
    }

    #[test]
    fn exact_receipt_derives_legal_reviewed_instead_of_accepting_a_boolean() {
        let assessment = assessment();
        let preimage = preimage(&assessment);
        let digest = legal_override_receipt_sha256(&preimage);
        let receipt = LegalOverrideReceipt {
            preimage,
            receipt_sha256: &digest,
        };

        let proof = verify_legal_override(&assessment, &receipt, &parties())
            .expect("exact immutable receipt must pass");
        assert!(proof.legal_reviewed());
        assert_eq!(proof.receipt_sha256(), digest);
        assert_eq!(
            enforce_natural_person_publication_gate(&assessment, Some(&proof)),
            Ok(())
        );
    }

    #[test]
    fn changed_public_text_cannot_reuse_an_override() {
        let original = assessment();
        let preimage = preimage(&original);
        let digest = legal_override_receipt_sha256(&preimage);
        let receipt = LegalOverrideReceipt {
            preimage,
            receipt_sha256: &digest,
        };
        let changed_document = PublicTextNode::text("김민수 전 장관 관련 공식 처분 추가");
        let registered = RegisteredPersonName::new("김민수").expect("valid test PERSON");
        let changed = scan_public_text(&changed_document, &[registered]).expect("scan");

        assert_eq!(
            verify_legal_override(&changed, &receipt, &parties()),
            Err(LegalOverrideError::PublicTextDigestMismatch)
        );
    }

    #[test]
    fn receipt_digest_binds_reason_source_and_reviewer() {
        let assessment = assessment();
        let preimage = preimage(&assessment);
        let digest = legal_override_receipt_sha256(&preimage);
        let changed = LegalOverrideReceiptPreimage {
            reason: LegalOverrideReason::PublicFigure,
            ..preimage
        };
        let receipt = LegalOverrideReceipt {
            preimage: changed,
            receipt_sha256: &digest,
        };

        assert_eq!(
            verify_legal_override(&assessment, &receipt, &parties()),
            Err(LegalOverrideError::ReceiptDigestInvalid)
        );
    }

    #[test]
    fn reviewer_must_be_independent_from_author_and_editor() {
        let assessment = assessment();
        let mut preimage = preimage(&assessment);
        preimage.legal_reviewer_id = "editor";
        let digest = legal_override_receipt_sha256(&preimage);
        let receipt = LegalOverrideReceipt {
            preimage,
            receipt_sha256: &digest,
        };

        assert_eq!(
            verify_legal_override(&assessment, &receipt, &parties()),
            Err(LegalOverrideError::ReviewerNotIndependent)
        );
    }

    #[test]
    fn named_individual_blocks_without_receipt_and_proof_cannot_cross_publications() {
        let original = assessment();
        assert_eq!(
            enforce_natural_person_publication_gate(&original, None),
            Err(NaturalPersonPublicationBlocker::LegalOverrideRequired)
        );
        let preimage = preimage(&original);
        let digest = legal_override_receipt_sha256(&preimage);
        let receipt = LegalOverrideReceipt {
            preimage,
            receipt_sha256: &digest,
        };
        let proof = verify_legal_override(&original, &receipt, &parties()).expect("valid proof");

        let changed_document = PublicTextNode::text("김민수 전 장관의 다른 공개 문장");
        let registered = RegisteredPersonName::new("김민수").expect("valid test PERSON");
        let changed = scan_public_text(&changed_document, &[registered]).expect("scan");
        assert_eq!(
            enforce_natural_person_publication_gate(&changed, Some(&proof)),
            Err(NaturalPersonPublicationBlocker::LegalOverrideScopeMismatch)
        );
    }

    #[test]
    fn empty_source_and_non_hex_digest_fail_closed() {
        let assessment = assessment();
        let mut missing_locator = preimage(&assessment);
        missing_locator.official_source_locator = " ";
        let missing_digest = legal_override_receipt_sha256(&missing_locator);
        let missing_receipt = LegalOverrideReceipt {
            preimage: missing_locator,
            receipt_sha256: &missing_digest,
        };
        assert_eq!(
            verify_legal_override(&assessment, &missing_receipt, &parties()),
            Err(LegalOverrideError::OfficialSourceLocatorMissing)
        );

        let mut invalid_source = preimage(&assessment);
        invalid_source.official_source_sha256 = "not-a-sha";
        let invalid_digest = legal_override_receipt_sha256(&invalid_source);
        let invalid_receipt = LegalOverrideReceipt {
            preimage: invalid_source,
            receipt_sha256: &invalid_digest,
        };
        assert_eq!(
            verify_legal_override(&assessment, &invalid_receipt, &parties()),
            Err(LegalOverrideError::OfficialSourceDigestInvalid)
        );
    }
}
