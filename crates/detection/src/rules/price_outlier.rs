use std::collections::BTreeSet;

use rust_decimal::Decimal;
use serde_json::{Map, Value};
use time::{Date, Month};

use crate::engine::{
    Evaluation, EvaluationError, blocked, bool_value, decimal, decimal_text, finish, missing,
    quantized, string,
};

type ComparableClassification = (Vec<String>, Vec<String>, Vec<Decimal>);

pub fn evaluate(input: &Value) -> Result<Value, EvaluationError> {
    if missing_fields(input) {
        return blocked("REQUIRED_FIELD_MISSING", input);
    }
    let target = input
        .get("target")
        .and_then(Value::as_object)
        .ok_or(EvaluationError::InvalidScalar)?;
    if target["vat_included"].is_null() {
        return blocked("TARGET_VAT_UNKNOWN", input);
    }
    let target_info = target_info(target)?;
    if !target_info.bundle_known {
        return blocked("TARGET_BUNDLE_UNKNOWN", input);
    }
    let target_date = target_info.observed_at;
    let comparables = input["comparables"]
        .as_array()
        .ok_or(EvaluationError::InvalidScalar)?;
    let (included, excluded, mut values) = classify_comparables(target, target_date, comparables)?;
    if values.len() < 8 {
        return blocked("INSUFFICIENT_COMPARABLES", input);
    }
    values.sort();
    let median = median(&values);
    let target_price = decimal(target_info.unit_price)?;
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

struct TargetInfo<'a> {
    unit_price: &'a Value,
    bundle_known: bool,
    observed_at: Date,
}

fn missing_fields(input: &Value) -> bool {
    [
        "target.id",
        "target.unit_price",
        "target.unit",
        "target.category",
        "target.vat_included",
        "target.bundle_known",
        "target.observed_at",
        "comparables",
    ]
    .iter()
    .any(|path| missing(input, path))
}

fn target_info(target: &Map<String, Value>) -> Result<TargetInfo<'_>, EvaluationError> {
    Ok(TargetInfo {
        unit_price: &target["unit_price"],
        bundle_known: bool_value(&target["bundle_known"])?,
        observed_at: parse_date(string(&target["observed_at"])?)?,
    })
}

fn classify_comparables(
    target: &Map<String, Value>,
    target_date: Date,
    comparables: &[Value],
) -> Result<ComparableClassification, EvaluationError> {
    let mut seen: BTreeSet<String> = BTreeSet::new();
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
        let compatible = compatible(target, target_date, object, &mut seen, source_key)?;
        if compatible {
            included.push(id.to_owned());
            values.push(decimal(&object["unit_price"])?);
        } else {
            excluded.push(id.to_owned());
        }
    }
    Ok((included, excluded, values))
}

fn compatible(
    target: &Map<String, Value>,
    target_date: Date,
    object: &Map<String, Value>,
    seen: &mut BTreeSet<String>,
    source_key: &str,
) -> Result<bool, EvaluationError> {
    let fields = [
        "unit_price",
        "unit",
        "category",
        "vat_included",
        "bundle_known",
        "observed_at",
    ];
    if !seen.insert(source_key.to_owned())
        || fields
            .iter()
            .any(|field| object.get(*field).is_none_or(Value::is_null))
    {
        return Ok(false);
    }
    if object["unit"] != target["unit"]
        || object["category"] != target["category"]
        || object["vat_included"] != target["vat_included"]
        || !bool_value(&object["bundle_known"])?
    {
        return Ok(false);
    }
    let observed = parse_date(string(&object["observed_at"])?)?;
    Ok((target_date.to_julian_day() - observed.to_julian_day()).abs() <= 365)
}

fn median(values: &[Decimal]) -> Decimal {
    let middle = values.len() / 2;
    if values.len().is_multiple_of(2) {
        (values[middle - 1] + values[middle]) / Decimal::from(2)
    } else {
        values[middle]
    }
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
