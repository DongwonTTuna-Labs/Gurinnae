use gurine_auth::envelope::{EnvelopeKey, EnvelopeKeyRing, encrypt};
use gurine_publication_policy::natural_person::{
    NATURAL_PERSON_RULESET_VERSION, NaturalPersonFindingBasis, RegisteredPersonName,
};

use super::*;

type TestResult = Result<(), Box<dyn std::error::Error>>;

fn payload() -> Value {
    json!({
        "publicationState":"PUBLISHED_ANOMALY",
        "title":"가상 계약 점검",
        "summary":"계약 자료 비교",
        "nonConclusion":"현재 자료만으로 위법성이나 부패 여부를 판단할 수 없습니다.",
        "agencyName":"가상시청",
        "contractName":"정보화 사업",
        "claims":[{"text":"박민수 대표 관련 자료","limitations":["재직 기간 미확인"]}],
        "evidence":[{
            "title":"계약서",
            "documentTitle":"계약 원문",
            "publisher":"가상시청",
            "pageAnchor":"3쪽",
            "sourceLocator":"https://official.example/contracts/1",
            "publicExcerpt":"박민수 대표 서명"
        }],
        "responses":[{"partyName":"가상 주식회사","excerpt":"추가 확인 중"}]
    })
}

#[test]
fn scanner_tree_covers_nested_public_text_without_scanning_internal_ids() -> TestResult {
    let payload = payload();
    let tree = publication_text_tree(&payload)?;
    let registered = RegisteredPersonName::new("박민수")?;
    let assessment = scan_public_text(&tree, &[registered])?;

    assert!(assessment.findings.iter().any(|finding| {
        finding.path == "/claims/0/text"
            && finding.basis == NaturalPersonFindingBasis::RegisteredPersonExact
    }));
    assert!(
        assessment
            .findings
            .iter()
            .any(|finding| finding.path == "/evidence/0/publicExcerpt")
    );
    assert!(
        assessment
            .findings
            .iter()
            .all(|finding| !finding.path.contains("Id"))
    );
    Ok(())
}

#[test]
fn caller_cannot_supply_server_owned_publication_guard_authority() {
    for key in SERVER_OWNED_PUBLICATION_GUARD_KEYS {
        let request = Map::from_iter([(key.to_owned(), json!({}))]);
        assert!(matches!(
            reject_caller_publication_guard_authority(&request),
            Err(ServiceError::InvalidRequest)
        ));
    }
    assert!(
        reject_caller_publication_guard_authority(&Map::from_iter([
            ("caseId".to_owned(), json!(Uuid::new_v4())),
            ("reviewSnapshotId".to_owned(), json!(Uuid::new_v4())),
            ("locale".to_owned(), json!("ko-KR")),
        ]))
        .is_ok()
    );
}

