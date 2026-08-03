use super::*;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum EconomicsSourceResolutionV1 {
    Append,
    Existing,
}

#[path = "qualification_cost/cost.rs"]
mod cost;
#[path = "qualification_cost/qualification.rs"]
mod qualification;

#[cfg(test)]
#[path = "qualification_cost/tests.rs"]
mod tests;

pub(super) use cost::EconomicsCostCloseImportV1;
pub(super) use qualification::EconomicsQualificationImportV1;
