use std::sync::Arc;

use serde::{Deserialize, Serialize};

use super::{FixtureRuntime, decode, fixture_runtime, hint_digest, sha256_hex};
use crate::{
    AdapterEnvironment, BillingAuthorization, BillingCredentialKind, BillingKeyMaterial,
    ChargeAcknowledgement, ChargeInstrument, ChargeRequest, FetchPaymentRequest, FetchedPayment,
    IssueBillingKeyReceipt, IssueBillingKeyRequest, MerchantOrderId, PaymentLocator,
    PaymentProvider, PaymentProviderError, PaymentState, PaymentTransport, ProviderCapabilities,
    ProviderEventIdentity, ProviderFuture, ProviderKind, ProviderOperation, ProviderPaymentId,
    RefundAcknowledgement, RefundRequest, WebhookAuthentication, WebhookEnvelope, WebhookHint,
    WebhookSignatureSupport,
};

pub struct TossPayments {
    runtime: FixtureRuntime,
}

impl TossPayments {
    pub fn new(
        environment: AdapterEnvironment,
        transport: Arc<dyn PaymentTransport>,
    ) -> Result<Self, PaymentProviderError> {
        Ok(Self {
            runtime: fixture_runtime(environment, transport)?,
        })
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct IssueRequestWire<'a> {
    auth_key: &'a str,
    customer_key: &'a str,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct IssueResponseWire {
    billing_key: String,
    customer_key: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ChargeRequestWire<'a> {
    billing_key: &'a str,
    customer_key: &'a str,
    amount: i64,
    currency: &'static str,
    order_id: &'a str,
    merchant_scheduled: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ChargeResponseWire {
    payment_key: String,
    order_id: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RefundRequestWire<'a> {
    payment_key: &'a str,
    cancel_amount: i64,
    currency: &'static str,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RefundResponseWire {
    payment_key: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct FetchRequestWire<'a> {
    locator_kind: &'static str,
    locator: &'a str,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct FetchResponseWire {
    payment_key: String,
    order_id: String,
    amount: i64,
    status: String,
    observed_at_unix: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WebhookWire {
    event_id: String,
    payment_key: String,
}

impl PaymentProvider for TossPayments {
    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities::fixture(
            ProviderKind::TossPayments,
            BillingCredentialKind::TossBillingKey,
            WebhookSignatureSupport::NotAvailableFetchRequired,
        )
    }

    fn issue_billing_key<'a>(
        &'a self,
        request: &'a IssueBillingKeyRequest,
    ) -> ProviderFuture<'a, IssueBillingKeyReceipt> {
        Box::pin(async move {
            let BillingAuthorization::TossPayments {
                auth_key,
                customer_key,
            } = &request.authorization
            else {
                return Err(PaymentProviderError::ProviderMismatch);
            };
            let wire = IssueRequestWire {
                auth_key: auth_key.expose_for_provider_codec(),
                customer_key: customer_key.expose_for_provider_codec(),
            };
            let output = self
                .runtime
                .exchange(
                    ProviderKind::TossPayments,
                    ProviderOperation::IssueBillingKey,
                    Some(request.idempotency_key),
                    &wire,
                )
                .await?;
            let response: IssueResponseWire = decode(&output.body)?;
            if response.customer_key != customer_key.expose_for_provider_codec() {
                return Err(PaymentProviderError::InvalidResponse);
            }
            Ok(IssueBillingKeyReceipt {
                binding_id: request.binding_id,
                use_policy: request.use_policy,
                material: BillingKeyMaterial::TossPayments {
                    billing_key: crate::SecretText::try_new(response.billing_key)?,
                    customer_key: crate::SecretText::try_new(response.customer_key)?,
                },
                transport: output.receipt,
            })
        })
    }

