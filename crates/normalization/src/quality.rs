use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum QualityFlag {
    MissingRequiredField,
    UnknownUnit,
    UnknownVatTreatment,
    AmbiguousIdentity,
    InvalidDate,
    DuplicateObservation,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct QualityReport {
    pub flags: Vec<QualityFlag>,
}

impl QualityReport {
    pub fn add(&mut self, flag: QualityFlag) {
        if !self.flags.contains(&flag) {
            self.flags.push(flag);
        }
    }

    pub fn publishable(&self) -> bool {
        self.flags.is_empty()
    }
}