#[test]
fn official_confirmation_is_required_only_for_confirmed_state() {
    let mut confirmed = payload();
    confirmed["publicationState"] = json!("OFFICIALLY_CONFIRMED");
    assert!(
        bind_preview_publication_contract(
            &mut confirmed,
            &Map::from_iter([(
                "officialConfirmation".to_owned(),
                json!({
                    "institution":"가상법원",
                    "documentType":"판결문",
                    "documentDate":"2026-08-01",
                    "confirmedScope":"문서 기재 범위",
                    "sourceLocator":"https://official.example/judgments/1",
                    "sourceDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                }),
            )]),
        )
        .is_ok()
    );
    let mut missing = payload();
    missing["publicationState"] = json!("OFFICIALLY_CONFIRMED");
    assert!(matches!(
        bind_preview_publication_contract(&mut missing, &Map::new()),
        Err(ServiceError::PreconditionFailed)
    ));
    let mut ordinary = payload();
    assert!(matches!(
        bind_preview_publication_contract(
            &mut ordinary,
            &Map::from_iter([("officialConfirmation".to_owned(), json!({}))]),
        ),
        Err(ServiceError::InvalidRequest)
    ));
}

#[test]
fn encrypted_registered_person_context_is_bound_to_exact_aad_and_key() -> TestResult {
    let context_id = Uuid::parse_str("10000000-0000-4000-8000-000000000021")?;
    let node_id = Uuid::parse_str("10000000-0000-4000-8000-000000000022")?;
    let aad = format!("core.relationship_graph_person_context_v3/{context_id}/contextual_name/v1");
    let keys = EnvelopeKeyRing {
        current: EnvelopeKey::new([7_u8; 32]),
        previous: None,
    };
    let token = encrypt(
        "gurine-fe-v1",
        &keys.current,
        &[&aad],
        " 김·하 늘 ".as_bytes(),
    )?;
    let key_id = token
        .split('.')
        .nth(1)
        .ok_or_else(|| std::io::Error::other("test envelope has no key id"))?
        .to_owned();
    let context = registered_person_context(
        node_id,
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".to_owned(),
        context_id,
        token.into_bytes(),
        sha256(" 김·하 늘 ".as_bytes()),
        sha256(aad.as_bytes()),
        key_id,
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb".to_owned(),
        &keys,
    )?;
    assert_eq!(context.normalized_name, "김하늘");
    Ok(())
}

#[test]
fn registered_person_set_and_finding_bindings_use_only_opaque_digests() -> TestResult {
    let context = RegisteredPersonContext {
        person_node_id: Uuid::parse_str("10000000-0000-4000-8000-000000000031")?,
        topology_digest: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            .to_owned(),
        context_id: Uuid::parse_str("10000000-0000-4000-8000-000000000032")?,
        person_name_digest: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            .to_owned(),
        normalized_name: "박민수".to_owned(),
        display_name: "박민수".to_owned(),
    };
    let payload = payload();
    let tree = publication_text_tree(&payload)?;
    let registered = RegisteredPersonName::new(&context.display_name)?;
    let assessment = scan_public_text(&tree, &[registered])?;
    let contexts = vec![context];
    let set_digest = registered_name_set_sha256(&contexts)?;
    let bindings = bind_publication_findings(&tree, &assessment, &contexts)?;
    assert!(is_sha256(&set_digest));
    assert_eq!(bindings.len(), 4);
    let (registered, ambiguous): (Vec<_>, Vec<_>) = bindings.iter().partition(|binding| {
        binding.finding.basis == NaturalPersonFindingBasis::RegisteredPersonExact
    });
    assert_eq!(registered.len(), 2);
    assert!(registered.iter().all(|binding| {
        is_sha256(&binding.matched_text_sha256)
            && binding.context_id == Some(contexts[0].context_id)
            && binding.person_name_digest.as_deref()
                == Some("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
    }));
    assert_eq!(ambiguous.len(), 2);
    assert!(ambiguous.iter().all(|binding| {
        binding.finding.basis == NaturalPersonFindingBasis::TitleAdjacentKoreanName
            && is_sha256(&binding.matched_text_sha256)
            && binding.person_node_id.is_none()
            && binding.topology_digest.is_none()
            && binding.context_id.is_none()
            && binding.person_name_digest.is_none()
    }));
    let scan = PublicationScan {
        assessment,
        registered_name_set_sha256: set_digest,
        finding_bindings: bindings,
    };
    let wire = publication_scan_payload(&scan)?;
    assert_eq!(wire.as_object().map(Map::len), Some(5));
    assert_eq!(wire["findings"][0].as_object().map(Map::len), Some(10));
    assert_eq!(wire["rulesetVersion"], NATURAL_PERSON_RULESET_VERSION);
    assert_eq!(
        wire["findings"][0]["detectorKind"],
        "REGISTERED_PERSON_EXACT"
    );
    assert_eq!(wire["findings"][0]["jsonPointer"], "/claims/0/text");
    assert_eq!(wire["findings"][0]["startUtf16"], 0);
    assert_eq!(wire["findings"][0]["endUtf16"], 3);
    assert_eq!(
        wire["findings"][0]["contextId"],
        contexts[0].context_id.to_string()
    );
    assert!(
        !wire.to_string().contains(&contexts[0].display_name),
        "owner payload must not persist registered PERSON plaintext"
    );
    Ok(())
}

#[test]
fn duplicate_canonical_registered_person_names_fail_closed() -> TestResult {
    let first = RegisteredPersonContext {
        person_node_id: Uuid::parse_str("10000000-0000-4000-8000-000000000041")?,
        topology_digest: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            .to_owned(),
        context_id: Uuid::parse_str("10000000-0000-4000-8000-000000000042")?,
        person_name_digest: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            .to_owned(),
        normalized_name: "김하늘".to_owned(),
        display_name: "김하늘".to_owned(),
    };
    let duplicate = RegisteredPersonContext {
        person_node_id: Uuid::parse_str("10000000-0000-4000-8000-000000000043")?,
        topology_digest: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
            .to_owned(),
        context_id: Uuid::parse_str("10000000-0000-4000-8000-000000000044")?,
        person_name_digest: "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
            .to_owned(),
        normalized_name: "김하늘".to_owned(),
        display_name: "김 하늘".to_owned(),
    };

    assert!(matches!(
        reject_ambiguous_registered_names(&[first, duplicate]),
        Err(ServiceError::PreconditionFailed)
    ));
    Ok(())
}

#[test]
fn ambiguous_title_finding_has_no_person_identity_binding() -> TestResult {
    let payload = json!({
        "publicationState":"PUBLISHED_ANOMALY",
        "title":"계약 기록",
        "summary":"대표이사 김하늘은 답변함",
        "nonConclusion":"현재 자료만으로 위법성이나 부패 여부를 판단할 수 없습니다.",
        "claims":[],
        "evidence":[],
        "responses":[]
    });
    let tree = publication_text_tree(&payload)?;
    let assessment = scan_public_text(&tree, &[])?;
    let bindings = bind_publication_findings(&tree, &assessment, &[])?;
    assert_eq!(bindings.len(), 1);
    assert!(bindings[0].person_node_id.is_none());
    assert!(bindings[0].topology_digest.is_none());
    assert!(bindings[0].context_id.is_none());
    assert!(bindings[0].person_name_digest.is_none());
    let scan = PublicationScan {
        assessment,
        registered_name_set_sha256:
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".to_owned(),
        finding_bindings: bindings,
    };
    let wire = publication_scan_payload(&scan)?;
    assert_eq!(wire["rulesetVersion"], NATURAL_PERSON_RULESET_VERSION);
    assert_eq!(
        wire["findings"][0]["detectorKind"],
        "TITLE_ADJACENT_KOREAN_NAME"
    );
    assert_eq!(wire["findings"][0]["jsonPointer"], "/summary");
    assert_eq!(wire["findings"][0]["startUtf16"], 5);
    assert_eq!(wire["findings"][0]["endUtf16"], 8);
    assert!(wire["findings"][0]["contextId"].is_null());
    Ok(())
}

#[test]
fn utf16_finding_ranges_reject_surrogate_boundaries() -> TestResult {
    assert_eq!(utf16_slice("가😀나", 1, 3)?, "😀");
    assert!(matches!(
        utf16_slice("가😀나", 2, 3),
        Err(ServiceError::Persistence)
    ));
    Ok(())
}
