use std::collections::{BTreeMap, BTreeSet};

use gurine_source_connectors::{koneps, koneps_bid_results, open_dart, operations, pps_sanctions};
use serde_json::{Value, json};

#[test]
fn authority_connector_surface_is_exact() {
    let records = operations().collect::<Vec<_>>();
    assert_eq!(records.len(), 56);
    let ids = records
        .iter()
        .map(|record| record.id)
        .collect::<BTreeSet<_>>();
    assert_eq!(ids.len(), 56);
    let mut counts = BTreeMap::new();
    for record in records {
        *counts.entry(record.connector_id).or_insert(0_usize) += 1;
        assert_eq!(record.method, "GET");
        assert!(!record.remote_path.starts_with("http://"));
        assert!(!record.remote_path.starts_with("https://"));
    }
    assert_eq!(counts["koneps-contracts"], 16);
    assert_eq!(counts["koneps-notices"], 17);
    assert_eq!(counts["koneps-bid-results"], 8);
    assert_eq!(counts["open-dart"], 6);
    assert_eq!(counts["pps-sanctions"], 2);
    assert_eq!(counts["local-finance"], 3);
    assert_eq!(counts["alio"], 2);
    assert_eq!(counts["audit-results"], 2);
}

#[test]
fn koneps_opening_metadata_never_parses_opaque_participant_text() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../specs/connectors/koneps-bid-results/fixtures/success.json"
    ))
    .expect("structural opening fixture");
    let record = fixture
        .pointer("/response/body/items/item/0")
        .expect("opening record");
    let first =
        koneps_bid_results::normalize_metadata("opening-goods-search", record, b"fixture-key")
            .expect("closed opening metadata");
    let mut changed = record.clone();
    changed["opengCorpInfo"] = json!("완전히 다른 불투명 참가업체 텍스트");
    changed["opengRsltNtcCntnts"] = json!("완전히 다른 원문 안내");
    let second =
        koneps_bid_results::normalize_metadata("opening-goods-search", &changed, b"fixture-key")
            .expect("closed opening metadata");
    assert_eq!(first, second);
    assert_eq!(first.participant_count, Some(3));
    assert_eq!(first.winner_name, None);
    assert!(!format!("{first:?}").contains("참가업체"));
}

#[test]
fn koneps_award_metadata_drops_person_contact_fields_and_hashes_business_number() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../specs/connectors/koneps-bid-results/fixtures/award-success.json"
    ))
    .expect("structural award fixture");
    let record = fixture
        .pointer("/response/body/items/item/0")
        .expect("award record");
    let first =
        koneps_bid_results::normalize_metadata("award-goods-search", record, b"fixture-key")
            .expect("closed award metadata");
    let mut changed = record.clone();
    changed["fnlSucsfCorpOfcl"] = json!("다른 담당자");
    changed["bidwinnrCeoNm"] = json!("다른 대표자");
    changed["bidwinnrAdrs"] = json!("다른 주소");
    changed["bidwinnrTelNo"] = json!("다른 전화번호");
    let second =
        koneps_bid_results::normalize_metadata("award-goods-search", &changed, b"fixture-key")
            .expect("closed award metadata");
    assert_eq!(first, second);
    assert!(
        first
            .winner_business_number_hmac
            .as_deref()
            .is_some_and(|digest| digest.len() == 64)
    );
    let rendered = format!("{first:?}");
    for forbidden in ["0000000000", "담당자", "대표자", "주소", "전화번호"] {
        assert!(!rendered.contains(forbidden));
    }
}

#[test]
fn open_dart_person_projection_is_closed_and_demographics_do_not_affect_identity() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../specs/connectors/open-dart/fixtures/officers-success.json"
    ))
    .expect("structural officer fixture");
    let record = fixture.pointer("/response/list/0").expect("officer record");
    let first = open_dart::normalize_person_observation("dart-executive-status", record, "/list/0")
        .expect("minimal person context");
    let mut changed = record.clone();
    changed["sexdstn"] = json!("남");
    changed["birth_ym"] = json!("190001");
    changed["adres"] = json!("저장 금지 주소");
    changed["tel"] = json!("저장 금지 전화");
    changed["mxmm_shrholdr_relate"] = json!("가족");
    let second =
        open_dart::normalize_person_observation("dart-executive-status", &changed, "/list/0")
            .expect("minimal person context");
    assert_eq!(first, second);
    assert_eq!(first.identifier_digest.len(), 64);
    let rendered = format!("{first:?}");
    for forbidden in ["198001", "190001", "저장 금지", "가족"] {
        assert!(!rendered.contains(forbidden));
    }
}

