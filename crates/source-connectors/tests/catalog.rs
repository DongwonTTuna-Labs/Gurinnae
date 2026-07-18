use std::collections::{BTreeMap, BTreeSet};

use gurine_source_connectors::{koneps, operations};

#[test]
fn authority_connector_surface_is_exact() {
    let records = operations().collect::<Vec<_>>();
    assert_eq!(records.len(), 44);
    let ids = records
        .iter()
        .map(|record| record.id)
        .collect::<BTreeSet<_>>();
    assert_eq!(ids.len(), 44);
    let mut counts = BTreeMap::new();
    for record in records {
        *counts.entry(record.connector_id).or_insert(0_usize) += 1;
        assert_eq!(record.method, "GET");
        assert!(!record.remote_path.starts_with("http://"));
        assert!(!record.remote_path.starts_with("https://"));
    }
    assert_eq!(counts["koneps-contracts"], 16);
    assert_eq!(counts["koneps-notices"], 17);
    assert_eq!(counts["open-dart"], 4);
    assert_eq!(counts["local-finance"], 3);
    assert_eq!(counts["alio"], 2);
    assert_eq!(counts["audit-results"], 2);
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
