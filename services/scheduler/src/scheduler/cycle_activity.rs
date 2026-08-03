use uuid::Uuid;

pub(super) struct CycleActivity {
    pub(super) recovered: u64,
    pub(super) source_runs: u64,
    pub(super) delivery_polls: u64,
    pub(super) snapshot_builds: u64,
    pub(super) entity_retention_jobs: u64,
    pub(super) person_retention_jobs: u64,
    pub(super) donation_charge_jobs: u64,
    pub(super) catalog_syncs: u64,
    pub(super) publication_expiry: Option<Uuid>,
    pub(super) dispatched: u64,
    pub(super) consumed: bool,
}

impl CycleActivity {
    pub(super) fn is_idle(&self) -> bool {
        self.recovered == 0
            && self.source_runs == 0
            && self.delivery_polls == 0
            && self.snapshot_builds == 0
            && self.entity_retention_jobs == 0
            && self.person_retention_jobs == 0
            && self.donation_charge_jobs == 0
            && self.catalog_syncs == 0
            && self.publication_expiry.is_none()
            && self.dispatched == 0
            && !self.consumed
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn idle_cycle() -> CycleActivity {
        CycleActivity {
            recovered: 0,
            source_runs: 0,
            delivery_polls: 0,
            snapshot_builds: 0,
            entity_retention_jobs: 0,
            person_retention_jobs: 0,
            donation_charge_jobs: 0,
            catalog_syncs: 0,
            publication_expiry: None,
            dispatched: 0,
            consumed: false,
        }
    }

    #[test]
    fn donation_enqueue_activity_keeps_once_mode_running() {
        let mut activity = idle_cycle();
        assert!(activity.is_idle());

        activity.donation_charge_jobs = 1;
        assert!(!activity.is_idle());
    }
}
