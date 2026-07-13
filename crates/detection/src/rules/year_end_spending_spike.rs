use rust_decimal::Decimal;
use serde_json::{Map, Value};

use crate::engine::{
    Evaluation, EvaluationError, blocked, decimal, decimal_text, finish, integer, missing,
    quantized,
};

pub fn evaluate(input: &Value) -> Result<Value, EvaluationError> {
    if ["monthly_spend", "monthly_contract_count"]
        .iter()
        .any(|path| missing(input, path))
    {
        return blocked("REQUIRED_FIELD_MISSING", input);
    }
    let spend_values = input["monthly_spend"]
        .as_array()
        .ok_or(EvaluationError::InvalidScalar)?;
    let count_values = input["monthly_contract_count"]
        .as_array()
        .ok_or(EvaluationError::InvalidScalar)?;
    if spend_values.len() != 12 || count_values.len() != 12 {
        return blocked("INCOMPLETE_YEAR", input);
    }
    let spends = spend_values
        .iter()
        .map(decimal)
        .collect::<Result<Vec<_>, _>>()?;
    let counts = count_values
        .iter()
        .map(integer)
        .collect::<Result<Vec<_>, _>>()?;
    let total_count: i64 = counts.iter().sum();
    if total_count < 10 {
        return blocked("INSUFFICIENT_CONTRACTS", input);
    }
    let annual: Decimal = spends.iter().sum();
    let prior = median(&spends[..11]);
    let december = spends[11];
    if annual <= Decimal::ZERO || prior <= Decimal::ZERO {
        return blocked("INCOMPLETE_YEAR", input);
    }
    let share = december / annual;
    let ratio = december / prior;
    let signal = share >= Decimal::new(25, 2) && ratio >= Decimal::from(3);
    let mut metrics = Map::new();
    metrics.insert("annual_spend".to_owned(), annual.to_string().into());
    metrics.insert(
        "december_spend".to_owned(),
        decimal_text(&spend_values[11])?.into(),
    );
    metrics.insert("december_share".to_owned(), quantized(share).into());
    metrics.insert("prior_month_median".to_owned(), quantized(prior).into());
    metrics.insert(
        "december_to_prior_median".to_owned(),
        quantized(ratio).into(),
    );
    metrics.insert("annual_contract_count".to_owned(), total_count.into());
    finish(
        Evaluation {
            outcome: if signal { "SIGNAL" } else { "NO_SIGNAL" },
            blockers: Vec::new(),
            metrics,
            included_ids: if signal {
                vec!["month-12".to_owned()]
            } else {
                Vec::new()
            },
            excluded_ids: if signal {
                Vec::new()
            } else {
                vec!["month-12".to_owned()]
            },
        },
        input,
    )
}

fn median(values: &[Decimal]) -> Decimal {
    let mut sorted = values.to_vec();
    sorted.sort();
    let middle = sorted.len() / 2;
    if sorted.len().is_multiple_of(2) {
        (sorted[middle - 1] + sorted[middle]) / Decimal::from(2)
    } else {
        sorted[middle]
    }
}
