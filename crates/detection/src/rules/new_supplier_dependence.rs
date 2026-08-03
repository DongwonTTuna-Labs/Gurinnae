use rust_decimal::Decimal;
use serde_json::{Map, Value};

use crate::engine::{
    Evaluation, EvaluationError, blocked, bool_value, decimal, decimal_text, finish, integer,
    missing, quantized, string,
};

pub fn evaluate(input: &Value) -> Result<Value, EvaluationError> {
    let required = [
        "supplier.id",
        "supplier.age_days",
        "supplier.agency_contract_count",
        "supplier.agency_spend",
        "supplier.total_public_spend",
        "supplier.identity_verified",
    ];
    if required.iter().any(|path| missing(input, path)) {
        return blocked("REQUIRED_FIELD_MISSING", input);
    }
    let supplier = input
        .get("supplier")
        .ok_or(EvaluationError::InvalidScalar)?;
    if !bool_value(&supplier["identity_verified"])? {
        return blocked("IDENTITY_AMBIGUOUS", input);
    }
    let total = decimal(&supplier["total_public_spend"])?;
    if total <= Decimal::ZERO {
        return blocked("TOTAL_SPEND_ZERO", input);
    }
    let agency_spend = decimal(&supplier["agency_spend"])?;
    let age = integer(&supplier["age_days"])?;
    let count = integer(&supplier["agency_contract_count"])?;
    let share = agency_spend / total;
    let signal = age <= 365
        && count >= 3
        && agency_spend >= Decimal::from(50_000_000)
        && share >= Decimal::new(5, 1);
    let id = string(&supplier["id"])?;
    let mut metrics = Map::new();
    metrics.insert("supplier_age_days".to_owned(), age.into());
    metrics.insert("agency_contract_count".to_owned(), count.into());
    metrics.insert(
        "agency_spend".to_owned(),
        decimal_text(&supplier["agency_spend"])?.into(),
    );
    metrics.insert(
        "total_public_spend".to_owned(),
        decimal_text(&supplier["total_public_spend"])?.into(),
    );
    metrics.insert("agency_share".to_owned(), quantized(share).into());
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
