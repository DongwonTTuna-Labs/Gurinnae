use std::sync::Arc;

use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;

use super::{FixtureRuntime, decode, fixture_runtime, hint_digest, sha256_hex};
use crate::{
    AdapterEnvironment, BillingAuthorization, BillingCredentialKind, BillingKeyMaterial,
    ChargeAcknowledgement, ChargeInstrument, ChargeRequest, FetchPaymentRequest, FetchedPayment,
    IssueBillingKeyReceipt, IssueBillingKeyRequest, KeyVersion, MerchantOrderId, PaymentLocator,
    PaymentProvider, PaymentProviderError, PaymentState, PaymentTransport, ProviderCapabilities,
    ProviderEventIdentity, ProviderFuture, ProviderKind, ProviderOperation, ProviderPaymentId,
    RefundAcknowledgement, RefundRequest, WebhookAuthentication, WebhookEnvelope, WebhookHint,
    WebhookSignatureSupport, WebhookSigningKey,
};

type HmacSha256 = Hmac<Sha256>;

pub struct Stripe {
    runtime: FixtureRuntime,
    webhook_signing_key: WebhookSigningKey,
    webhook_key_version: KeyVersion,
}

impl Stripe {
    pub fn new(
        environment: AdapterEnvironment,
        transport: Arc<dyn PaymentTransport>,
        webhook_signing_key: WebhookSigningKey,
        webhook_key_version: KeyVersion,
    ) -> Result<Self, PaymentProviderError> {
        Ok(Self {
            runtime: fixture_runtime(environment, transport)?,
            webhook_signing_key,
            webhook_key_version,
        })
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct IssueRequestWire<'a> {
    customer_id: &'a str,
    payment_method_id: &'a str,
    usage: &'static str,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct IssueResponseWire {
    customer_id: String,
    payment_method_id: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ChargeRequestWire<'a> {
    customer_id: &'a str,
    payment_method_id: &'a str,
    amount: i64,
    currency: &'static str,
    merchant_order_id: &'a str,
    off_session: bool,
    confirm: bool,
    merchant_scheduled: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ChargeResponseWire {
    payment_intent_id: String,
    merchant_order_id: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RefundRequestWire<'a> {
    payment_intent_id: &'a str,
    amount: i64,
    currency: &'static str,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RefundResponseWire {
    payment_intent_id: String,
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
    payment_intent_id: String,
    merchant_order_id: String,
    amount: i64,
    currency: String,
    status: String,
    refunded_amount: i64,
    observed_at_unix: i64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WebhookWire {
    id: String,
    r#type: String,
    data: WebhookData,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WebhookData {
    object: WebhookObject,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WebhookObject {
    id: String,
}

impl PaymentProvider for Stripe {
    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities::fixture(
            ProviderKind::Stripe,
            BillingCredentialKind::StripeOffSessionPaymentMethod,
            WebhookSignatureSupport::StripeV1HmacSha256,
        )
    }

    fn issue_billing_key<'a>(
        &'a self,
        request: &'a IssueBillingKeyRequest,
    ) -> ProviderFuture<'a, IssueBillingKeyReceipt> {
        Box::pin(async move {
            let BillingAuthorization::Stripe {
                customer_id,
                payment_method_id,
            } = &request.authorization
            else {
                return Err(PaymentProviderError::ProviderMismatch);
            };
            let wire = IssueRequestWire {
                customer_id: customer_id.expose_for_provider_codec(),
                payment_method_id: payment_method_id.expose_for_provider_codec(),
                usage: "off_session",
            };
            let output = self
                .runtime
                .exchange(
                    ProviderKind::Stripe,
                    ProviderOperation::IssueBillingKey,
                    Some(request.idempotency_key),
                    &wire,
                )
                .await?;
            let response: IssueResponseWire = decode(&output.body)?;
            if response.customer_id != customer_id.expose_for_provider_codec()
                || response.payment_method_id != payment_method_id.expose_for_provider_codec()
            {
                return Err(PaymentProviderError::InvalidResponse);
            }
            Ok(IssueBillingKeyReceipt {
                binding_id: request.binding_id,
                use_policy: request.use_policy,
                material: BillingKeyMaterial::Stripe {
                    customer_id: crate::SecretText::try_new(response.customer_id)?,
                    payment_method_id: crate::SecretText::try_new(response.payment_method_id)?,
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
            let ChargeInstrument::Stored(BillingKeyMaterial::Stripe {
                customer_id,
                payment_method_id,
            }) = request.instrument
            else {
                return Err(PaymentProviderError::ProviderMismatch);
            };
            let wire = ChargeRequestWire {
                customer_id: customer_id.expose_for_provider_codec(),
                payment_method_id: payment_method_id.expose_for_provider_codec(),
                amount: request.amount.whole_krw(),
                currency: "krw",
                merchant_order_id: request.merchant_order_id.as_str(),
                off_session: true,
                confirm: true,
                merchant_scheduled: true,
            };
            let output = self
                .runtime
                .exchange(
                    ProviderKind::Stripe,
                    ProviderOperation::Charge,
                    Some(request.idempotency_key),
                    &wire,
                )
                .await?;
            let response: ChargeResponseWire = decode(&output.body)?;
            if response.merchant_order_id != request.merchant_order_id.as_str() {
                return Err(PaymentProviderError::InvalidResponse);
            }
            Ok(ChargeAcknowledgement {
                attempt_id: request.attempt_id,
                merchant_order_id: MerchantOrderId::try_new(response.merchant_order_id)?,
                locator: PaymentLocator::ProviderPaymentId(ProviderPaymentId::try_new(
                    response.payment_intent_id,
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
                payment_intent_id: request.payment_id.as_str(),
                amount: request.amount.whole_krw(),
                currency: "krw",
            };
            let output = self
                .runtime
                .exchange(
                    ProviderKind::Stripe,
                    ProviderOperation::Refund,
                    Some(request.idempotency_key),
                    &wire,
                )
                .await?;
            let response: RefundResponseWire = decode(&output.body)?;
            if response.payment_intent_id != request.payment_id.as_str() {
                return Err(PaymentProviderError::InvalidResponse);
            }
            Ok(RefundAcknowledgement {
                attempt_id: request.attempt_id,
                locator: PaymentLocator::ProviderPaymentId(ProviderPaymentId::try_new(
                    response.payment_intent_id,
                )?),
                transport: output.receipt,
            })
        })
    }

    fn verify_webhook(
        &self,
        webhook: WebhookEnvelope<'_>,
    ) -> Result<WebhookHint, PaymentProviderError> {
        let policy = webhook.replay_policy.validate()?;
        let signature_header = webhook
            .headers
            .stripe_signature()
            .ok_or(PaymentProviderError::WebhookAuthenticationFailed)?;
        let (signed_at_unix, signature) = parse_signature_header(signature_header)?;
        let age = (i128::from(policy.now_unix) - i128::from(signed_at_unix)).abs();
        if age > i128::from(policy.tolerance_seconds) {
            return Err(PaymentProviderError::WebhookReplayPolicyFailed);
        }
        let mut signed_payload = signed_at_unix.to_string().into_bytes();
        signed_payload.push(b'.');
        signed_payload.extend_from_slice(webhook.body);
        let mut mac =
            HmacSha256::new_from_slice(self.webhook_signing_key.expose_for_verification())
                .map_err(|_| PaymentProviderError::WebhookAuthenticationFailed)?;
        mac.update(&signed_payload);
        mac.verify_slice(&signature)
            .map_err(|_| PaymentProviderError::WebhookAuthenticationFailed)?;

        let parsed: WebhookWire = decode(webhook.body)?;
        if parsed.r#type.trim().is_empty() {
            return Err(PaymentProviderError::InvalidResponse);
        }
        let event_identity = ProviderEventIdentity::try_new(parsed.id)?;
        let payment_id = ProviderPaymentId::try_new(parsed.data.object.id)?;
        let body_sha256 = sha256_hex(webhook.body);
        let hint_sha256 = hint_digest(
            ProviderKind::Stripe,
            &event_identity,
            payment_id.as_str(),
            &body_sha256,
        );
        Ok(WebhookHint::new(
            ProviderKind::Stripe,
            event_identity,
            PaymentLocator::ProviderPaymentId(payment_id),
            WebhookAuthentication::VerifiedSignature {
                algorithm: "STRIPE_V1_HMAC_SHA256",
                key_version: self.webhook_key_version.clone(),
                signed_at_unix,
                signature_sha256: sha256_hex(&signature),
                signed_payload_sha256: sha256_hex(&signed_payload),
            },
            body_sha256,
            hint_sha256,
        ))
    }

    fn fetch_payment<'a>(
        &'a self,
        request: &'a FetchPaymentRequest,
    ) -> ProviderFuture<'a, FetchedPayment> {
        Box::pin(async move {
            if request.provider != ProviderKind::Stripe {
                return Err(PaymentProviderError::ProviderMismatch);
            }
            let (kind, locator) = locator_parts(&request.locator);
            let output = self
                .runtime
                .exchange(
                    ProviderKind::Stripe,
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
            let amount = crate::KrwAmount::try_from_currency(response.amount, &response.currency)?;
            Ok(FetchedPayment {
                provider: ProviderKind::Stripe,
                provider_payment_id: ProviderPaymentId::try_new(response.payment_intent_id)?,
                attempt_id: request.expected_attempt_id,
                merchant_order_id: MerchantOrderId::try_new(response.merchant_order_id)?,
                amount,
                state: stripe_state(&response.status, response.refunded_amount, amount)?,
                provider_observed_at_unix: response.observed_at_unix,
                transport: output.receipt,
            })
        })
    }
}

fn parse_signature_header(value: &str) -> Result<(i64, [u8; 32]), PaymentProviderError> {
    let mut timestamp = None;
    let mut signature = None;
    for segment in value.split(',') {
        let (name, value) = segment
            .trim()
            .split_once('=')
            .ok_or(PaymentProviderError::WebhookAuthenticationFailed)?;
        match name {
            "t" if timestamp.is_none() => {
                timestamp = Some(
                    value
                        .parse::<i64>()
                        .map_err(|_| PaymentProviderError::WebhookAuthenticationFailed)?,
                );
            }
            "v1" if signature.is_none() => signature = Some(decode_hex_32(value)?),
            _ => return Err(PaymentProviderError::WebhookAuthenticationFailed),
        }
    }
    Ok((
        timestamp.ok_or(PaymentProviderError::WebhookAuthenticationFailed)?,
        signature.ok_or(PaymentProviderError::WebhookAuthenticationFailed)?,
    ))
}

fn decode_hex_32(value: &str) -> Result<[u8; 32], PaymentProviderError> {
    if value.len() != 64 {
        return Err(PaymentProviderError::WebhookAuthenticationFailed);
    }
    let mut output = [0_u8; 32];
    for (index, pair) in value.as_bytes().chunks_exact(2).enumerate() {
        let high = hex_nibble(pair[0]).ok_or(PaymentProviderError::WebhookAuthenticationFailed)?;
        let low = hex_nibble(pair[1]).ok_or(PaymentProviderError::WebhookAuthenticationFailed)?;
        output[index] = (high << 4) | low;
    }
    Ok(output)
}

fn hex_nibble(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        _ => None,
    }
}

fn locator_parts(locator: &PaymentLocator) -> (&'static str, &str) {
    match locator {
        PaymentLocator::ProviderPaymentId(value) => ("PAYMENT_INTENT_ID", value.as_str()),
        PaymentLocator::MerchantOrderId(value) => ("MERCHANT_ORDER_ID", value.as_str()),
    }
}

fn validate_fetch(
    request: &FetchPaymentRequest,
    response: &FetchResponseWire,
) -> Result<(), PaymentProviderError> {
    if response.merchant_order_id != request.expected_merchant_order_id.as_str()
        || response.amount != request.expected_amount.whole_krw()
        || response.currency != "KRW"
        || response.refunded_amount < 0
        || response.refunded_amount > response.amount
        || response.observed_at_unix <= 0
    {
        return Err(PaymentProviderError::WebhookBindingMismatch);
    }
    if let PaymentLocator::ProviderPaymentId(expected) = &request.locator
        && response.payment_intent_id != expected.as_str()
    {
        return Err(PaymentProviderError::WebhookBindingMismatch);
    }
    Ok(())
}

fn stripe_state(
    status: &str,
    refunded_amount: i64,
    amount: crate::KrwAmount,
) -> Result<PaymentState, PaymentProviderError> {
    if refunded_amount == amount.whole_krw() {
        return Ok(PaymentState::Refunded);
    }
    if refunded_amount > 0 {
        return Ok(PaymentState::PartiallyRefunded);
    }
    match status {
        "requires_payment_method" | "requires_confirmation" | "requires_action" | "processing" => {
            Ok(PaymentState::Pending)
        }
        "succeeded" => Ok(PaymentState::Succeeded),
        "canceled" => Ok(PaymentState::Canceled),
        "failed" => Ok(PaymentState::Failed),
        _ => Err(PaymentProviderError::InvalidResponse),
    }
}
