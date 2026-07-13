use std::collections::{BTreeMap, BTreeSet};

use rust_decimal::Decimal;
use serde_json::{Map, Value};
use time::{Date, Month};

use crate::engine::{
    Evaluation, EvaluationError, blocked, bool_value, decimal, decimal_text, finish, integer,
    missing, string, unique_contracts,
};

type ContractGroupKey = (String, String, String);
type ContractGroup<'a> = Vec<&'a Map<String, Value>>;

pub fn evaluate(input: &Value) -> Result<Value, EvaluationError> {
    if ["contracts", "single_source_threshold", "window_days"]
        .iter()
        .any(|path| missing(input, path))
    {
        return blocked("REQUIRED_FIELD_MISSING", input);
    }
    let contracts = unique_contracts(&input["contracts"])?;
    let required = [
        "agency_id",
        "supplier_id",
        "category",
        "signed_at",
        "amount",
        "method",
    ];
    if contracts.iter().any(|contract| {
        required
            .iter()
            .any(|field| contract.get(*field).is_none_or(Value::is_null))
    }) {
        return blocked("REQUIRED_FIELD_MISSING", input);
    }
    let threshold = decimal(&input["single_source_threshold"])?;
    let window_days = integer(&input["window_days"])?;
    let mut groups: BTreeMap<ContractGroupKey, ContractGroup<'_>> = BTreeMap::new();
    for contract in &contracts {
        let legitimate = contract
            .get("legitimate_phase")
            .map(bool_value)
            .transpose()?
            .unwrap_or(false);
        if string(&contract["method"])? == "SINGLE_SOURCE"
            && decimal(&contract["amount"])? < threshold
            && !legitimate
        {
            groups
                .entry((
                    string(&contract["agency_id"])?.to_owned(),
                    string(&contract["supplier_id"])?.to_owned(),
                    string(&contract["category"])?.to_owned(),
                ))
                .or_default()
                .push(contract);
        }
    }
    let mut matched = Vec::new();
    for group in groups.values_mut() {
        group.sort_by_key(|contract| {
            contract["signed_at"]
                .as_str()
                .unwrap_or_default()
                .to_owned()
        });
        let first = parse_date(string(&group[0]["signed_at"])?)?;
        let last = parse_date(string(&group[group.len() - 1]["signed_at"])?)?;
        let total: Decimal = group
            .iter()
            .map(|contract| decimal(&contract["amount"]))
            .collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .sum();
        if group.len() >= 3
            && i64::from(last.to_julian_day() - first.to_julian_day()) <= window_days
            && total >= threshold
        {
            matched.extend(
                group
                    .iter()
                    .map(|contract| string(&contract["id"]).map(ToOwned::to_owned))
                    .collect::<Result<Vec<_>, _>>()?,
            );
        }
    }
    let matched_set: BTreeSet<_> = matched.iter().cloned().collect();
    let excluded = contracts
        .iter()
        .map(|contract| string(&contract["id"]))
        .filter_map(|result| {
            result
                .ok()
                .filter(|id| !matched_set.contains(*id))
                .map(ToOwned::to_owned)
        })
        .collect();
    let mut metrics = Map::new();
    metrics.insert(
        "matched_contract_count".to_owned(),
        (matched_set.len() as u64).into(),
    );
    metrics.insert(
        "threshold".to_owned(),
        decimal_text(&input["single_source_threshold"])?.into(),
    );
    finish(
        Evaluation {
            outcome: if matched.is_empty() {
                "NO_SIGNAL"
            } else {
                "SIGNAL"
            },
            blockers: Vec::new(),
            metrics,
            included_ids: matched,
            excluded_ids: excluded,
        },
        input,
    )
}

fn parse_date(value: &str) -> Result<Date, EvaluationError> {
    let parts = value.split('-').collect::<Vec<_>>();
    if parts.len() != 3 {
        return Err(EvaluationError::InvalidScalar);
    }
    let year = parts[0]
        .parse()
        .map_err(|_| EvaluationError::InvalidScalar)?;
    let month = Month::try_from(
        parts[1]
            .parse::<u8>()
            .map_err(|_| EvaluationError::InvalidScalar)?,
    )
    .map_err(|_| EvaluationError::InvalidScalar)?;
    let day = parts[2]
        .parse()
        .map_err(|_| EvaluationError::InvalidScalar)?;
    Date::from_calendar_date(year, month, day).map_err(|_| EvaluationError::InvalidScalar)
}
