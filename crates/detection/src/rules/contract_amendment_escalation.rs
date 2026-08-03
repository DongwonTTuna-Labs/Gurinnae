use rust_decimal::Decimal;
use serde_json::{Map, Value};

use crate::engine::{
    Evaluation, EvaluationError, blocked, bool_value, decimal, decimal_text, finish, integer,
    missing, quantized, string,
};

pub fn evaluate(input: &Value) -> Result<Value, EvaluationError> {
    let required = [
        "contract.id",
        "contract.original_amount",
        "contract.final_amount",
        "contract.amendment_count",
        "contract.scope_change_explained",
    ];
    if required.iter().any(|path| missing(input, path)) {
        return blocked("REQUIRED_FIELD_MISSING", input);
    }
    let contract = input
        .get("contract")
        .ok_or(EvaluationError::InvalidScalar)?;
    let original = decimal(&contract["original_amount"])?;
    if original <= Decimal::ZERO {
        return blocked("ORIGINAL_AMOUNT_ZERO", input);
    }
    let final_amount = decimal(&contract["final_amount"])?;
    let amendment_count = integer(&contract["amendment_count"])?;
    let explained = bool_value(&contract["scope_change_explained"])?;
    let ratio = final_amount / original;
    let signal = original >= Decimal::from(10_000_000)
        && amendment_count >= 2
        && ratio >= Decimal::new(15, 1)
        && !explained;
    let id = string(&contract["id"])?;
    let mut metrics = Map::new();
    metrics.insert(
        "original_amount".to_owned(),
        decimal_text(&contract["original_amount"])?.into(),
    );
    metrics.insert(
        "final_amount".to_owned(),
        decimal_text(&contract["final_amount"])?.into(),
    );
    metrics.insert("ratio".to_owned(), quantized(ratio).into());
    metrics.insert("amendment_count".to_owned(), amendment_count.into());
    metrics.insert("scope_change_explained".to_owned(), explained.into());
    finish(
        Evaluation {
            outcome: if signal { "SIGNAL" } else { "NO_SIGNAL" },
            blockers: Vec::new(),
            metrics,
            included_ids: if signal {
                vec![id.to_owned()]
            } else {
                Vec::new()
            },
            excluded_ids: if signal {
                Vec::new()
            } else {
                vec![id.to_owned()]
            },
        },
        input,
    )
}
