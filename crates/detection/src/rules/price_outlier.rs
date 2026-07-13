use std::collections::BTreeSet;

use rust_decimal::Decimal;
use serde_json::{Map, Value};
use time::{Date, Month};

use crate::engine::{
    Evaluation, EvaluationError, blocked, bool_value, decimal, decimal_text, finish, missing,
    quantized, string,
};

pub fn evaluate(input: &Value) -> Result<Value, EvaluationError> {
    let required = [
        "target.id",
        "target.unit_price",
        "target.unit",
        "target.category",
        "target.vat_included",
        "target.bundle_known",
        "target.observed_at",
        "comparables",
    ];
    if required.iter().any(|path| missing(input, path)) {
        return blocked("REQUIRED_FIELD_MISSING", input);
    }
    let target = input.get("target").ok_or(EvaluationError::InvalidScalar)?;
    if !bool_value(&target["bundle_known"])? {
        return blocked("TARGET_BUNDLE_UNKNOWN", input);
    }
    if target["vat_included"].is_null() {
        return blocked("TARGET_VAT_UNKNOWN", input);
    }
    let target_date = parse_date(string(&target["observed_at"])?)?;
    let comparables = input["comparables"]
        .as_array()
        .ok_or(EvaluationError::InvalidScalar)?;
    let mut seen = BTreeSet::new();
    let mut included = Vec::new();
    let mut excluded = Vec::new();
    let mut values = Vec::new();
    for comparable in comparables {
        let object = comparable
            .as_object()
            .ok_or(EvaluationError::InvalidScalar)?;
        let id = object
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or("UNKNOWN");
        let source_key = object
            .get("source_key")
            .and_then(Value::as_str)
            .unwrap_or(id);
        let required_fields = [
            "unit_price",
            "unit",
            "category",
            "vat_included",
            "bundle_known",
            "observed_at",
        ];
        let mut compatible = seen.insert(source_key)
            && required_fields
                .iter()
                .all(|field| object.get(*field).is_some_and(|value| !value.is_null()));
        if compatible {
            compatible = object["unit"] == target["unit"]
                && object["category"] == target["category"]
                && object["vat_included"] == target["vat_included"]
                && bool_value(&object["bundle_known"])?;
        }
        if compatible {
            let observed = parse_date(string(&object["observed_at"])?)?;
            compatible = (target_date.to_julian_day() - observed.to_julian_day()).abs() <= 365;
        }
        if compatible {
            included.push(id.to_owned());
            values.push(decimal(&object["unit_price"])?);
        } else {
            excluded.push(id.to_owned());
        }
    }
    if values.len() < 8 {
        return blocked("INSUFFICIENT_COMPARABLES", input);
    }
    values.sort();
    let middle = values.len() / 2;
    let median = if values.len() % 2 == 0 {
        (values[middle - 1] + values[middle]) / Decimal::from(2)
    } else {
        values[middle]
    };
    let target_price = decimal(&target["unit_price"])?;
    let ratio = target_price / median;
    let mut metrics = Map::new();
    metrics.insert(
        "target_unit_price".to_owned(),
        decimal_text(&target["unit_price"])?.into(),
    );
    metrics.insert("median_unit_price".to_owned(), quantized(median).into());
    metrics.insert("ratio".to_owned(), quantized(ratio).into());
    metrics.insert("comparable_count".to_owned(), (values.len() as u64).into());
    finish(
        Evaluation {
            outcome: if ratio >= Decimal::from(3) {
                "SIGNAL"
            } else {
                "NO_SIGNAL"
            },
            blockers: Vec::new(),
            metrics,
            included_ids: included,
            excluded_ids: excluded,
        },
        input,
    )
}

fn parse_date(value: &str) -> Result<Date, EvaluationError> {
    let mut parts = value.split('-');
    let year = parts
        .next()
        .and_then(|part| part.parse::<i32>().ok())
        .ok_or(EvaluationError::InvalidScalar)?;
    let month = parts
        .next()
        .and_then(|part| part.parse::<u8>().ok())
        .ok_or(EvaluationError::InvalidScalar)?;
    let day = parts
        .next()
        .and_then(|part| part.parse::<u8>().ok())
        .ok_or(EvaluationError::InvalidScalar)?;
    if parts.next().is_some() {
        return Err(EvaluationError::InvalidScalar);
    }
    let month = Month::try_from(month).map_err(|_| EvaluationError::InvalidScalar)?;
    Date::from_calendar_date(year, month, day).map_err(|_| EvaluationError::InvalidScalar)
}
