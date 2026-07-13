use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};

use crate::error::DomainError;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Money {
    amount: Decimal,
    currency: String,
}

impl Money {
    pub fn new(amount: Decimal, currency: &str) -> Result<Self, DomainError> {
        if amount.scale() > 4 || amount < Decimal::ZERO {
            return Err(DomainError::InvalidAmount);
        }
        if currency.len() != 3 || !currency.bytes().all(|byte| byte.is_ascii_uppercase()) {
            return Err(DomainError::InvalidCurrency);
        }
        Ok(Self {
            amount,
            currency: currency.to_owned(),
        })
    }

    pub const fn amount(&self) -> Decimal {
        self.amount
    }

    pub fn currency(&self) -> &str {
        &self.currency
    }

    pub fn checked_add(&self, other: &Self) -> Result<Self, DomainError> {
        if self.currency != other.currency {
            return Err(DomainError::InvalidCurrency);
        }
        self.amount
            .checked_add(other.amount)
            .ok_or(DomainError::InvalidAmount)
            .and_then(|amount| Self::new(amount, &self.currency))
    }
}
