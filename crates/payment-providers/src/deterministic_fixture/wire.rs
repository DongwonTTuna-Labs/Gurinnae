use serde::{Deserialize, de::DeserializeOwned};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::{
    BillingAuthorization, IdempotencyKey, KrwAmount, MerchantOrderId, PaymentProviderError,
    PaymentState, PaymentTransportError, ProviderKind, ProviderPaymentId, SecretText,
    TransportRequest,
};

mod response;
mod secret;

pub(super) use response::{charge_response, fetch_response, refund_response};
use secret::SecretWire;

pub(super) enum FixtureCommand {
    Issue {
        binding_id: Uuid,
        idempotency_key: IdempotencyKey,
    },
    Charge {
        idempotency_key: IdempotencyKey,
        credential_sha256: String,
        merchant_order_id: MerchantOrderId,
        amount: KrwAmount,
    },
    Refund {
        idempotency_key: IdempotencyKey,
        provider_payment_id: ProviderPaymentId,
        amount: KrwAmount,
    },
    Fetch {
        lookup: FixturePaymentLookup,
    },
}

pub(super) enum FixturePaymentLookup {
    ProviderPaymentId(ProviderPaymentId),
    MerchantOrderId(MerchantOrderId),
}

#[derive(Clone)]
pub(super) struct FixturePayment {
    pub provider: ProviderKind,
    pub provider_payment_id: ProviderPaymentId,
    pub merchant_order_id: MerchantOrderId,
    pub amount: KrwAmount,
    pub state: PaymentState,
    pub refunded_amount: i64,
    pub observed_at_unix: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TossIssueRequest {
    auth_key: SecretWire,
    customer_key: SecretWire,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct KakaoIssueRequest {
    transaction_id: SecretWire,
    approval_token: SecretWire,
    partner_user_id: SecretWire,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StripeIssueRequest {
    customer_id: SecretWire,
    payment_method_id: SecretWire,
    usage: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TossChargeRequest {
    billing_key: SecretWire,
    customer_key: SecretWire,
    amount: i64,
    currency: String,
    order_id: String,
    merchant_scheduled: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct KakaoChargeRequest {
    subscription_id: SecretWire,
    partner_user_id: SecretWire,
    total_amount: i64,
    currency: String,
    partner_order_id: String,
    merchant_scheduled: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StripeChargeRequest {
    customer_id: SecretWire,
    payment_method_id: SecretWire,
    amount: i64,
    currency: String,
    merchant_order_id: String,
    off_session: bool,
    confirm: bool,
    merchant_scheduled: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TossRefundRequest {
    payment_key: String,
    cancel_amount: i64,
    currency: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct KakaoRefundRequest {
    transaction_id: String,
    cancel_amount: i64,
    currency: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StripeRefundRequest {
    payment_intent_id: String,
    amount: i64,
    currency: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct FetchRequest {
    locator_kind: String,
    locator: String,
}

pub(super) fn parse_request(
    request: &TransportRequest,
) -> Result<FixtureCommand, PaymentTransportError> {
    match request.operation() {
        crate::ProviderOperation::IssueBillingKey => parse_issue(request),
        crate::ProviderOperation::Charge => parse_charge(request),
        crate::ProviderOperation::Refund => parse_refund(request),
        crate::ProviderOperation::FetchPayment => parse_fetch(request),
    }
}

pub(super) fn issue_authorization(
    provider: ProviderKind,
    binding_id: Uuid,
    idempotency_key: IdempotencyKey,
) -> Result<BillingAuthorization, PaymentProviderError> {
    Ok(match provider {
        ProviderKind::TossPayments => BillingAuthorization::TossPayments {
            auth_key: derive_secret("toss-auth", provider, binding_id, idempotency_key)?,
            customer_key: derive_secret("toss-customer", provider, binding_id, idempotency_key)?,
        },
        ProviderKind::KakaoPay => BillingAuthorization::KakaoPay {
            transaction_id: derive_secret(
                "kakao-transaction",
                provider,
                binding_id,
                idempotency_key,
            )?,
            approval_token: derive_secret("kakao-approval", provider, binding_id, idempotency_key)?,
            partner_user_id: derive_secret(
                "kakao-partner-user",
                provider,
                binding_id,
                idempotency_key,
            )?,
        },
        ProviderKind::Stripe => BillingAuthorization::Stripe {
            customer_id: derive_secret("stripe-customer", provider, binding_id, idempotency_key)?,
            payment_method_id: derive_secret(
                "stripe-payment-method",
                provider,
                binding_id,
                idempotency_key,
            )?,
        },
    })
}

pub(super) fn issued_credential_sha256(
    provider: ProviderKind,
    binding_id: Uuid,
    idempotency_key: IdempotencyKey,
) -> Result<String, PaymentTransportError> {
    let material = issued_material(provider, binding_id, idempotency_key)?;
    Ok(credential_sha256(
        provider,
        material.first.expose_for_provider_codec(),
        material.second.expose_for_provider_codec(),
    ))
}

pub(super) fn issue_response(
    provider: ProviderKind,
    binding_id: Uuid,
    idempotency_key: IdempotencyKey,
) -> Result<Vec<u8>, PaymentTransportError> {
    let material = issued_material(provider, binding_id, idempotency_key)?;
    let first = material.first.expose_for_provider_codec();
    let second = material.second.expose_for_provider_codec();
    response::issue_response(provider, first, second)
}

pub(super) fn payment(
    provider: ProviderKind,
    idempotency_key: IdempotencyKey,
    merchant_order_id: MerchantOrderId,
    amount: KrwAmount,
    state: PaymentState,
    observed_at_unix: i64,
) -> Result<FixturePayment, PaymentTransportError> {
    let provider_payment_id =
        expected_provider_payment_id(provider, idempotency_key, &merchant_order_id, amount)?;
    Ok(FixturePayment {
        provider,
        provider_payment_id,
        merchant_order_id,
        amount,
        state,
        refunded_amount: 0,
        observed_at_unix,
    })
}

pub(super) fn expected_provider_payment_id(
    provider: ProviderKind,
    idempotency_key: IdempotencyKey,
    merchant_order_id: &MerchantOrderId,
    amount: KrwAmount,
) -> Result<ProviderPaymentId, PaymentTransportError> {
    let preimage = format!(
        "gurine-deterministic-payment-id.v1\n{}\n{}\n{}\n{}",
        provider.as_str(),
        idempotency_key.as_provider_value(),
        merchant_order_id.as_str(),
        amount.whole_krw()
    );
    let digest = sha256_hex(preimage.as_bytes());
    ProviderPaymentId::try_new(format!(
        "fixture-{}-payment-{}",
        provider_slug(provider),
        &digest[..32]
    ))
    .map_err(|_| PaymentTransportError::FixtureMismatch)
}

pub(super) fn validate_refund(
    payment: &FixturePayment,
    provider: ProviderKind,
    amount: KrwAmount,
) -> Result<(), PaymentTransportError> {
    let remaining = payment
        .amount
        .whole_krw()
        .checked_sub(payment.refunded_amount)
        .ok_or(PaymentTransportError::FixtureMismatch)?;
    if payment.provider != provider
        || !matches!(
            payment.state,
            PaymentState::Succeeded | PaymentState::PartiallyRefunded
        )
        || amount.whole_krw() > remaining
    {
        Err(PaymentTransportError::FixtureMismatch)
    } else {
        Ok(())
    }
}

pub(super) fn apply_refund(
    payment: &mut FixturePayment,
    amount: KrwAmount,
) -> Result<(), PaymentTransportError> {
    payment.refunded_amount = payment
        .refunded_amount
        .checked_add(amount.whole_krw())
        .ok_or(PaymentTransportError::FixtureMismatch)?;
    payment.state = if payment.refunded_amount == payment.amount.whole_krw() {
        PaymentState::Refunded
    } else {
        PaymentState::PartiallyRefunded
    };
    Ok(())
}

fn parse_issue(request: &TransportRequest) -> Result<FixtureCommand, PaymentTransportError> {
    let key = mutation_key(request)?;
    let binding_id = match request.provider() {
        ProviderKind::TossPayments => {
            let wire: TossIssueRequest = decode(request.body_for_egress())?;
            let binding =
                validate_secret(wire.auth_key.expose(), "toss-auth", request.provider(), key)?;
            validate_same_binding(
                binding,
                wire.customer_key.expose(),
                "toss-customer",
                request.provider(),
                key,
            )?;
            binding
        }
        ProviderKind::KakaoPay => {
            let wire: KakaoIssueRequest = decode(request.body_for_egress())?;
            let binding = validate_secret(
                wire.transaction_id.expose(),
                "kakao-transaction",
                request.provider(),
                key,
            )?;
            validate_same_binding(
                binding,
                wire.approval_token.expose(),
                "kakao-approval",
                request.provider(),
                key,
            )?;
            validate_same_binding(
                binding,
                wire.partner_user_id.expose(),
                "kakao-partner-user",
                request.provider(),
                key,
            )?;
            binding
        }
        ProviderKind::Stripe => {
            let wire: StripeIssueRequest = decode(request.body_for_egress())?;
            if wire.usage != "off_session" {
                return Err(PaymentTransportError::FixtureMismatch);
            }
            let binding = validate_secret(
                wire.customer_id.expose(),
                "stripe-customer",
                request.provider(),
                key,
            )?;
            validate_same_binding(
                binding,
                wire.payment_method_id.expose(),
                "stripe-payment-method",
                request.provider(),
                key,
            )?;
            binding
        }
    };
    Ok(FixtureCommand::Issue {
        binding_id,
        idempotency_key: key,
    })
}

fn parse_charge(request: &TransportRequest) -> Result<FixtureCommand, PaymentTransportError> {
    let key = mutation_key(request)?;
    let (first, second, order, amount) = match request.provider() {
        ProviderKind::TossPayments => {
            let wire: TossChargeRequest = decode(request.body_for_egress())?;
            validate_charge_flags(wire.merchant_scheduled, true, &wire.currency)?;
            (
                wire.billing_key,
                wire.customer_key,
                wire.order_id,
                wire.amount,
            )
        }
        ProviderKind::KakaoPay => {
            let wire: KakaoChargeRequest = decode(request.body_for_egress())?;
            validate_charge_flags(wire.merchant_scheduled, true, &wire.currency)?;
            (
                wire.subscription_id,
                wire.partner_user_id,
                wire.partner_order_id,
                wire.total_amount,
            )
        }
        ProviderKind::Stripe => {
            let wire: StripeChargeRequest = decode(request.body_for_egress())?;
            validate_charge_flags(
                wire.merchant_scheduled && wire.off_session,
                wire.confirm,
                &wire.currency,
            )?;
            (
                wire.customer_id,
                wire.payment_method_id,
                wire.merchant_order_id,
                wire.amount,
            )
        }
    };
    Ok(FixtureCommand::Charge {
        idempotency_key: key,
        credential_sha256: credential_sha256(request.provider(), first.expose(), second.expose()),
        merchant_order_id: MerchantOrderId::try_new(order)
            .map_err(|_| PaymentTransportError::FixtureMismatch)?,
        amount: KrwAmount::try_new(amount).map_err(|_| PaymentTransportError::FixtureMismatch)?,
    })
}

fn parse_refund(request: &TransportRequest) -> Result<FixtureCommand, PaymentTransportError> {
    let key = mutation_key(request)?;
    let (payment_id, amount, currency) = match request.provider() {
        ProviderKind::TossPayments => {
            let wire: TossRefundRequest = decode(request.body_for_egress())?;
            (wire.payment_key, wire.cancel_amount, wire.currency)
        }
        ProviderKind::KakaoPay => {
            let wire: KakaoRefundRequest = decode(request.body_for_egress())?;
            (wire.transaction_id, wire.cancel_amount, wire.currency)
        }
        ProviderKind::Stripe => {
            let wire: StripeRefundRequest = decode(request.body_for_egress())?;
            (wire.payment_intent_id, wire.amount, wire.currency)
        }
    };
    validate_currency(&currency)?;
    Ok(FixtureCommand::Refund {
        idempotency_key: key,
        provider_payment_id: ProviderPaymentId::try_new(payment_id)
            .map_err(|_| PaymentTransportError::FixtureMismatch)?,
        amount: KrwAmount::try_new(amount).map_err(|_| PaymentTransportError::FixtureMismatch)?,
    })
}

fn parse_fetch(request: &TransportRequest) -> Result<FixtureCommand, PaymentTransportError> {
    if request.idempotency_key().is_some() {
        return Err(PaymentTransportError::FixtureMismatch);
    }
    let wire: FetchRequest = decode(request.body_for_egress())?;
    let lookup = match (request.provider(), wire.locator_kind.as_str()) {
        (ProviderKind::TossPayments, "PAYMENT_KEY")
        | (ProviderKind::KakaoPay, "TRANSACTION_ID")
        | (ProviderKind::Stripe, "PAYMENT_INTENT_ID") => FixturePaymentLookup::ProviderPaymentId(
            ProviderPaymentId::try_new(wire.locator)
                .map_err(|_| PaymentTransportError::FixtureMismatch)?,
        ),
        (ProviderKind::TossPayments, "ORDER_ID")
        | (ProviderKind::KakaoPay, "PARTNER_ORDER_ID")
        | (ProviderKind::Stripe, "MERCHANT_ORDER_ID") => FixturePaymentLookup::MerchantOrderId(
            MerchantOrderId::try_new(wire.locator)
                .map_err(|_| PaymentTransportError::FixtureMismatch)?,
        ),
        _ => return Err(PaymentTransportError::FixtureMismatch),
    };
    Ok(FixtureCommand::Fetch { lookup })
}

struct IssuedMaterial {
    first: SecretText,
    second: SecretText,
}

fn issued_material(
    provider: ProviderKind,
    binding_id: Uuid,
    key: IdempotencyKey,
) -> Result<IssuedMaterial, PaymentTransportError> {
    let labels = match provider {
        ProviderKind::TossPayments => ("toss-billing", "toss-customer"),
        ProviderKind::KakaoPay => ("kakao-subscription", "kakao-partner-user"),
        ProviderKind::Stripe => ("stripe-customer", "stripe-payment-method"),
    };
    Ok(IssuedMaterial {
        first: derive_secret(labels.0, provider, binding_id, key)
            .map_err(|_| PaymentTransportError::FixtureMismatch)?,
        second: derive_secret(labels.1, provider, binding_id, key)
            .map_err(|_| PaymentTransportError::FixtureMismatch)?,
    })
}

fn derive_secret(
    label: &str,
    provider: ProviderKind,
    binding_id: Uuid,
    key: IdempotencyKey,
) -> Result<SecretText, PaymentProviderError> {
    let preimage = format!(
        "gurine-deterministic-payment-fixture-secret.v1\n{}\n{}\n{}\n{}",
        provider.as_str(),
        label,
        binding_id,
        key.as_provider_value()
    );
    SecretText::try_new(format!(
        "fixture-v1/{label}/{binding_id}/{}",
        sha256_hex(preimage.as_bytes())
    ))
}

fn validate_secret(
    value: &str,
    label: &str,
    provider: ProviderKind,
    key: IdempotencyKey,
) -> Result<Uuid, PaymentTransportError> {
    let prefix = format!("fixture-v1/{label}/");
    let rest = value
        .strip_prefix(&prefix)
        .ok_or(PaymentTransportError::FixtureMismatch)?;
    let (binding, _) = rest
        .split_once('/')
        .ok_or(PaymentTransportError::FixtureMismatch)?;
    let binding = Uuid::parse_str(binding).map_err(|_| PaymentTransportError::FixtureMismatch)?;
    validate_same_binding(binding, value, label, provider, key)?;
    Ok(binding)
}

fn validate_same_binding(
    binding_id: Uuid,
    value: &str,
    label: &str,
    provider: ProviderKind,
    key: IdempotencyKey,
) -> Result<(), PaymentTransportError> {
    let expected = derive_secret(label, provider, binding_id, key)
        .map_err(|_| PaymentTransportError::FixtureMismatch)?;
    if expected.expose_for_provider_codec() == value {
        Ok(())
    } else {
        Err(PaymentTransportError::FixtureMismatch)
    }
}

fn credential_sha256(provider: ProviderKind, first: &str, second: &str) -> String {
    let preimage = format!(
        "gurine-deterministic-payment-credential.v1\n{}\n{}\n{}",
        provider.as_str(),
        first,
        second
    );
    sha256_hex(preimage.as_bytes())
}

fn mutation_key(request: &TransportRequest) -> Result<IdempotencyKey, PaymentTransportError> {
    request
        .idempotency_key()
        .ok_or(PaymentTransportError::FixtureMismatch)
}

fn validate_charge_flags(
    merchant_scheduled: bool,
    confirmation: bool,
    currency: &str,
) -> Result<(), PaymentTransportError> {
    validate_currency(currency)?;
    if merchant_scheduled && confirmation {
        Ok(())
    } else {
        Err(PaymentTransportError::FixtureMismatch)
    }
}

fn validate_currency(currency: &str) -> Result<(), PaymentTransportError> {
    if matches!(currency, "KRW" | "krw") {
        Ok(())
    } else {
        Err(PaymentTransportError::FixtureMismatch)
    }
}

fn decode<T: DeserializeOwned>(bytes: &[u8]) -> Result<T, PaymentTransportError> {
    serde_json::from_slice(bytes).map_err(|_| PaymentTransportError::FixtureMismatch)
}

fn sha256_hex(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let digest = Sha256::digest(bytes);
    let mut output = String::with_capacity(64);
    for byte in digest {
        output.push(char::from(HEX[usize::from(byte >> 4)]));
        output.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    output
}

const fn provider_slug(provider: ProviderKind) -> &'static str {
    match provider {
        ProviderKind::TossPayments => "toss",
        ProviderKind::KakaoPay => "kakao",
        ProviderKind::Stripe => "stripe",
    }
}
