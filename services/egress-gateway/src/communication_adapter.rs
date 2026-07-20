//! Typed outbound communication adapters.
//!
//! The notification worker never talks to a provider directly.  This module is
//! deliberately small and provider-specific: a channel is selected once and
//! the adapter owns request framing and receipt extraction.  Unknown or
//! unconfigured channels fail closed; they are never sent through the SMTP
//! facade with a marker header.

use reqwest::{Client, Url};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Channel {
    Telegram,
    WhatsApp,
    Line,
    Sms,
    Kakao,
}

impl Channel {
    pub fn parse(value: &str) -> Option<Self> {
        match value.to_ascii_uppercase().as_str() {
            "TELEGRAM" | "TELEGRAM_BOT_API" => Some(Self::Telegram),
            "WHATSAPP" | "META_WHATSAPP_BUSINESS_CLOUD" => Some(Self::WhatsApp),
            "LINE" | "LINE_MESSAGING_API" => Some(Self::Line),
            "SMS" | "SOLAPI_SMS" => Some(Self::Sms),
            "KAKAO" | "SOLAPI_KAKAO_BIZMESSAGE" => Some(Self::Kakao),
            _ => None,
        }
    }

    pub fn adapter_id(self) -> &'static str {
        match self {
            Self::Telegram => "telegram-bot-api-v1",
            Self::WhatsApp => "meta-whatsapp-business-cloud-v1",
            Self::Line => "line-messaging-api-v1",
            Self::Sms => "solapi-sms-v1",
            Self::Kakao => "solapi-kakao-bizmessage-v1",
        }
    }
}

#[derive(Clone)]
pub struct Adapter {
    client: Client,
    pub channel: Channel,
    endpoint: Url,
    credential: String,
}

#[derive(Clone, Debug)]
pub struct OutboundMessage<'a> {
    pub recipient: &'a str,
    pub subject: &'a str,
    pub text: &'a str,
    pub idempotency_key: &'a str,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum PollState {
    Delivered,
    Read,
    FailedPermanent,
    ReconciliationRequired,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PollReceipt {
    pub provider_message_id: String,
    pub state: PollState,
    pub provider_evidence_digest: String,
}

#[derive(Clone, Debug)]
pub struct PollRequest<'a> {
    pub provider_message_id: &'a str,
}

#[derive(Debug, Error)]
pub enum AdapterError {
    #[error("communication adapter is not configured")]
    NotConfigured,
    #[error("communication request failed")]
    Request,
    #[error("communication provider returned an invalid receipt")]
    InvalidReceipt,
    #[error("communication provider does not expose an authenticated status poll")]
    PollUnsupported,
}

#[derive(Debug, Serialize)]
struct TelegramRequest<'a> {
    chat_id: &'a str,
    text: &'a str,
    disable_web_page_preview: bool,
}

#[derive(Debug, Serialize)]
struct WhatsAppRequest<'a> {
    messaging_product: &'static str,
    recipient_type: &'static str,
    to: &'a str,
    r#type: &'static str,
    text: WhatsAppText<'a>,
}

#[derive(Debug, Serialize)]
struct WhatsAppText<'a> {
    preview_url: bool,
    body: &'a str,
}

#[derive(Debug, Serialize)]
struct LineRequest<'a> {
    to: &'a str,
    messages: [LineMessage<'a>; 1],
}

#[derive(Debug, Serialize)]
struct LineMessage<'a> {
    r#type: &'static str,
    text: &'a str,
}

#[derive(Debug, Serialize)]
struct SolapiRequest<'a> {
    message: SolapiMessage<'a>,
}

#[derive(Debug, Serialize)]
struct SolapiMessage<'a> {
    to: &'a str,
    text: &'a str,
}

#[derive(Debug, Deserialize)]
struct TelegramResponse {
    ok: bool,
    result: Option<TelegramResult>,
}

#[derive(Debug, Deserialize)]
struct TelegramResult {
    message_id: i64,
}

#[derive(Debug, Deserialize)]
struct WhatsAppResponse {
    messages: Option<Vec<WhatsAppResult>>,
}

#[derive(Debug, Deserialize)]
struct WhatsAppResult {
    id: String,
}

