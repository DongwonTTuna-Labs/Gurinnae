use serde_json::{Map, Value};

use crate::engine::{
    Evaluation, EvaluationError, blocked, bool_value, finish, integer, missing, string,
};

pub fn evaluate(input: &Value) -> Result<Value, EvaluationError> {
    let required = [
        "specification.id",
        "specification.brand_mentions",
        "specification.model_mentions",
        "specification.equivalent_allowed",
        "specification.valid_bidder_count",
        "specification.justification_present",
    ];
    if required.iter().any(|path| missing(input, path)) {
        return blocked("REQUIRED_FIELD_MISSING", input);
    }
    let specification = input
        .get("specification")
        .ok_or(EvaluationError::InvalidScalar)?;
    let brands = integer(&specification["brand_mentions"])?;
    let models = integer(&specification["model_mentions"])?;
    let equivalent = bool_value(&specification["equivalent_allowed"])?;
    let bidders = integer(&specification["valid_bidder_count"])?;
    let justified = bool_value(&specification["justification_present"])?;
    let signal = brands + models >= 1 && !equivalent && bidders <= 1 && !justified;
    let id = string(&specification["id"])?;
    let mut metrics = Map::new();
    metrics.insert("brand_mentions".to_owned(), brands.into());
    metrics.insert("model_mentions".to_owned(), models.into());
    metrics.insert("equivalent_allowed".to_owned(), equivalent.into());
    metrics.insert("valid_bidder_count".to_owned(), bidders.into());
    metrics.insert("justification_present".to_owned(), justified.into());
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
