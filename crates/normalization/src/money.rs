use gurine_domain::{error::DomainError, money::Money};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum VatTreatment {
    Included,
    Excluded,
    Exempt,
    Unknown,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct NormalizedMoney {
    pub gross: Money,
    pub net: Option<Money>,
    pub vat: Option<Money>,
    pub treatment: VatTreatment,
}

#[derive(Debug, Error)]
pub enum MoneyNormalizationError {
    #[error("raw monetary value is invalid")]
    InvalidRawValue,
    #[error(transparent)]
    Domain(#[from] DomainError),
}

pub fn normalize_krw(
    raw: &str,
    treatment: VatTreatment,
) -> Result<NormalizedMoney, MoneyNormalizationError> {
    let cleaned = raw.trim().replace([',', '₩', '원', ' '], "");
    let gross_amount = cleaned
        .parse::<Decimal>()
        .map_err(|_| MoneyNormalizationError::InvalidRawValue)?;
    let gross = Money::new(gross_amount, "KRW")?;
    let (net, vat) = match treatment {
        VatTreatment::Included => {
            let divisor = Decimal::new(11, 1);
            let net_amount = gross_amount
                .checked_div(divisor)
                .ok_or(MoneyNormalizationError::InvalidRawValue)?
                .round();
            (
                Some(Money::new(net_amount, "KRW")?),
                Some(Money::new(gross_amount - net_amount, "KRW")?),
            )
        }
        VatTreatment::Excluded => {
            let vat_amount = gross_amount
                .checked_mul(Decimal::new(1, 1))
                .ok_or(MoneyNormalizationError::InvalidRawValue)?
                .round();
            (Some(gross.clone()), Some(Money::new(vat_amount, "KRW")?))
        }
        VatTreatment::Exempt => (Some(gross.clone()), Some(Money::new(Decimal::ZERO, "KRW")?)),
        VatTreatment::Unknown => (None, None),
    };
    Ok(NormalizedMoney {
        gross,
        net,
        vat,
        treatment,
    })
}
