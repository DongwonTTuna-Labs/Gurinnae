use gurine_payment_providers::{KrwAmount, ProviderKind};
use serde::Serialize;
use uuid::Uuid;

use crate::{
    digest::Sha256Digest,
    payment::model::{DonationCadence, DonationIntentRequest, PaymentRuntimeError},
};

pub const FIXTURE_AUTHORITY: &str = "TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY";
const OFFER_ID: Uuid = Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_06e1);

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FixtureTier {
    pub tier_id: Uuid,
    pub amount_whole_krw: i64,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FixtureDonationOffer {
    pub schema_version: &'static str,
    pub authority: &'static str,
    pub offer_version_id: Uuid,
    pub offer_digest: Sha256Digest,
    pub currency: &'static str,
    pub tiers: Vec<FixtureTier>,
    pub cadences: [DonationCadence; 2],
    pub providers: [ProviderKind; 3],
    pub production_readiness_effect: &'static str,
}

impl FixtureDonationOffer {
    pub fn test_fixture() -> Self {
        let tiers = vec![
            FixtureTier {
                tier_id: Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_06e2),
                amount_whole_krw: 1_000,
            },
            FixtureTier {
                tier_id: Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_06e3),
                amount_whole_krw: 5_000,
            },
            FixtureTier {
                tier_id: Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_06e4),
                amount_whole_krw: 10_000,
            },
        ];
        let offer_digest = fixture_digest(&tiers);
        Self {
            schema_version: "donation-offer-fixture.v1",
            authority: FIXTURE_AUTHORITY,
            offer_version_id: OFFER_ID,
            offer_digest,
            currency: "KRW",
            tiers,
            cadences: [DonationCadence::OneTime, DonationCadence::Recurring],
            providers: [
                ProviderKind::TossPayments,
                ProviderKind::KakaoPay,
                ProviderKind::Stripe,
            ],
            production_readiness_effect: "NONE",
        }
    }

    pub fn resolve(
        &self,
        request: &DonationIntentRequest,
    ) -> Result<KrwAmount, PaymentRuntimeError> {
        if request.schema_version != super::model::DONATION_INTENT_REQUEST_SCHEMA
            || request.offer_version_id != self.offer_version_id
            || request.offer_digest != self.offer_digest
            || !self.cadences.contains(&request.cadence)
            || !self.providers.contains(&request.provider)
        {
            return Err(PaymentRuntimeError::InvalidRequest);
        }
        let amount = self
            .tiers
            .iter()
            .find(|tier| tier.tier_id == request.tier_id)
            .map(|tier| tier.amount_whole_krw)
            .ok_or(PaymentRuntimeError::InvalidRequest)?;
        KrwAmount::try_new(amount).map_err(Into::into)
    }
}

fn fixture_digest(tiers: &[FixtureTier]) -> Sha256Digest {
    let mut canonical =
        format!("gurine-donation-offer-fixture.v1\n{FIXTURE_AUTHORITY}\n{OFFER_ID}\nKRW");
    for tier in tiers {
        canonical.push('\n');
        canonical.push_str(&tier.tier_id.to_string());
        canonical.push(':');
        canonical.push_str(&tier.amount_whole_krw.to_string());
    }
    canonical.push_str("\nONE_TIME,RECURRING\nTOSS_PAYMENTS,KAKAO_PAY,STRIPE\nNONE");
    Sha256Digest::of(canonical.as_bytes())
}
