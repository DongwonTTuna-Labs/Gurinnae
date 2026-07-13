use std::collections::{BTreeMap, BTreeSet};

use gurine_source_connectors::operations;

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
