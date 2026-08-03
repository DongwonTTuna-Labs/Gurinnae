use serde::Serialize;

use super::FixturePayment;
use crate::{PaymentState, PaymentTransportError, ProviderKind, ProviderPaymentId};

pub(super) fn issue_response(
    provider: ProviderKind,
    first: &str,
    second: &str,
) -> Result<Vec<u8>, PaymentTransportError> {
    match provider {
        ProviderKind::TossPayments => encode(&TossIssueResponse {
            billing_key: first,
            customer_key: second,
        }),
        ProviderKind::KakaoPay => encode(&KakaoIssueResponse {
            subscription_id: first,
            partner_user_id: second,
        }),
        ProviderKind::Stripe => encode(&StripeIssueResponse {
            customer_id: first,
            payment_method_id: second,
        }),
    }
}

pub(in crate::deterministic_fixture) fn charge_response(
    payment: &FixturePayment,
) -> Result<Vec<u8>, PaymentTransportError> {
    match payment.provider {
        ProviderKind::TossPayments => encode(&TossChargeResponse {
            payment_key: payment.provider_payment_id.as_str(),
            order_id: payment.merchant_order_id.as_str(),
        }),
        ProviderKind::KakaoPay => encode(&KakaoChargeResponse {
            transaction_id: payment.provider_payment_id.as_str(),
            partner_order_id: payment.merchant_order_id.as_str(),
        }),
        ProviderKind::Stripe => encode(&StripeChargeResponse {
            payment_intent_id: payment.provider_payment_id.as_str(),
            merchant_order_id: payment.merchant_order_id.as_str(),
        }),
    }
}

pub(in crate::deterministic_fixture) fn refund_response(
    provider: ProviderKind,
    payment_id: &ProviderPaymentId,
) -> Result<Vec<u8>, PaymentTransportError> {
    match provider {
        ProviderKind::TossPayments => encode(&TossRefundResponse {
            payment_key: payment_id.as_str(),
        }),
        ProviderKind::KakaoPay => encode(&KakaoRefundResponse {
            transaction_id: payment_id.as_str(),
        }),
        ProviderKind::Stripe => encode(&StripeRefundResponse {
            payment_intent_id: payment_id.as_str(),
        }),
    }
}

pub(in crate::deterministic_fixture) fn fetch_response(
    payment: &FixturePayment,
) -> Result<Vec<u8>, PaymentTransportError> {
    match payment.provider {
        ProviderKind::TossPayments => encode(&TossFetchResponse {
            payment_key: payment.provider_payment_id.as_str(),
            order_id: payment.merchant_order_id.as_str(),
            amount: payment.amount.whole_krw(),
            status: toss_status(payment.state),
            observed_at_unix: payment.observed_at_unix,
        }),
        ProviderKind::KakaoPay => encode(&KakaoFetchResponse {
            transaction_id: payment.provider_payment_id.as_str(),
            partner_order_id: payment.merchant_order_id.as_str(),
            total_amount: payment.amount.whole_krw(),
            status: kakao_status(payment.state),
            observed_at_unix: payment.observed_at_unix,
        }),
        ProviderKind::Stripe => encode(&StripeFetchResponse {
            payment_intent_id: payment.provider_payment_id.as_str(),
            merchant_order_id: payment.merchant_order_id.as_str(),
            amount: payment.amount.whole_krw(),
            currency: "KRW",
            status: stripe_status(payment.state),
            refunded_amount: payment.refunded_amount,
            observed_at_unix: payment.observed_at_unix,
        }),
    }
}

fn encode<T: Serialize>(value: &T) -> Result<Vec<u8>, PaymentTransportError> {
    serde_json::to_vec(value).map_err(|_| PaymentTransportError::FixtureMismatch)
}

const fn toss_status(state: PaymentState) -> &'static str {
    match state {
        PaymentState::Pending => "IN_PROGRESS",
        PaymentState::Succeeded => "DONE",
        PaymentState::Failed => "ABORTED",
        PaymentState::Canceled | PaymentState::Refunded => "CANCELED",
        PaymentState::PartiallyRefunded => "PARTIAL_CANCELED",
    }
}

const fn kakao_status(state: PaymentState) -> &'static str {
    match state {
        PaymentState::Pending => "READY",
        PaymentState::Succeeded => "SUCCESS_PAYMENT",
        PaymentState::Failed => "FAIL_PAYMENT",
        PaymentState::Canceled | PaymentState::Refunded => "CANCEL_PAYMENT",
        PaymentState::PartiallyRefunded => "PART_CANCEL_PAYMENT",
    }
}

const fn stripe_status(state: PaymentState) -> &'static str {
    match state {
        PaymentState::Pending => "processing",
        PaymentState::Succeeded | PaymentState::PartiallyRefunded | PaymentState::Refunded => {
            "succeeded"
        }
        PaymentState::Failed => "failed",
        PaymentState::Canceled => "canceled",
    }
}

macro_rules! response_struct {
    ($name:ident { $($field:ident : $type:ty),+ $(,)? }) => {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct $name<'a> {
            $($field: $type),+
        }
    };
}

response_struct!(TossIssueResponse { billing_key: &'a str, customer_key: &'a str });
response_struct!(KakaoIssueResponse { subscription_id: &'a str, partner_user_id: &'a str });
response_struct!(StripeIssueResponse { customer_id: &'a str, payment_method_id: &'a str });
response_struct!(TossChargeResponse { payment_key: &'a str, order_id: &'a str });
response_struct!(KakaoChargeResponse { transaction_id: &'a str, partner_order_id: &'a str });
response_struct!(StripeChargeResponse { payment_intent_id: &'a str, merchant_order_id: &'a str });
response_struct!(TossRefundResponse { payment_key: &'a str });
response_struct!(KakaoRefundResponse { transaction_id: &'a str });
response_struct!(StripeRefundResponse { payment_intent_id: &'a str });

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TossFetchResponse<'a> {
    payment_key: &'a str,
    order_id: &'a str,
    amount: i64,
    status: &'static str,
    observed_at_unix: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct KakaoFetchResponse<'a> {
    transaction_id: &'a str,
    partner_order_id: &'a str,
    total_amount: i64,
    status: &'static str,
    observed_at_unix: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct StripeFetchResponse<'a> {
    payment_intent_id: &'a str,
    merchant_order_id: &'a str,
    amount: i64,
    currency: &'static str,
    status: &'static str,
    refunded_amount: i64,
    observed_at_unix: i64,
}