#[test]
fn open_dart_shareholder_relation_is_not_a_person_attribute_or_family_edge() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../specs/connectors/open-dart/fixtures/shareholders-success.json"
    ))
    .expect("structural shareholder fixture");
    let record = fixture
        .pointer("/response/list/0")
        .expect("shareholder record");
    let observation = open_dart::normalize_shareholder_observation(
        "dart-major-shareholder-status",
        record,
        "/list/0",
    )
    .expect("closed shareholder observation");
    assert!(!observation.holder_name.is_empty());
    assert_eq!(observation.observation_digest.len(), 64);
    assert!(!format!("{observation:?}").contains("본인"));
    assert!(
        open_dart::normalize_person_observation("dart-major-shareholder-status", record, "/list/0")
            .is_err()
    );
}

#[test]
fn open_dart_observation_digest_never_merges_same_name_across_contexts() {
    let first_record = json!({
        "rcept_no":"R-1","corp_code":"00000001","corp_name":"가상 회사 1",
        "nm":"동명이인","ofcps":"이사"
    });
    let second_record = json!({
        "rcept_no":"R-2","corp_code":"00000002","corp_name":"가상 회사 2",
        "nm":"동명이인","ofcps":"이사"
    });
    let first =
        open_dart::normalize_person_observation("dart-executive-status", &first_record, "/list/0")
            .expect("first observation");
    let second =
        open_dart::normalize_person_observation("dart-executive-status", &second_record, "/list/0")
            .expect("second observation");
    assert_eq!(first.contextual_name, second.contextual_name);
    assert_ne!(first.identifier_digest, second.identifier_digest);
}

#[test]
fn sanctions_connector_stays_disabled_until_both_external_gates_are_approved() {
    use pps_sanctions::SanctionActivationEvidence;

    assert_eq!(pps_sanctions::ACTIVATION_STATE, "DISABLED");
    assert_eq!(
        pps_sanctions::NORMALIZATION_BLOCKER,
        "PPS_SANCTIONS_REUSE_RIGHTS_UNCONFIRMED"
    );
    assert!(!pps_sanctions::normalized_output_allowed(
        SanctionActivationEvidence {
            rights_approved: false,
            schema_fingerprint_approved: true,
            preflight_recorded: true,
        }
    ));
    assert!(!pps_sanctions::normalized_output_allowed(
        SanctionActivationEvidence {
            rights_approved: true,
            schema_fingerprint_approved: false,
            preflight_recorded: true,
        }
    ));
    assert!(!pps_sanctions::normalized_output_allowed(
        SanctionActivationEvidence {
            rights_approved: true,
            schema_fingerprint_approved: true,
            preflight_recorded: false,
        }
    ));
    assert!(pps_sanctions::normalized_output_allowed(
        SanctionActivationEvidence {
            rights_approved: true,
            schema_fingerprint_approved: true,
            preflight_recorded: true,
        }
    ));
}

#[test]
fn koneps_json_and_xml_share_the_same_typed_digest() {
    let json = br#"{"bidNtceNo":"N-001","bidNtceOrd":"1","bidNtceNm":"Network equipment","dminsttNm":"Gurinnae City","cntrctCorpNm":"Example Co","bizno":"123-45-67890"}"#;
    let xml = br#"<item><bidNtceNo>N-001</bidNtceNo><bidNtceOrd>1</bidNtceOrd><bidNtceNm>Network equipment</bidNtceNm><dminsttNm>Gurinnae City</dminsttNm><cntrctCorpNm>Example Co</cntrctCorpNm><bizno>123-45-67890</bizno></item>"#;
    let from_json = koneps::parse_json_record("contract-goods-list", json, b"fixture-key")
        .expect("typed JSON fixture");
    let from_xml = koneps::parse_xml_record("contract-goods-list", xml, b"fixture-key")
        .expect("typed XML fixture");
    assert_eq!(from_json, from_xml);
    assert_eq!(from_json.record_digest.len(), 64);
    assert!(
        from_json
            .supplier_identifier_hmac
            .as_deref()
            .is_some_and(|digest| digest.len() == 64
                && digest
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()))
    );
}

#[test]
fn koneps_unknown_fields_are_not_promoted() {
    let json = br#"{"bidNtceNo":"N-002","bidNtceOrd":"1","bidNtceNm":"Service","dminsttNm":"Gurinnae City","secretProviderField":"must-remain-raw"}"#;
    let record = koneps::parse_json_record("notice-service-list", json, b"fixture-key")
        .expect("typed JSON fixture");
    assert_eq!(record.supplier_name, None);
    assert_eq!(record.supplier_identifier_hmac, None);
}
