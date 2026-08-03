use std::collections::{BTreeMap, BTreeSet};

use uuid::Uuid;

use crate::{
    IdempotencyKey, KrwAmount, MerchantOrderId, PaymentLocator, PaymentState,
    PaymentTransportError, ProviderKind, ProviderOperation, ProviderPaymentId,
};

use super::wire::{self, FixtureCommand, FixturePayment, FixturePaymentLookup};

pub(super) struct FixtureExecution {
    provider: ProviderKind,
    operation: ProviderOperation,
    request_sha256: String,
    command: FixtureCommand,
    configured_state: PaymentState,
    observed_at_unix: i64,
}

impl FixtureExecution {
    pub(super) fn new(
        provider: ProviderKind,
        operation: ProviderOperation,
        request_sha256: String,
        command: FixtureCommand,
        configured_state: PaymentState,
        observed_at_unix: i64,
    ) -> Self {
        Self {
            provider,
            operation,
            request_sha256,
            command,
            configured_state,
            observed_at_unix,
        }
    }
}

struct MutationContext {
    provider: ProviderKind,
    operation: ProviderOperation,
    idempotency_key: IdempotencyKey,
    request_sha256: String,
}

struct ChargeInput {
    mutation: MutationContext,
    credential_sha256: String,
    merchant_order_id: MerchantOrderId,
    amount: KrwAmount,
    state: PaymentState,
    observed_at_unix: i64,
}

struct RefundInput {
    mutation: MutationContext,
    provider_payment_id: ProviderPaymentId,
    amount: KrwAmount,
}

#[derive(Default)]
pub(super) struct FixtureLedger {
    mutations: BTreeMap<String, String>,
    issued_credentials: BTreeSet<String>,
    payments: BTreeMap<String, FixturePayment>,
    payment_by_order: BTreeMap<String, String>,
}

impl FixtureLedger {
    pub(super) fn execute(
        &mut self,
        execution: FixtureExecution,
    ) -> Result<Vec<u8>, PaymentTransportError> {
        let FixtureExecution {
            provider,
            operation,
            request_sha256,
            command,
            configured_state,
            observed_at_unix,
        } = execution;
        match command {
            FixtureCommand::Issue {
                binding_id,
                idempotency_key,
            } => self.issue(
                binding_id,
                MutationContext {
                    provider,
                    operation,
                    idempotency_key,
                    request_sha256,
                },
            ),
            FixtureCommand::Charge {
                idempotency_key,
                credential_sha256,
                merchant_order_id,
                amount,
            } => self.charge(ChargeInput {
                mutation: MutationContext {
                    provider,
                    operation,
                    idempotency_key,
                    request_sha256,
                },
                credential_sha256,
                merchant_order_id,
                amount,
                state: configured_state,
                observed_at_unix,
            }),
            FixtureCommand::Refund {
                idempotency_key,
                provider_payment_id,
                amount,
            } => self.refund(RefundInput {
                mutation: MutationContext {
                    provider,
                    operation,
                    idempotency_key,
                    request_sha256,
                },
                provider_payment_id,
                amount,
            }),
            FixtureCommand::Fetch { lookup } => self.fetch(provider, lookup),
        }
    }

    fn issue(
        &mut self,
        binding_id: Uuid,
        mutation: MutationContext,
    ) -> Result<Vec<u8>, PaymentTransportError> {
        let provider = mutation.provider;
        let idempotency_key = mutation.idempotency_key;
        self.claim_mutation(mutation)?;
        self.issued_credentials
            .insert(wire::issued_credential_sha256(
                provider,
                binding_id,
                idempotency_key,
            )?);
        wire::issue_response(provider, binding_id, idempotency_key)
    }

    fn charge(&mut self, input: ChargeInput) -> Result<Vec<u8>, PaymentTransportError> {
        if !self.issued_credentials.contains(&input.credential_sha256) {
            return Err(PaymentTransportError::FixtureMismatch);
        }
        let payment = wire::payment(
            input.mutation.provider,
            input.mutation.idempotency_key,
            input.merchant_order_id,
            input.amount,
            input.state,
            input.observed_at_unix,
        )?;
        self.validate_order_binding(&payment)?;
        let replay = self.claim_mutation(input.mutation)?;
        if !replay {
            self.payment_by_order.insert(
                payment.merchant_order_id.as_str().to_owned(),
                payment.provider_payment_id.as_str().to_owned(),
            );
            self.payments.insert(
                payment.provider_payment_id.as_str().to_owned(),
                payment.clone(),
            );
        }
        wire::charge_response(&payment)
    }

