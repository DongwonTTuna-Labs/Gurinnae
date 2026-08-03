use rust_decimal::Decimal;
use serde_json::{Map, Value};

use crate::engine::{
    Evaluation, EvaluationError, blocked, bool_value, decimal, decimal_text, finish, integer,
    missing, string,
};

pub fn evaluate(input: &Value) -> Result<Value, EvaluationError> {
    let required = [
        "procurement.id",
        "procurement.method",
        "procurement.valid_bidder_count",
        "procurement.estimated_amount",
        "procurement.emergency",
    ];
    if required.iter().any(|path| missing(input, path)) {
        return blocked("REQUIRED_FIELD_MISSING", input);
    }
    let procurement = input
        .get("procurement")
        .ok_or(EvaluationError::InvalidScalar)?;
    let id = string(&procurement["id"])?;
    let method = string(&procurement["method"])?;
    let bidder_count = integer(&procurement["valid_bidder_count"])?;
    let amount = decimal(&procurement["estimated_amount"])?;
    let emergency = bool_value(&procurement["emergency"])?;
    let competitive = matches!(method, "OPEN_COMPETITION" | "LIMITED_COMPETITION");
    let signal =
        competitive && bidder_count <= 1 && amount >= Decimal::from(50_000_000) && !emergency;
    let mut metrics = Map::new();
    metrics.insert("valid_bidder_count".to_owned(), bidder_count.into());
    metrics.insert(
        "estimated_amount".to_owned(),
        decimal_text(&procurement["estimated_amount"])?.into(),
    );
    metrics.insert("competitive".to_owned(), competitive.into());
    metrics.insert("emergency".to_owned(), emergency.into());
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
