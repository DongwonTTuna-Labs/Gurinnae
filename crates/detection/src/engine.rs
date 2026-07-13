use std::collections::BTreeSet;

use rust_decimal::{Decimal, RoundingStrategy};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::rules;

#[derive(Debug, Error)]
pub enum EvaluationError {
    #[error("unknown detection rule")]
    UnknownRule,
    #[error("rule input has an invalid scalar")]
    InvalidScalar,
    #[error("rule output serialization failed")]
    Serialization,
}

pub fn evaluate(rule_id: &str, input: &Value) -> Result<Value, EvaluationError> {
    match rule_id {
        "PRICE_OUTLIER" => rules::price_outlier::evaluate(input),
        "CONTRACT_SPLITTING_PATTERN" => rules::contract_splitting_pattern::evaluate(input),
        "REPEATED_SINGLE_SOURCE" => rules::repeated_single_source::evaluate(input),
        "SUPPLIER_CONCENTRATION" => rules::supplier_concentration::evaluate(input),
        "LOW_BID_COMPETITION" => rules::low_bid_competition::evaluate(input),
        "CONTRACT_AMENDMENT_ESCALATION" => rules::contract_amendment_escalation::evaluate(input),
        "YEAR_END_SPENDING_SPIKE" => rules::year_end_spending_spike::evaluate(input),
        "NEW_SUPPLIER_DEPENDENCE" => rules::new_supplier_dependence::evaluate(input),
        "SHARED_SUPPLIER_IDENTITY" => rules::shared_supplier_identity::evaluate(input),
        "RESTRICTIVE_SPECIFICATION" => rules::restrictive_specification::evaluate(input),
        _ => Err(EvaluationError::UnknownRule),
    }
}

pub(crate) fn blocked(code: &str, input: &Value) -> Result<Value, EvaluationError> {
    finish(
        Evaluation {
            outcome: "BLOCKED",
            blockers: vec![code.to_owned()],
            metrics: Map::new(),
            included_ids: Vec::new(),
            excluded_ids: Vec::new(),
        },
        input,
    )
}

pub(crate) struct Evaluation {
    pub outcome: &'static str,
    pub blockers: Vec<String>,
    pub metrics: Map<String, Value>,
    pub included_ids: Vec<String>,
    pub excluded_ids: Vec<String>,
}

pub(crate) fn finish(evaluation: Evaluation, input: &Value) -> Result<Value, EvaluationError> {
    let mut included = evaluation.included_ids;
    included.sort();
    let mut excluded = evaluation.excluded_ids;
    excluded.sort();
    let mut result = json!({
        "outcome": evaluation.outcome,
        "blockers": evaluation.blockers,
        "metrics": evaluation.metrics,
        "included_ids": included,
        "excluded_ids": excluded,
    });
    let object = result
        .as_object_mut()
        .ok_or(EvaluationError::Serialization)?;
    object.insert(
        "input_hash".to_owned(),
        Value::String(canonical_hash(input)?),
    );
    let result_hash = canonical_hash(&result)?;
    result
        .as_object_mut()
        .ok_or(EvaluationError::Serialization)?
        .insert("result_hash".to_owned(), Value::String(result_hash));
    Ok(result)
}

pub(crate) fn canonical_hash(value: &Value) -> Result<String, EvaluationError> {
    let bytes = serde_json::to_vec(value).map_err(|_| EvaluationError::Serialization)?;
    Ok(Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

pub(crate) fn missing(input: &Value, path: &str) -> bool {
    let mut current = input;
    for segment in path.split('.') {
        match current.get(segment) {
            Some(value) if !value.is_null() => current = value,
            _ => return true,
        }
    }
    false
}

pub(crate) fn decimal(value: &Value) -> Result<Decimal, EvaluationError> {
    let text = match value {
        Value::String(text) => text.clone(),
        Value::Number(number) => number.to_string(),
        _ => return Err(EvaluationError::InvalidScalar),
    };
    text.parse().map_err(|_| EvaluationError::InvalidScalar)
}

pub(crate) fn decimal_text(value: &Value) -> Result<String, EvaluationError> {
    match value {
        Value::String(text) => Ok(text.clone()),
        Value::Number(number) => Ok(number.to_string()),
        _ => Err(EvaluationError::InvalidScalar),
    }
}

pub(crate) fn quantized(value: Decimal) -> String {
    let rounded = value.round_dp_with_strategy(4, RoundingStrategy::MidpointAwayFromZero);
    format!("{rounded:.4}")
}

pub(crate) fn integer(value: &Value) -> Result<i64, EvaluationError> {
    value.as_i64().ok_or(EvaluationError::InvalidScalar)
}

pub(crate) fn string(value: &Value) -> Result<&str, EvaluationError> {
    value.as_str().ok_or(EvaluationError::InvalidScalar)
}

pub(crate) fn bool_value(value: &Value) -> Result<bool, EvaluationError> {
    value.as_bool().ok_or(EvaluationError::InvalidScalar)
}

pub(crate) fn unique_contracts(input: &Value) -> Result<Vec<&Map<String, Value>>, EvaluationError> {
    let contracts = input.as_array().ok_or(EvaluationError::InvalidScalar)?;
    let mut seen = BTreeSet::new();
    let mut output = Vec::new();
    for contract in contracts {
        let object = contract.as_object().ok_or(EvaluationError::InvalidScalar)?;
        let Some(id) = object.get("id").and_then(Value::as_str) else {
            continue;
        };
        if seen.insert(id) {
            output.push(object);
        }
    }
    Ok(output)
}
