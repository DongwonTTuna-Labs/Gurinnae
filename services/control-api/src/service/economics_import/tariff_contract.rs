use super::*;

#[path = "tariff_contract/contract.rs"]
mod contract;
#[path = "tariff_contract/tariff.rs"]
mod tariff;

pub(super) use contract::EconomicsContractImportV1;
pub(super) use tariff::EconomicsTariffImportV1;