    fn charge<'a>(
        &'a self,
        request: ChargeRequest<'a>,
    ) -> ProviderFuture<'a, ChargeAcknowledgement> {
        Box::pin(async move {
            let ChargeInstrument::Stored(BillingKeyMaterial::TossPayments {
                billing_key,
                customer_key,
            }) = request.instrument
            else {
                return Err(PaymentProviderError::ProviderMismatch);
            };
            let wire = ChargeRequestWire {
                billing_key: billing_key.expose_for_provider_codec(),
                customer_key: customer_key.expose_for_provider_codec(),
                amount: request.amount.whole_krw(),
                currency: "KRW",
                order_id: request.merchant_order_id.as_str(),
                merchant_scheduled: true,
            };
            let output = self
                .runtime
                .exchange(
                    ProviderKind::TossPayments,
                    ProviderOperation::Charge,
                    Some(request.idempotency_key),
                    &wire,
                )
                .await?;
            let response: ChargeResponseWire = decode(&output.body)?;
            if response.order_id != request.merchant_order_id.as_str() {
                return Err(PaymentProviderError::InvalidResponse);
            }
            Ok(ChargeAcknowledgement {
                attempt_id: request.attempt_id,
                merchant_order_id: MerchantOrderId::try_new(response.order_id)?,
                locator: PaymentLocator::ProviderPaymentId(ProviderPaymentId::try_new(
                    response.payment_key,
                )?),
                transport: output.receipt,
            })
        })
    }

    fn refund<'a>(
        &'a self,
        request: &'a RefundRequest,
    ) -> ProviderFuture<'a, RefundAcknowledgement> {
        Box::pin(async move {
            let wire = RefundRequestWire {
                payment_key: request.payment_id.as_str(),
                cancel_amount: request.amount.whole_krw(),
                currency: "KRW",
            };
            let output = self
                .runtime
                .exchange(
                    ProviderKind::TossPayments,
                    ProviderOperation::Refund,
                    Some(request.idempotency_key),
                    &wire,
                )
                .await?;
            let response: RefundResponseWire = decode(&output.body)?;
            if response.payment_key != request.payment_id.as_str() {
                return Err(PaymentProviderError::InvalidResponse);
            }
            Ok(RefundAcknowledgement {
                attempt_id: request.attempt_id,
                locator: PaymentLocator::ProviderPaymentId(ProviderPaymentId::try_new(
                    response.payment_key,
                )?),
                transport: output.receipt,
            })
        })
    }

    fn verify_webhook(
        &self,
        webhook: WebhookEnvelope<'_>,
    ) -> Result<WebhookHint, PaymentProviderError> {
        webhook.replay_policy.validate()?;
        let parsed: WebhookWire = decode(webhook.body)?;
        let event_identity = ProviderEventIdentity::try_new(parsed.event_id)?;
        let payment_id = ProviderPaymentId::try_new(parsed.payment_key)?;
        let body_sha256 = sha256_hex(webhook.body);
        let hint_sha256 = hint_digest(
            ProviderKind::TossPayments,
            &event_identity,
            payment_id.as_str(),
            &body_sha256,
        );
        Ok(WebhookHint::new(
            ProviderKind::TossPayments,
            event_identity,
            PaymentLocator::ProviderPaymentId(payment_id),
            WebhookAuthentication::NotAvailableFetchRequired,
            body_sha256,
            hint_sha256,
        ))
    }

    fn fetch_payment<'a>(
        &'a self,
        request: &'a FetchPaymentRequest,
    ) -> ProviderFuture<'a, FetchedPayment> {
        Box::pin(async move {
            if request.provider != ProviderKind::TossPayments {
                return Err(PaymentProviderError::ProviderMismatch);
            }
            let (kind, locator) = locator_parts(&request.locator);
            let output = self
                .runtime
                .exchange(
                    ProviderKind::TossPayments,
                    ProviderOperation::FetchPayment,
                    None,
                    &FetchRequestWire {
                        locator_kind: kind,
                        locator,
                    },
                )
                .await?;
            let response: FetchResponseWire = decode(&output.body)?;
            validate_fetch(request, &response)?;
            Ok(FetchedPayment {
                provider: ProviderKind::TossPayments,
                provider_payment_id: ProviderPaymentId::try_new(response.payment_key)?,
                attempt_id: request.expected_attempt_id,
                merchant_order_id: MerchantOrderId::try_new(response.order_id)?,
                amount: crate::KrwAmount::try_new(response.amount)?,
                state: toss_state(&response.status)?,
                provider_observed_at_unix: response.observed_at_unix,
                transport: output.receipt,
            })
        })
    }
}

fn locator_parts(locator: &PaymentLocator) -> (&'static str, &str) {
    match locator {
        PaymentLocator::ProviderPaymentId(value) => ("PAYMENT_KEY", value.as_str()),
        PaymentLocator::MerchantOrderId(value) => ("ORDER_ID", value.as_str()),
    }
}

fn validate_fetch(
    request: &FetchPaymentRequest,
    response: &FetchResponseWire,
) -> Result<(), PaymentProviderError> {
    if response.order_id != request.expected_merchant_order_id.as_str()
        || response.amount != request.expected_amount.whole_krw()
        || response.observed_at_unix <= 0
    {
        return Err(PaymentProviderError::WebhookBindingMismatch);
    }
    if let PaymentLocator::ProviderPaymentId(expected) = &request.locator
        && response.payment_key != expected.as_str()
    {
        return Err(PaymentProviderError::WebhookBindingMismatch);
    }
    Ok(())
}

fn toss_state(value: &str) -> Result<PaymentState, PaymentProviderError> {
    match value {
        "READY" | "IN_PROGRESS" | "WAITING_FOR_DEPOSIT" => Ok(PaymentState::Pending),
        "DONE" => Ok(PaymentState::Succeeded),
        "CANCELED" => Ok(PaymentState::Canceled),
        "PARTIAL_CANCELED" => Ok(PaymentState::PartiallyRefunded),
        "ABORTED" | "EXPIRED" => Ok(PaymentState::Failed),
        _ => Err(PaymentProviderError::InvalidResponse),
    }
}
