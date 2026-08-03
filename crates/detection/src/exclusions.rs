use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum ExclusionReason {
    Cancelled,
    IncompatibleUnit,
    DifferentCategory,
    OutsideWindow,
    MissingRequiredField,
    DuplicateObservation,
    AmbiguousIdentity,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ExcludedRecord {
    pub id: String,
    pub reason: ExclusionReason,
}
