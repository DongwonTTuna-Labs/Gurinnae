use rust_decimal::Decimal;
use thiserror::Error;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Distribution {
    pub count: usize,
    pub minimum: Decimal,
    pub median: Decimal,
    pub maximum: Decimal,
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum CalculationError {
    #[error("calculation requires at least one value")]
    EmptyCohort,
    #[error("calculation overflowed")]
    Overflow,
}

pub fn distribution(values: &[Decimal]) -> Result<Distribution, CalculationError> {
    let mut sorted = values.to_vec();
    sorted.sort();
    let minimum = sorted
        .first()
        .copied()
        .ok_or(CalculationError::EmptyCohort)?;
    let maximum = sorted
        .last()
        .copied()
        .ok_or(CalculationError::EmptyCohort)?;
    let middle = sorted.len() / 2;
    let median = if sorted.len().is_multiple_of(2) {
        sorted[middle - 1]
            .checked_add(sorted[middle])
            .and_then(|value| value.checked_div(Decimal::from(2)))
            .ok_or(CalculationError::Overflow)?
    } else {
        sorted[middle]
    };
    Ok(Distribution {
        count: sorted.len(),
        minimum,
        median,
        maximum,
    })
}

pub fn relative_difference(value: Decimal, baseline: Decimal) -> Result<Decimal, CalculationError> {
    value
        .checked_sub(baseline)
        .and_then(|difference| difference.checked_div(baseline))
        .ok_or(CalculationError::Overflow)
}