    fn refund(&mut self, input: RefundInput) -> Result<Vec<u8>, PaymentTransportError> {
        let provider = input.mutation.provider;
        let payment_key = input.provider_payment_id.as_str().to_owned();
        let payment = self
            .payments
            .get(&payment_key)
            .ok_or(PaymentTransportError::FixtureMismatch)?;
        wire::validate_refund(payment, provider, input.amount)?;
        let replay = self.claim_mutation(input.mutation)?;
        if !replay {
            let payment = self
                .payments
                .get_mut(&payment_key)
                .ok_or(PaymentTransportError::FixtureMismatch)?;
            wire::apply_refund(payment, input.amount)?;
        }
        wire::refund_response(provider, &input.provider_payment_id)
    }

    fn fetch(
        &self,
        provider: ProviderKind,
        lookup: FixturePaymentLookup,
    ) -> Result<Vec<u8>, PaymentTransportError> {
        let payment = match lookup {
            FixturePaymentLookup::ProviderPaymentId(value) => self.payments.get(value.as_str()),
            FixturePaymentLookup::MerchantOrderId(value) => self
                .payment_by_order
                .get(value.as_str())
                .and_then(|payment_id| self.payments.get(payment_id)),
        }
        .ok_or(PaymentTransportError::FixtureMismatch)?;
        if payment.provider != provider {
            return Err(PaymentTransportError::FixtureMismatch);
        }
        wire::fetch_response(payment)
    }

    pub(super) fn payment_for_locator(
        &self,
        provider: ProviderKind,
        locator: &PaymentLocator,
    ) -> Result<&FixturePayment, PaymentTransportError> {
        let payment = match locator {
            PaymentLocator::ProviderPaymentId(value) => self.payments.get(value.as_str()),
            PaymentLocator::MerchantOrderId(value) => self
                .payment_by_order
                .get(value.as_str())
                .and_then(|payment_id| self.payments.get(payment_id)),
        }
        .ok_or(PaymentTransportError::FixtureMismatch)?;
        if payment.provider == provider {
            Ok(payment)
        } else {
            Err(PaymentTransportError::FixtureMismatch)
        }
    }

    fn claim_mutation(&mut self, mutation: MutationContext) -> Result<bool, PaymentTransportError> {
        let identity = mutation_identity(
            mutation.provider,
            mutation.operation,
            mutation.idempotency_key,
        );
        match self.mutations.get(&identity) {
            Some(existing) if existing == &mutation.request_sha256 => Ok(true),
            Some(_) => Err(PaymentTransportError::FixtureMismatch),
            None => {
                self.mutations.insert(identity, mutation.request_sha256);
                Ok(false)
            }
        }
    }

    fn validate_order_binding(
        &self,
        payment: &FixturePayment,
    ) -> Result<(), PaymentTransportError> {
        match self
            .payment_by_order
            .get(payment.merchant_order_id.as_str())
        {
            Some(existing) if existing != payment.provider_payment_id.as_str() => {
                Err(PaymentTransportError::FixtureMismatch)
            }
            _ => Ok(()),
        }
    }
}

fn mutation_identity(
    provider: ProviderKind,
    operation: ProviderOperation,
    idempotency_key: IdempotencyKey,
) -> String {
    format!(
        "{}\0{}\0{}",
        provider.as_str(),
        operation_name(operation),
        idempotency_key.as_provider_value()
    )
}

const fn operation_name(operation: ProviderOperation) -> &'static str {
    match operation {
        ProviderOperation::IssueBillingKey => "ISSUE_BILLING_KEY",
        ProviderOperation::Charge => "CHARGE",
        ProviderOperation::Refund => "REFUND",
        ProviderOperation::FetchPayment => "FETCH_PAYMENT",
    }
}
