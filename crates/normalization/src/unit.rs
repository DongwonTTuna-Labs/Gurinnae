use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum Unit {
    Each,
    Kilogram,
    Meter,
    Liter,
    Hour,
    Service,
    Unknown(String),
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum UnitError {
    #[error("unit is empty")]
    Empty,
}

pub fn normalize(value: &str) -> Result<Unit, UnitError> {
    let normalized = value.trim().to_ascii_uppercase();
    if normalized.is_empty() {
        return Err(UnitError::Empty);
    }
    Ok(match normalized.as_str() {
        "EA" | "EACH" | "개" => Unit::Each,
        "KG" | "KILOGRAM" | "킬로그램" => Unit::Kilogram,
        "M" | "METER" | "미터" => Unit::Meter,
        "L" | "LITER" | "리터" => Unit::Liter,
        "H" | "HR" | "HOUR" | "시간" => Unit::Hour,
        "SERVICE" | "용역" | "식" => Unit::Service,
        _ => Unit::Unknown(normalized),
    })
}
