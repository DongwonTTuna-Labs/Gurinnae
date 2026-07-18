use std::collections::{BTreeMap, BTreeSet};

use rust_decimal::Decimal;
use serde_json::{Map, Value};
use time::{Date, Month};

use crate::engine::{
    Evaluation, EvaluationError, blocked, decimal, finish, integer, missing, string,
    unique_contracts,
};

type ContractGroupKey = (String, String, String);
type ContractGroup<'a> = Vec<&'a Map<String, Value>>;

pub fn evaluate(input: &Value) -> Result<Value, EvaluationError> {
    if ["contracts", "window_days"]
        .iter()
        .any(|path| missing(input, path))
    {
        return blocked("REQUIRED_FIELD_MISSING", input);
    }
    let contracts = unique_contracts(&input["contracts"])?;
    if has_missing_fields(&contracts) {
        return blocked("REQUIRED_FIELD_MISSING", input);
    }
    let window_days = integer(&input["window_days"])?;
    let groups = candidate_groups(&contracts)?;
    let (matched, greatest_total) = matching_ids(groups, window_days)?;
    let matched_set: BTreeSet<_> = matched.iter().cloned().collect();
    let excluded = contracts
        .iter()
        .filter_map(|contract| contract["id"].as_str())
        .filter(|id| !matched_set.contains(*id))
        .map(ToOwned::to_owned)
        .collect();
    let mut metrics = Map::new();
    metrics.insert(
        "matched_contract_count".to_owned(),
        (matched_set.len() as u64).into(),
    );
    metrics.insert(
        "matched_total_amount".to_owned(),
        greatest_total.to_string().into(),
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

fn has_missing_fields(contracts: &[&Map<String, Value>]) -> bool {
    let required = [
        "agency_id",
        "supplier_id",
        "category",
        "signed_at",
        "amount",
        "method",
    ];
    contracts.iter().any(|contract| {
        required
            .iter()
            .any(|field| contract.get(*field).is_none_or(Value::is_null))
    })
}

fn candidate_groups<'a>(
    contracts: &'a [&'a Map<String, Value>],
) -> Result<BTreeMap<ContractGroupKey, ContractGroup<'a>>, EvaluationError> {
    let mut groups: BTreeMap<ContractGroupKey, ContractGroup<'a>> = BTreeMap::new();
    for contract in contracts {
        if string(&contract["method"])? == "SINGLE_SOURCE" {
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
    Ok(groups)
}

fn matching_ids(
    mut groups: BTreeMap<ContractGroupKey, ContractGroup<'_>>,
    window_days: i64,
) -> Result<(Vec<String>, Decimal), EvaluationError> {
    let mut matched = Vec::new();
    let mut greatest_total = Decimal::ZERO;
    for group in groups.values_mut() {
        group.sort_by_key(|contract| {
            contract["signed_at"]
                .as_str()
                .unwrap_or_default()
                .to_owned()
        });
        let first = parse_date(string(&group[0]["signed_at"])?)?;
        let last = parse_date(string(&group[group.len() - 1]["signed_at"])?)?;
        let dates: BTreeSet<_> = group
            .iter()
            .filter_map(|contract| contract["signed_at"].as_str())
            .collect();
        let total: Decimal = group
            .iter()
            .map(|contract| decimal(&contract["amount"]))
            .collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .sum();
        if group.len() >= 4
            && dates.len() >= 3
            && i64::from(last.to_julian_day() - first.to_julian_day()) <= window_days
            && total >= Decimal::from(50_000_000)
        {
            matched.extend(
                group
                    .iter()
                    .map(|contract| string(&contract["id"]).map(ToOwned::to_owned))
                    .collect::<Result<Vec<_>, _>>()?,
            );
            greatest_total = greatest_total.max(total);
        }
    }
    Ok((matched, greatest_total))
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
