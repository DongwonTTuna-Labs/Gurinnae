use rust_decimal::Decimal;
use time::Date;

use crate::exclusions::{ExcludedRecord, ExclusionReason};

pub struct CohortRecord<'a> {
    pub id: &'a str,
    pub category: &'a str,
    pub unit: &'a str,
    pub signed_on: Date,
    pub unit_price: Option<Decimal>,
    pub cancelled: bool,
}

pub struct CohortSelection<'a> {
    pub included: Vec<&'a CohortRecord<'a>>,
    pub excluded: Vec<ExcludedRecord>,
}

pub fn select<'a>(
    records: &'a [CohortRecord<'a>],
    category: &str,
    unit: &str,
    starts_on: Date,
    ends_on: Date,
) -> CohortSelection<'a> {
    let mut included = Vec::new();
    let mut excluded = Vec::new();
    for record in records {
        let reason = if record.cancelled {
            Some(ExclusionReason::Cancelled)
        } else if record.category != category {
            Some(ExclusionReason::DifferentCategory)
        } else if record.unit != unit {
            Some(ExclusionReason::IncompatibleUnit)
        } else if record.signed_on < starts_on || record.signed_on > ends_on {
            Some(ExclusionReason::OutsideWindow)
        } else if record.unit_price.is_none() {
            Some(ExclusionReason::MissingRequiredField)
        } else {
            None
        };
        if let Some(reason) = reason {
            excluded.push(ExcludedRecord {
                id: record.id.to_owned(),
                reason,
            });
        } else {
            included.push(record);
        }
    }
    CohortSelection { included, excluded }
}
