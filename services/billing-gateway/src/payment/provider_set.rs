use std::sync::Arc;

use gurine_payment_providers::{
    BillingAuthorization, DeterministicFixtureProviderFactory, IdempotencyKey, PaymentProvider,
    ProviderKind, ScheduleOwnership,
};
use uuid::Uuid;

use super::model::PaymentRuntimeError;

pub struct ProviderSet {
    factory: DeterministicFixtureProviderFactory,
    entries: Vec<ProviderEntry>,
}

struct ProviderEntry {
    provider_kind: ProviderKind,
    provider: Arc<dyn PaymentProvider>,
}

impl ProviderSet {
    pub fn test_fixture(
        factory: DeterministicFixtureProviderFactory,
    ) -> Result<Self, PaymentRuntimeError> {
        let mut entries = Vec::with_capacity(3);
        for expected in required_providers() {
            let provider = factory.provider(expected)?;
            validate_provider(expected, provider.as_ref())?;
            entries.push(ProviderEntry {
                provider_kind: expected,
                provider,
            });
        }
        validate_required_providers(&entries)?;
        Ok(Self { factory, entries })
    }

    pub(super) fn get(
        &self,
        provider: ProviderKind,
    ) -> Result<&Arc<dyn PaymentProvider>, PaymentRuntimeError> {
        self.entries
            .iter()
            .find(|entry| entry.provider_kind == provider)
            .map(|entry| &entry.provider)
            .ok_or(PaymentRuntimeError::Unavailable)
    }

    pub(super) fn issue_authorization(
        &self,
        provider: ProviderKind,
        binding_id: Uuid,
        idempotency_key: IdempotencyKey,
    ) -> Result<BillingAuthorization, PaymentRuntimeError> {
        self.factory
            .issue_authorization(provider, binding_id, idempotency_key)
            .map_err(Into::into)
    }

    pub(super) fn webhook_verifier(
        &self,
        provider: ProviderKind,
    ) -> Result<&Arc<dyn PaymentProvider>, PaymentRuntimeError> {
        self.get(provider)
    }
}

fn validate_provider(
    expected: ProviderKind,
    provider: &dyn PaymentProvider,
) -> Result<(), PaymentRuntimeError> {
    let capabilities = provider.capabilities();
    if capabilities.provider != expected
        || capabilities.schedule_ownership != ScheduleOwnership::MerchantScheduled
        || capabilities.webhook_is_payment_truth
        || !capabilities.authenticated_fetch_is_payment_truth
    {
        Err(PaymentRuntimeError::InvalidRequest)
    } else {
        Ok(())
    }
}

fn validate_required_providers(entries: &[ProviderEntry]) -> Result<(), PaymentRuntimeError> {
    let valid = entries.len() == required_providers().len()
        && required_providers().iter().all(|provider| {
            entries
                .iter()
                .filter(|entry| entry.provider_kind == *provider)
                .count()
                == 1
        });
    if valid {
        Ok(())
    } else {
        Err(PaymentRuntimeError::InvalidRequest)
    }
}

const fn required_providers() -> [ProviderKind; 3] {
    [
        ProviderKind::TossPayments,
        ProviderKind::KakaoPay,
        ProviderKind::Stripe,
    ]
}
