use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum DependencyStatus {
    Ready,
    Degraded,
    Unavailable,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ReadinessReport {
    pub service: String,
    pub dependencies: BTreeMap<String, DependencyStatus>,
}

impl ReadinessReport {
    pub fn ready(&self) -> bool {
        self.dependencies
            .values()
            .all(|status| *status == DependencyStatus::Ready)
    }
}
