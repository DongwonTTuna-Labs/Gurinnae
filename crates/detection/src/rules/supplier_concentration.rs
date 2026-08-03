use std::collections::BTreeMap;

use rust_decimal::Decimal;
use serde_json::{Map, Value};

use crate::engine::{
    Evaluation, EvaluationError, blocked, decimal, finish, missing, quantized, string,
    unique_contracts,
};

pub fn evaluate(input: &Value) -> Result<Value, EvaluationError> {
    if ["contracts", "minimum_total_spend"]
        .iter()
        .any(|path| missing(input, path))
    {
        return blocked("REQUIRED_FIELD_MISSING", input);
    }
    let contracts = unique_contracts(&input["contracts"])?;
    if contracts.iter().any(|contract| {
        contract.get("supplier_id").is_none_or(Value::is_null)
            || contract.get("amount").is_none_or(Value::is_null)
    }) {
        return blocked("IDENTITY_AMBIGUOUS", input);
    }
    let amounts = contracts
        .iter()
        .map(|contract| decimal(&contract["amount"]))
        .collect::<Result<Vec<_>, _>>()?;
    let total: Decimal = amounts.iter().sum();
    if total < decimal(&input["minimum_total_spend"])? {
        return blocked("INSUFFICIENT_TOTAL_SPEND", input);
    }
    let mut sums: BTreeMap<String, Decimal> = BTreeMap::new();
    let mut counts: BTreeMap<String, u64> = BTreeMap::new();
    let mut order = Vec::new();
    for (contract, amount) in contracts.iter().zip(amounts) {
        let supplier = string(&contract["supplier_id"])?.to_owned();
        if !sums.contains_key(&supplier) {
            order.push(supplier.clone());
        }
        *sums.entry(supplier.clone()).or_default() += amount;
        *counts.entry(supplier).or_default() += 1;
    }
    let mut top_supplier = order.first().ok_or(EvaluationError::InvalidScalar)?.clone();
    for supplier in order.iter().skip(1) {
        if sums[supplier] > sums[&top_supplier] {
            top_supplier = supplier.clone();
        }
    }
    let share = sums[&top_supplier] / total;
    let count = counts[&top_supplier];
    let signal = share >= Decimal::new(6, 1) && count >= 3;
    let matched = contracts
        .iter()
        .filter(|contract| contract["supplier_id"].as_str() == Some(&top_supplier))
        .filter_map(|contract| contract["id"].as_str().map(ToOwned::to_owned))
        .collect::<Vec<_>>();
    let excluded = contracts
        .iter()
        .filter(|contract| !signal || contract["supplier_id"].as_str() != Some(&top_supplier))
        .filter_map(|contract| contract["id"].as_str().map(ToOwned::to_owned))
        .collect();
    let mut metrics = Map::new();
    metrics.insert("top_supplier_id".to_owned(), top_supplier.into());
    metrics.insert("top_supplier_share".to_owned(), quantized(share).into());
    metrics.insert("top_supplier_contract_count".to_owned(), count.into());
    metrics.insert("total_spend".to_owned(), total.to_string().into());
    finish(
        Evaluation {
            outcome: if signal { "SIGNAL" } else { "NO_SIGNAL" },
            blockers: Vec::new(),
            metrics,
            included_ids: if signal { matched } else { Vec::new() },
            excluded_ids: excluded,
        },
        input,
    )
}
