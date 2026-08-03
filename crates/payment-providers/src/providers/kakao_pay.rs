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

pub struct KakaoPay {
    runtime: FixtureRuntime,
}

impl KakaoPay {
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
    transaction_id: &'a str,
    approval_token: &'a str,
    partner_user_id: &'a str,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct IssueResponseWire {
    subscription_id: String,
    partner_user_id: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ChargeRequestWire<'a> {
    subscription_id: &'a str,
    partner_user_id: &'a str,
    partner_order_id: &'a str,
    total_amount: i64,
    currency: &'static str,
    merchant_scheduled: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ChargeResponseWire {
    transaction_id: String,
    partner_order_id: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RefundRequestWire<'a> {
    transaction_id: &'a str,
    cancel_amount: i64,
    currency: &'static str,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RefundResponseWire {
    transaction_id: String,
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
    transaction_id: String,
    partner_order_id: String,
    total_amount: i64,
    status: String,
    observed_at_unix: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WebhookWire {
    event_id: String,
    transaction_id: String,
}

impl PaymentProvider for KakaoPay {
    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities::fixture(
            ProviderKind::KakaoPay,
            BillingCredentialKind::KakaoSubscriptionId,
            WebhookSignatureSupport::NotAvailableFetchRequired,
        )
    }

    fn issue_billing_key<'a>(
        &'a self,
        request: &'a IssueBillingKeyRequest,
    ) -> ProviderFuture<'a, IssueBillingKeyReceipt> {
        Box::pin(async move {
            let BillingAuthorization::KakaoPay {
                transaction_id,
                approval_token,
                partner_user_id,
            } = &request.authorization
            else {
                return Err(PaymentProviderError::ProviderMismatch);
            };
            let wire = IssueRequestWire {
                transaction_id: transaction_id.expose_for_provider_codec(),
                approval_token: approval_token.expose_for_provider_codec(),
                partner_user_id: partner_user_id.expose_for_provider_codec(),
            };
            let output = self
                .runtime
                .exchange(
                    ProviderKind::KakaoPay,
                    ProviderOperation::IssueBillingKey,
                    Some(request.idempotency_key),
                    &wire,
                )
                .await?;
            let response: IssueResponseWire = decode(&output.body)?;
            if response.partner_user_id != partner_user_id.expose_for_provider_codec() {
                return Err(PaymentProviderError::InvalidResponse);
            }
            Ok(IssueBillingKeyReceipt {
                binding_id: request.binding_id,
                use_policy: request.use_policy,
                material: BillingKeyMaterial::KakaoPay {
                    subscription_id: crate::SecretText::try_new(response.subscription_id)?,
                    partner_user_id: crate::SecretText::try_new(response.partner_user_id)?,
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
            let ChargeInstrument::Stored(BillingKeyMaterial::KakaoPay {
                subscription_id,
                partner_user_id,
            }) = request.instrument
            else {
                return Err(PaymentProviderError::ProviderMismatch);
            };
            let wire = ChargeRequestWire {
                subscription_id: subscription_id.expose_for_provider_codec(),
                partner_user_id: partner_user_id.expose_for_provider_codec(),
                partner_order_id: request.merchant_order_id.as_str(),
                total_amount: request.amount.whole_krw(),
                currency: "KRW",
                merchant_scheduled: true,
            };
            let output = self
                .runtime
                .exchange(
                    ProviderKind::KakaoPay,
                    ProviderOperation::Charge,
                    Some(request.idempotency_key),
                    &wire,
                )
                .await?;
            let response: ChargeResponseWire = decode(&output.body)?;
            if response.partner_order_id != request.merchant_order_id.as_str() {
                return Err(PaymentProviderError::InvalidResponse);
            }
            Ok(ChargeAcknowledgement {
                attempt_id: request.attempt_id,
                merchant_order_id: MerchantOrderId::try_new(response.partner_order_id)?,
                locator: PaymentLocator::ProviderPaymentId(ProviderPaymentId::try_new(
                    response.transaction_id,
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
                transaction_id: request.payment_id.as_str(),
                cancel_amount: request.amount.whole_krw(),
                currency: "KRW",
            };
            let output = self
                .runtime
                .exchange(
                    ProviderKind::KakaoPay,
                    ProviderOperation::Refund,
                    Some(request.idempotency_key),
                    &wire,
                )
                .await?;
            let response: RefundResponseWire = decode(&output.body)?;
            if response.transaction_id != request.payment_id.as_str() {
                return Err(PaymentProviderError::InvalidResponse);
            }
            Ok(RefundAcknowledgement {
                attempt_id: request.attempt_id,
                locator: PaymentLocator::ProviderPaymentId(ProviderPaymentId::try_new(
                    response.transaction_id,
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
        let payment_id = ProviderPaymentId::try_new(parsed.transaction_id)?;
        let body_sha256 = sha256_hex(webhook.body);
        let hint_sha256 = hint_digest(
            ProviderKind::KakaoPay,
            &event_identity,
            payment_id.as_str(),
            &body_sha256,
        );
        Ok(WebhookHint::new(
            ProviderKind::KakaoPay,
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
            if request.provider != ProviderKind::KakaoPay {
                return Err(PaymentProviderError::ProviderMismatch);
            }
            let (kind, locator) = locator_parts(&request.locator);
            let output = self
                .runtime
                .exchange(
                    ProviderKind::KakaoPay,
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
                provider: ProviderKind::KakaoPay,
                provider_payment_id: ProviderPaymentId::try_new(response.transaction_id)?,
                attempt_id: request.expected_attempt_id,
                merchant_order_id: MerchantOrderId::try_new(response.partner_order_id)?,
                amount: crate::KrwAmount::try_new(response.total_amount)?,
                state: kakao_state(&response.status)?,
                provider_observed_at_unix: response.observed_at_unix,
                transport: output.receipt,
            })
        })
    }
}

fn locator_parts(locator: &PaymentLocator) -> (&'static str, &str) {
    match locator {
        PaymentLocator::ProviderPaymentId(value) => ("TRANSACTION_ID", value.as_str()),
        PaymentLocator::MerchantOrderId(value) => ("PARTNER_ORDER_ID", value.as_str()),
    }
}

fn validate_fetch(
    request: &FetchPaymentRequest,
    response: &FetchResponseWire,
) -> Result<(), PaymentProviderError> {
    if response.partner_order_id != request.expected_merchant_order_id.as_str()
        || response.total_amount != request.expected_amount.whole_krw()
        || response.observed_at_unix <= 0
    {
        return Err(PaymentProviderError::WebhookBindingMismatch);
    }
    if let PaymentLocator::ProviderPaymentId(expected) = &request.locator
        && response.transaction_id != expected.as_str()
    {
        return Err(PaymentProviderError::WebhookBindingMismatch);
    }
    Ok(())
}

fn kakao_state(value: &str) -> Result<PaymentState, PaymentProviderError> {
    match value {
        "READY" | "AUTHENTICATING" => Ok(PaymentState::Pending),
        "SUCCESS_PAYMENT" => Ok(PaymentState::Succeeded),
        "CANCEL_PAYMENT" => Ok(PaymentState::Canceled),
        "PART_CANCEL_PAYMENT" => Ok(PaymentState::PartiallyRefunded),
        "FAIL_PAYMENT" => Ok(PaymentState::Failed),
        _ => Err(PaymentProviderError::InvalidResponse),
    }
}