#[derive(Debug, Deserialize)]
struct LineResponse {
    #[serde(default)]
    request_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SolapiResponse {
    group_id: Option<String>,
    message_id: Option<String>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct SolapiPollResponse {
    #[serde(alias = "statusCode", alias = "status_code")]
    status: Option<String>,
    #[serde(alias = "messageId", alias = "message_id")]
    message_id: Option<String>,
    #[serde(alias = "groupId", alias = "group_id")]
    group_id: Option<String>,
}

impl Adapter {
    pub fn new(channel: Channel, endpoint: Url, credential: String) -> Result<Self, AdapterError> {
        if credential.trim().is_empty() {
            return Err(AdapterError::NotConfigured);
        }
        let client = Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .map_err(|_| AdapterError::Request)?;
        Ok(Self {
            client,
            channel,
            endpoint,
            credential,
        })
    }

    pub async fn send(&self, message: OutboundMessage<'_>) -> Result<String, AdapterError> {
        let idempotency_key = message.idempotency_key;
        let (request, body) = self.request(message)?;
        let mut outbound = self.client.post(request);
        if !matches!(self.channel, Channel::Telegram) {
            outbound = outbound.bearer_auth(&self.credential);
        }
        let response = outbound
            .header("x-gurine-idempotency-key", idempotency_key)
            .header("x-gurine-adapter-id", self.channel.adapter_id())
            .json(&body)
            .send()
            .await
            .map_err(|_| AdapterError::Request)?;
        if !response.status().is_success() {
            return Err(AdapterError::Request);
        }
        let bytes = response.bytes().await.map_err(|_| AdapterError::Request)?;
        self.receipt(&bytes)
    }

    /// Poll a provider-native status endpoint with the same credential and
    /// provider revision as the send path.  Adapters without a documented
    /// authenticated status API fail closed instead of treating an accepted
    /// send response as delivery proof.
    pub async fn poll(&self, request: PollRequest<'_>) -> Result<PollReceipt, AdapterError> {
        if request.provider_message_id.trim().is_empty()
            || request.provider_message_id.len() > 256
            || request
                .provider_message_id
                .bytes()
                .any(|byte| byte.is_ascii_control() || byte == b'/')
        {
            return Err(AdapterError::InvalidReceipt);
        }
        if !matches!(self.channel, Channel::Sms | Channel::Kakao) {
            return Err(AdapterError::PollUnsupported);
        }
        let mut endpoint = self.endpoint.clone();
        let path = endpoint.path().trim_end_matches('/');
        endpoint.set_path(&format!("{path}/{}", request.provider_message_id));
        let response = self
            .client
            .get(endpoint)
            .bearer_auth(&self.credential)
            .header("x-gurine-adapter-id", self.channel.adapter_id())
            .send()
            .await
            .map_err(|_| AdapterError::Request)?;
        if !response.status().is_success() {
            return Err(AdapterError::Request);
        }
        let bytes = response.bytes().await.map_err(|_| AdapterError::Request)?;
        let value: SolapiPollResponse =
            serde_json::from_slice(&bytes).map_err(|_| AdapterError::InvalidReceipt)?;
        let id = value
            .message_id
            .clone()
            .or(value.group_id.clone())
            .filter(|id| id == request.provider_message_id)
            .ok_or(AdapterError::InvalidReceipt)?;
        let state = match value
            .status
            .as_deref()
            .map(|status| status.to_ascii_uppercase())
            .as_deref()
        {
            Some("DELIVERED" | "COMPLETED" | "SUCCESS" | "SENT") => PollState::Delivered,
            Some("READ") => PollState::Read,
            Some("FAILED" | "FAILURE" | "REJECTED" | "CANCELED" | "CANCELLED") => {
                PollState::FailedPermanent
            }
            _ => PollState::ReconciliationRequired,
        };
        let normalized = serde_json::json!({
            "adapterId": self.channel.adapter_id(),
            "providerMessageId": id,
            "state": state,
            "status": value.status,
        });
        let provider_evidence_digest =
            format!("{:x}", Sha256::digest(normalized.to_string().as_bytes()));
        Ok(PollReceipt {
            provider_message_id: id,
            state,
            provider_evidence_digest,
        })
    }

    fn request(
        &self,
        message: OutboundMessage<'_>,
    ) -> Result<(Url, serde_json::Value), AdapterError> {
        let body = match self.channel {
            Channel::Telegram => serde_json::to_value(TelegramRequest {
                chat_id: message.recipient,
                text: message.text,
                disable_web_page_preview: true,
            })
            .map_err(|_| AdapterError::Request)?,
            Channel::WhatsApp => serde_json::to_value(WhatsAppRequest {
                messaging_product: "whatsapp",
                recipient_type: "individual",
                to: message.recipient,
                r#type: "text",
                text: WhatsAppText {
                    preview_url: false,
                    body: message.text,
                },
            })
            .map_err(|_| AdapterError::Request)?,
            Channel::Line => serde_json::to_value(LineRequest {
                to: message.recipient,
                messages: [LineMessage {
                    r#type: "text",
                    text: message.text,
                }],
            })
            .map_err(|_| AdapterError::Request)?,
            Channel::Sms | Channel::Kakao => serde_json::to_value(SolapiRequest {
                message: SolapiMessage {
                    to: message.recipient,
                    text: message.text,
                },
            })
            .map_err(|_| AdapterError::Request)?,
        };
        let mut endpoint = self.endpoint.clone();
        if self.channel == Channel::Telegram {
            let path = endpoint.path().trim_end_matches('/');
            endpoint.set_path(&format!("{path}/bot{}/sendMessage", self.credential));
        }
        Ok((endpoint, body))
    }

    fn receipt(&self, bytes: &[u8]) -> Result<String, AdapterError> {
        match self.channel {
            Channel::Telegram => {
                let value: TelegramResponse =
                    serde_json::from_slice(bytes).map_err(|_| AdapterError::InvalidReceipt)?;
                if !value.ok {
                    return Err(AdapterError::InvalidReceipt);
                }
                value
                    .result
                    .map(|result| format!("telegram:{}", result.message_id))
                    .ok_or(AdapterError::InvalidReceipt)
            }
            Channel::WhatsApp => {
                let value: WhatsAppResponse =
                    serde_json::from_slice(bytes).map_err(|_| AdapterError::InvalidReceipt)?;
                value
                    .messages
                    .and_then(|items| items.into_iter().next())
                    .map(|item| format!("whatsapp:{}", item.id))
                    .ok_or(AdapterError::InvalidReceipt)
            }
            Channel::Line => {
                let value: LineResponse =
                    serde_json::from_slice(bytes).map_err(|_| AdapterError::InvalidReceipt)?;
                (!value.request_id.is_empty())
                    .then(|| format!("line:{}", value.request_id))
                    .ok_or(AdapterError::InvalidReceipt)
            }
            Channel::Sms | Channel::Kakao => {
                let value: SolapiResponse =
                    serde_json::from_slice(bytes).map_err(|_| AdapterError::InvalidReceipt)?;
                value
                    .message_id
                    .or(value.group_id)
                    .map(|id| format!("solapi:{}", id))
                    .ok_or(AdapterError::InvalidReceipt)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn adapter(channel: Channel) -> Adapter {
        Adapter::new(
            channel,
            Url::parse("https://provider.invalid/v1/send").unwrap(),
            "test-secret".into(),
        )
        .unwrap()
    }

    #[test]
    fn canonical_channels_map_to_distinct_adapters() {
        let ids = [
            Channel::Telegram,
            Channel::WhatsApp,
            Channel::Line,
            Channel::Sms,
            Channel::Kakao,
        ]
        .map(Channel::adapter_id);
        assert_eq!(
            ids,
            [
                "telegram-bot-api-v1",
                "meta-whatsapp-business-cloud-v1",
                "line-messaging-api-v1",
                "solapi-sms-v1",
                "solapi-kakao-bizmessage-v1",
            ]
        );
    }

    #[test]
    fn provider_receipts_are_rejected_when_missing() {
        assert!(
            adapter(Channel::Telegram)
                .receipt(br#"{"ok":true,"result":{}}"#)
                .is_err()
        );
        assert!(
            adapter(Channel::WhatsApp)
                .receipt(br#"{"messages":[]}"#)
                .is_err()
        );
        assert!(adapter(Channel::Line).receipt(br#"{}"#).is_err());
        assert!(adapter(Channel::Sms).receipt(br#"{}"#).is_err());
    }

    #[test]
    fn provider_receipts_are_typed_per_channel() {
        assert_eq!(
            adapter(Channel::Telegram)
                .receipt(br#"{"ok":true,"result":{"message_id":7}}"#)
                .unwrap(),
            "telegram:7"
        );
        assert_eq!(
            adapter(Channel::WhatsApp)
                .receipt(br#"{"messages":[{"id":"wamid.1"}]}"#)
                .unwrap(),
            "whatsapp:wamid.1"
        );
        assert_eq!(
            adapter(Channel::Line)
                .receipt(br#"{"request_id":"line-1"}"#)
                .unwrap(),
            "line:line-1"
        );
        assert_eq!(
            adapter(Channel::Sms)
                .receipt(br#"{"messageId":"sms-1"}"#)
                .unwrap(),
            "solapi:sms-1"
        );
        assert_eq!(
            adapter(Channel::Kakao)
                .receipt(br#"{"groupId":"group-1"}"#)
                .unwrap(),
            "solapi:group-1"
        );
    }

    #[test]
    fn telegram_uses_bot_token_path_while_other_channels_use_bearer() {
        let telegram = adapter(Channel::Telegram);
        let (url, _) = telegram
            .request(OutboundMessage {
                recipient: "chat-1",
                subject: "subject",
                text: "hello",
                idempotency_key: "k",
            })
            .expect("test request serialization");
        assert_eq!(url.path(), "/v1/send/bottest-secret/sendMessage");
    }
}
