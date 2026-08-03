#[cfg(test)]
use super::*;

fn model(id: &str, created: Option<i64>) -> RelayCatalogModel {
    RelayCatalogModel {
        model_id: id.to_owned(),
        family: relay_family_and_track(id).0,
        track: relay_family_and_track(id).1,
        created_at: created.and_then(|value| OffsetDateTime::from_unix_timestamp(value).ok()),
        raw: json!({"id":id,"object":"model","created":created}),
    }
}

#[test]
fn catalog_parser_is_unique_and_created_is_nullable() {
    let parsed = parse_relay_model_list(&json!({
        "object":"list",
        "data":[
            {"id":"gpt-new","object":"model","created":200,"owned_by":"relay"},
            {"id":"claude-current","object":"model","created":null}
        ]
    }))
    .expect("valid model list");
    assert_eq!(parsed[0].created_at, None);
    assert!(parsed[0].raw["created"].is_null());
    assert_eq!(parsed[1].track.as_deref(), Some("gpt-"));
    assert!(parse_relay_model_list(&json!({
        "object":"list",
        "data":[
            {"id":"gpt-same","object":"model"},
            {"id":"gpt-same","object":"model"}
        ]
    }))
    .is_err());
}

#[test]
fn newest_selection_is_unique_case_sensitive_and_excludes_missing_created() {
    let rows = vec![
        model("gpt-old", Some(100)),
        model("gpt-new", Some(200)),
        model("gpt-undated", None),
        model("GPT-newer", Some(300)),
    ];
    let active_tracks = vec!["gpt-".to_owned()];
    assert_eq!(
        newest_relay_model(&rows, "gpt-", &active_tracks, Some("gpt-old")),
        RelayNewestCandidate::Unique("gpt-new".to_owned())
    );
}

#[test]
fn newest_created_tie_never_auto_selects() {
    let rows = vec![model("gpt-a", Some(200)), model("gpt-b", Some(200))];
    let active_tracks = vec!["gpt-".to_owned()];
    assert_eq!(
        newest_relay_model(&rows, "gpt-", &active_tracks, Some("gpt-old")),
        RelayNewestCandidate::CreatedAtTie
    );
}

#[test]
fn overlapping_tracks_assign_each_model_to_the_longest_case_sensitive_prefix() {
    let rows = vec![
        model("gpt-general", Some(100)),
        model("gpt-4-old", Some(200)),
        model("gpt-4-new", Some(300)),
        model("GPT-4-newer", Some(400)),
    ];
    let active_tracks = vec![
        "gpt-".to_owned(),
        "gpt-4-".to_owned(),
        "gpt-4-".to_owned(),
    ];

    assert_eq!(
        longest_matching_track("gpt-4-new", &active_tracks),
        Some("gpt-4-")
    );
    assert_eq!(
        newest_relay_model(&rows, "gpt-", &active_tracks, None),
        RelayNewestCandidate::Unique("gpt-general".to_owned())
    );
    assert_eq!(
        newest_relay_model(&rows, "gpt-4-", &active_tracks, Some("gpt-4-old")),
        RelayNewestCandidate::Unique("gpt-4-new".to_owned())
    );
    assert_eq!(longest_matching_track("GPT-4-newer", &active_tracks), None);
}

#[test]
fn lifecycle_plan_preserves_first_seen_refreshes_seen_and_deactivates_missing() {
    let first_seen = OffsetDateTime::from_unix_timestamp(100).expect("first seen");
    let prior_seen = OffsetDateTime::from_unix_timestamp(150).expect("prior seen");
    let observed = OffsetDateTime::from_unix_timestamp(200).expect("observed");
    let existing = vec![
        RelayCatalogStoredRow {
            model_id: "gpt-seen".to_owned(),
            first_seen_at: first_seen,
            last_seen_at: prior_seen,
            raw: json!({"id":"gpt-seen","object":"model","created":1}),
        },
        RelayCatalogStoredRow {
            model_id: "gpt-missing".to_owned(),
            first_seen_at: first_seen,
            last_seen_at: prior_seen,
            raw: json!({"id":"gpt-missing","object":"model","created":1}),
        },
    ];
    let plan = relay_catalog_lifecycle_plan(
        &existing,
        &[model("gpt-seen", Some(2)), model("gpt-new", Some(3))],
        observed,
    );
    assert!(plan.contains(&RelayCatalogLifecycleMutation::Seen {
        model: model("gpt-seen", Some(2)),
        first_seen_at: first_seen,
        last_seen_at: observed,
    }));
    assert!(plan.contains(&RelayCatalogLifecycleMutation::Seen {
        model: model("gpt-new", Some(3)),
        first_seen_at: observed,
        last_seen_at: observed,
    }));
    assert!(plan.contains(&RelayCatalogLifecycleMutation::Missing(
        existing[1].clone()
    )));
}

#[test]
fn auto_upgrade_gate_enqueues_without_authoritative_auto_failure() {
    let now = OffsetDateTime::from_unix_timestamp(10_000).expect("test timestamp");
    assert_eq!(relay_auto_upgrade_gate(None, now), RelayAutoUpgradeGate::Enqueue);
    assert_eq!(
        relay_auto_upgrade_gate(
            Some(RelayAutoUpgradePriorAttempt {
                attempt_kind: RelayUpgradeAttemptKind::Auto,
                status: "FAILED",
                cooldown_until: Some(now - time::Duration::seconds(1)),
            }),
            now,
        ),
        RelayAutoUpgradeGate::Enqueue
    );
}

#[test]
fn same_target_auto_upgrade_is_suppressed_during_active_or_six_hour_window() {
    let now = OffsetDateTime::from_unix_timestamp(10_000).expect("test timestamp");
    assert_eq!(
        relay_auto_upgrade_gate(
            Some(RelayAutoUpgradePriorAttempt {
                attempt_kind: RelayUpgradeAttemptKind::Auto,
                status: "RUNNING",
                cooldown_until: None,
            }),
            now,
        ),
        RelayAutoUpgradeGate::Suppressed
    );
    assert_eq!(
        relay_auto_upgrade_gate(
            Some(RelayAutoUpgradePriorAttempt {
                attempt_kind: RelayUpgradeAttemptKind::Auto,
                status: "FAILED",
                cooldown_until: Some(now + time::Duration::hours(6)),
            }),
            now,
        ),
        RelayAutoUpgradeGate::Suppressed
    );
}

#[test]
fn manual_attempt_is_not_an_auto_suppression_authority() {
    let now = OffsetDateTime::from_unix_timestamp(10_000).expect("test timestamp");
    assert_eq!(
        relay_auto_upgrade_gate(
            Some(RelayAutoUpgradePriorAttempt {
                attempt_kind: RelayUpgradeAttemptKind::Manual,
                status: "RUNNING",
                cooldown_until: Some(now + time::Duration::hours(6)),
            }),
            now,
        ),
        RelayAutoUpgradeGate::Enqueue
    );
}
