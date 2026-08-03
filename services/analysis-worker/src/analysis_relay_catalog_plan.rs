use std::collections::{BTreeMap, BTreeSet};

use serde_json::Value;
use time::OffsetDateTime;

use super::RelayCatalogModel;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct RelayCatalogStoredRow {
    pub(super) model_id: String,
    pub(super) first_seen_at: OffsetDateTime,
    pub(super) last_seen_at: OffsetDateTime,
    pub(super) raw: Value,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) enum RelayCatalogLifecycleMutation {
    Seen {
        model: RelayCatalogModel,
        first_seen_at: OffsetDateTime,
        last_seen_at: OffsetDateTime,
    },
    Missing(RelayCatalogStoredRow),
}

pub(super) fn relay_catalog_lifecycle_plan(
    existing: &[RelayCatalogStoredRow],
    models: &[RelayCatalogModel],
    observed_at: OffsetDateTime,
) -> Vec<RelayCatalogLifecycleMutation> {
    let existing_by_id = existing
        .iter()
        .map(|row| (row.model_id.as_str(), row))
        .collect::<BTreeMap<_, _>>();
    let incoming_ids = models
        .iter()
        .map(|model| model.model_id.as_str())
        .collect::<BTreeSet<_>>();
    let mut plan = models
        .iter()
        .map(|model| RelayCatalogLifecycleMutation::Seen {
            model: model.clone(),
            first_seen_at: existing_by_id
                .get(model.model_id.as_str())
                .map_or(observed_at, |row| row.first_seen_at),
            last_seen_at: observed_at,
        })
        .collect::<Vec<_>>();
    plan.extend(
        existing
            .iter()
            .filter(|row| !incoming_ids.contains(row.model_id.as_str()))
            .cloned()
            .map(RelayCatalogLifecycleMutation::Missing),
    );
    plan
}
