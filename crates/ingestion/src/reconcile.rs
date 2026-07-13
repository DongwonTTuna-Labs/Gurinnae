use std::collections::BTreeSet;

pub struct ReconciliationResult {
    pub inserted: Vec<String>,
    pub unchanged: Vec<String>,
    pub removed: Vec<String>,
}

pub fn reconcile(previous: &BTreeSet<String>, observed: &BTreeSet<String>) -> ReconciliationResult {
    ReconciliationResult {
        inserted: observed.difference(previous).cloned().collect(),
        unchanged: observed.intersection(previous).cloned().collect(),
        removed: previous.difference(observed).cloned().collect(),
    }
}
