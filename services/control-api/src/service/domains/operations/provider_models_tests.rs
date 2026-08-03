use super::*;

#[test]
fn conflict_requires_an_active_created_exact_prefix_tie_at_the_latest_time() {
    let older = OffsetDateTime::UNIX_EPOCH + time::Duration::seconds(100);
    let latest = OffsetDateTime::UNIX_EPOCH + time::Duration::seconds(200);
    let future = OffsetDateTime::UNIX_EPOCH + time::Duration::seconds(300);
    let active_tracks = vec!["gpt-".to_owned()];
    let mut candidates = vec![
        candidate("gpt-older", Some(older), true),
        candidate("gpt-current", Some(latest), true),
        candidate("gpt-missing-created", None, true),
        candidate("gpt-inactive", Some(latest), false),
        candidate("GPT-case-mismatch", Some(latest), true),
        candidate("claude-other-track", Some(latest), true),
    ];

    assert!(!latest_track_has_conflict(
        true,
        Some("gpt-"),
        &active_tracks,
        &candidates
    ));
    assert!(!latest_track_has_conflict(
        false,
        Some("gpt-"),
        &active_tracks,
        &candidates
    ));
    assert!(!latest_track_has_conflict(
        true,
        None,
        &active_tracks,
        &candidates
    ));

    candidates.push(candidate("gpt-second", Some(latest), true));
    assert!(latest_track_has_conflict(
        true,
        Some("gpt-"),
        &active_tracks,
        &candidates
    ));

    candidates.push(candidate("gpt-future", Some(future), true));
    assert!(!latest_track_has_conflict(
        true,
        Some("gpt-"),
        &active_tracks,
        &candidates
    ));
    candidates.push(candidate("gpt-future-2", Some(future), true));
    assert!(latest_track_has_conflict(
        true,
        Some("gpt-"),
        &active_tracks,
        &candidates
    ));
}

#[test]
fn conflict_projection_assigns_overlapping_models_to_the_longest_track() {
    let latest = OffsetDateTime::UNIX_EPOCH + time::Duration::seconds(200);
    let active_tracks = vec!["gpt-".to_owned(), "gpt-4-".to_owned(), "gpt-4-".to_owned()];
    let candidates = vec![
        candidate("gpt-general", Some(latest), true),
        candidate("gpt-4-a", Some(latest), true),
        candidate("gpt-4-b", Some(latest), true),
        candidate("GPT-4-c", Some(latest), true),
    ];

    assert_eq!(
        longest_matching_track("gpt-4-a", &active_tracks),
        Some("gpt-4-")
    );
    assert!(!latest_track_has_conflict(
        true,
        Some("gpt-"),
        &active_tracks,
        &candidates
    ));
    assert!(latest_track_has_conflict(
        true,
        Some("gpt-4-"),
        &active_tracks,
        &candidates
    ));
    assert_eq!(longest_matching_track("GPT-4-c", &active_tracks), None);
}

fn candidate(
    model_id: &str,
    created_at: Option<OffsetDateTime>,
    active: bool,
) -> RelayModelCandidate {
    RelayModelCandidate {
        model_id: model_id.to_owned(),
        created_at,
        active,
    }
}
