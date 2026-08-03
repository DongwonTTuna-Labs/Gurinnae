use std::collections::BTreeSet;

use rust_decimal::Decimal;
use serde_json::{Map, Value, json};

use crate::engine::{
    Evaluation, EvaluationError, blocked, decimal, finish, missing, string, unique_contracts,
};

pub fn evaluate(input: &Value) -> Result<Value, EvaluationError> {
    if ["suppliers", "contracts"]
        .iter()
        .any(|path| missing(input, path))
    {
        return blocked("REQUIRED_FIELD_MISSING", input);
    }
    let suppliers = input["suppliers"]
        .as_array()
        .ok_or(EvaluationError::InvalidScalar)?;
    let contracts = unique_contracts(&input["contracts"])?;
    if suppliers.len() < 2 || contracts.len() < 3 {
        return blocked("INSUFFICIENT_CONTRACT_CONTEXT", input);
    }
    if suppliers.iter().any(|supplier| {
        supplier["strong_identifier_hashes"]
            .as_array()
            .is_none_or(Vec::is_empty)
    }) {
        return blocked("IDENTITY_HASH_MISSING", input);
    }
    for (index, first) in suppliers.iter().enumerate() {
        for second in suppliers.iter().skip(index + 1) {
            if let Some(signal) = evaluate_pair(first, second, &contracts)? {
                let relevant_set: BTreeSet<_> = signal.included_ids.iter().cloned().collect();
                let excluded = contracts
                    .iter()
                    .filter_map(|contract| contract["id"].as_str())
                    .filter(|id| !relevant_set.contains(*id))
                    .map(ToOwned::to_owned)
                    .collect();
                return finish(
                    Evaluation {
                        outcome: "SIGNAL",
                        blockers: Vec::new(),
                        metrics: signal.metrics,
                        included_ids: signal.included_ids,
                        excluded_ids: excluded,
                    },
                    input,
                );
            }
        }
    }
    let mut metrics = Map::new();
    metrics.insert("shared_identifier_count".to_owned(), 0.into());
    metrics.insert("combined_contract_count".to_owned(), 0.into());
    metrics.insert("combined_amount".to_owned(), "0".into());
    finish(
        Evaluation {
            outcome: "NO_SIGNAL",
            blockers: Vec::new(),
            metrics,
            included_ids: Vec::new(),
            excluded_ids: contracts
                .iter()
                .filter_map(|contract| contract["id"].as_str().map(ToOwned::to_owned))
                .collect(),
        },
        input,
    )
}

struct PairSignal {
    included_ids: Vec<String>,
    metrics: Map<String, Value>,
}

fn evaluate_pair(
    first: &Value,
    second: &Value,
    contracts: &[&Map<String, Value>],
) -> Result<Option<PairSignal>, EvaluationError> {
    let first_id = string(&first["id"])?;
    let second_id = string(&second["id"])?;
    let shared = hashes(&first["strong_identifier_hashes"])?
        .intersection(&hashes(&second["strong_identifier_hashes"])?)
        .count();
    let relevant = contracts.iter().filter(|contract| matches!(contract["supplier_id"].as_str(), Some(id) if id == first_id || id == second_id)).copied().collect::<Vec<_>>();
    let agencies = relevant
        .iter()
        .map(|contract| contract.get("agency_id").and_then(Value::as_str))
        .collect::<BTreeSet<_>>();
    let total: Decimal = relevant
        .iter()
        .map(|contract| {
            contract
                .get("amount")
                .map(decimal)
                .transpose()
                .map(|value| value.unwrap_or_default())
        })
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .sum();
    if shared < 2 || relevant.len() < 3 || agencies.len() != 1 || total < Decimal::from(50_000_000)
    {
        return Ok(None);
    }
    let included_ids = relevant
        .iter()
        .filter_map(|contract| contract["id"].as_str().map(ToOwned::to_owned))
        .collect::<Vec<_>>();
    let mut metrics = Map::new();
    metrics.insert("supplier_ids".to_owned(), json!([first_id, second_id]));
    metrics.insert("shared_identifier_count".to_owned(), (shared as u64).into());
    metrics.insert(
        "combined_contract_count".to_owned(),
        (relevant.len() as u64).into(),
    );
    metrics.insert("combined_amount".to_owned(), total.to_string().into());
    Ok(Some(PairSignal {
        included_ids,
        metrics,
    }))
}

fn hashes(value: &Value) -> Result<BTreeSet<&str>, EvaluationError> {
    value
        .as_array()
        .ok_or(EvaluationError::InvalidScalar)?
        .iter()
        .map(string)
        .collect()
}
