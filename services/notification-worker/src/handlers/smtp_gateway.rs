use gurine_email::port::EmailMessage;
use serde::{Deserialize, Serialize};
use url::Url;
use uuid::Uuid;

use super::delivery::{
    DeliveryError, ProviderBinding, ProviderPollReceipt, ProviderPreflightReceipt,
    ProviderRevision, SmtpGateway,
};

#[derive(Serialize)]
struct Request<'a> {
    channel: &'a str,
    from: &'a str,
    to: &'a str,
    subject: &'a str,
    text_body: &'a str,
    html_body: &'a str,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Response {
    provider_message_id: String,
}

impl SmtpGateway {
    pub fn new(url: Url) -> Result<Self, DeliveryError> {
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .map_err(|_| DeliveryError::Initialization)?;
        Ok(Self { client, url })
    }

    pub async fn send_for_channel(
        &self,
        message: &EmailMessage,
        channel: &str,
    ) -> Result<String, DeliveryError> {
        let key = sha256_hex(
            format!(
                "{}\n{}\n{}\n{}",
                channel, message.to, message.subject, message.text_body
            )
            .as_bytes(),
        );
        self.send_for_channel_with_key(message, channel, &key).await
    }

    pub async fn send_for_channel_with_key(
        &self,
        message: &EmailMessage,
        channel: &str,
        idempotency_key: &str,
    ) -> Result<String, DeliveryError> {
        if !matches!(
            channel,
            "EMAIL" | "SMS" | "TELEGRAM" | "WHATSAPP" | "LINE" | "KAKAO"
        ) {
            return Err(DeliveryError::Delivery);
        }
        if channel != "EMAIL" {
            return self
                .send_provider_channel(message, channel, idempotency_key)
                .await;
        }
        // Email uses the SMTP envelope. Every non-email adapter is a typed
        // communication contract and must receive only the fields accepted by
        // the egress `CommunicationRequest` (`recipient`, `subject`,
        // `textBody`, `idempotencyKey`). Sending the SMTP envelope to these
        // routes is rejected by their deny-unknown-fields deserializer.
        let payload = if channel == "EMAIL" {
            serde_json::to_value(Request {
                channel,
                from: &message.from,
                to: &message.to,
                subject: &message.subject,
                text_body: &message.text_body,
                html_body: &message.html_body,
            })
        } else {
            serde_json::to_value(ProviderRequest {
                recipient: &message.to,
                subject: &message.subject,
                text_body: &message.text_body,
                idempotency_key,
            })
        }
        .map_err(|_| DeliveryError::Delivery)?;
        let response = self
            .client
            .post(self.url.clone())
            .header("x-gurine-egress-caller", "notification-worker")
            .header("x-gurine-channel", channel)
            .header("x-gurine-idempotency-key", idempotency_key)
            // The SMTP endpoint intentionally has a separate, strict
            // envelope. Non-email adapters accept only their typed
            // recipient/content/idempotency contract above.
            .json(&payload)
            .send()
            .await
            .map_err(|_| DeliveryError::Delivery)?;
        if !response.status().is_success() {
            return Err(DeliveryError::Delivery);
        }
        response
            .json::<Response>()
            .await
            .map(|value| value.provider_message_id)
            .map_err(|_| DeliveryError::Delivery)
    }

    pub(super) async fn send_for_channel_with_binding(
        &self,
        message: &EmailMessage,
        channel: &str,
        idempotency_key: &str,
        binding: &ProviderBinding,
    ) -> Result<String, DeliveryError> {
        if !matches!(
            channel,
            "EMAIL" | "SMS" | "TELEGRAM" | "WHATSAPP" | "LINE" | "KAKAO"
        ) {
            return Err(DeliveryError::Delivery);
        }
        let mut endpoint = self.url.clone();
        if channel != "EMAIL" {
            endpoint.set_path(&format!("/communication/{}", channel.to_ascii_lowercase()));
        }
        let payload = if channel == "EMAIL" {
            serde_json::to_value(Request {
                channel,
                from: &message.from,
                to: &message.to,
                subject: &message.subject,
                text_body: &message.text_body,
                html_body: &message.html_body,
            })
        } else {
            serde_json::to_value(ProviderRequest {
                recipient: &message.to,
                subject: &message.subject,
                text_body: &message.text_body,
                idempotency_key,
            })
        }
        .map_err(|_| DeliveryError::Delivery)?;
        let response = self
            .client
            .post(endpoint)
            .header("x-gurine-egress-caller", "notification-worker")
            .header("x-gurine-channel", channel)
            .header("x-gurine-idempotency-key", idempotency_key)
            .header("x-gurine-provider-config-id", binding.config_id.to_string())
            .header(
                "x-gurine-provider-config-version",
                binding.config_version.to_string(),
            )
            .header(
                "x-gurine-provider-configuration-digest",
                &binding.configuration_digest,
            )
            .header(
                "x-gurine-provider-preflight-id",
                binding.preflight_id.to_string(),
            )
            .header(
                "x-gurine-provider-preflight-digest",
                &binding.preflight_digest,
            )
            .json(&payload)
            .send()
            .await
            .map_err(|_| DeliveryError::Delivery)?;
        if !response.status().is_success() {
            return Err(DeliveryError::Delivery);
        }
        response
            .json::<Response>()
            .await
            .map(|value| value.provider_message_id)
            .map_err(|_| DeliveryError::Delivery)
    }

    async fn send_provider_channel(
        &self,
        message: &EmailMessage,
        channel: &str,
        idempotency_key: &str,
    ) -> Result<String, DeliveryError> {
        let mut endpoint = self.url.clone();
        endpoint.set_path(&format!("/communication/{}", channel.to_ascii_lowercase()));
        let response = self
            .client
            .post(endpoint)
            .header("x-gurine-egress-caller", "notification-worker")
            .json(&ProviderRequest {
                recipient: &message.to,
                subject: &message.subject,
                text_body: &message.text_body,
                idempotency_key,
            })
            .send()
            .await
            .map_err(|_| DeliveryError::Delivery)?;
        if !response.status().is_success() {
            return Err(DeliveryError::Delivery);
        }
        response
            .json::<Response>()
            .await
            .map(|value| value.provider_message_id)
            .map_err(|_| DeliveryError::Delivery)
    }

    pub async fn poll_for_channel_with_binding(
        &self,
        channel: &str,
        provider_message_id: &str,
        binding: &ProviderBinding,
    ) -> Result<ProviderPollReceipt, DeliveryError> {
        if !matches!(channel, "SMS" | "KAKAO" | "TELEGRAM" | "WHATSAPP" | "LINE") {
            return Err(DeliveryError::PollUnsupported);
        }
        let mut endpoint = self.url.clone();
        endpoint.set_path(&format!(
            "/communication/{}/poll",
            channel.to_ascii_lowercase()
        ));
        let response = self
            .client
            .post(endpoint)
            .header("x-gurine-egress-caller", "notification-worker")
            .header("x-gurine-provider-config-id", binding.config_id.to_string())
            .header(
                "x-gurine-provider-config-version",
                binding.config_version.to_string(),
            )
            .header(
                "x-gurine-provider-configuration-digest",
                &binding.configuration_digest,
            )
            .header(
                "x-gurine-provider-preflight-id",
                binding.preflight_id.to_string(),
            )
            .header(
                "x-gurine-provider-preflight-digest",
                &binding.preflight_digest,
            )
            .json(&ProviderPollRequest {
                provider_message_id,
            })
            .send()
            .await
            .map_err(|_| DeliveryError::Delivery)?;
        if response.status().as_u16() == 422 {
            return Err(DeliveryError::PollUnsupported);
        }
        if !response.status().is_success() {
            return Err(DeliveryError::Delivery);
        }
        response
            .json::<ProviderPollReceipt>()
            .await
            .map_err(|_| DeliveryError::Delivery)
    }

    pub async fn preflight_provider_revision(
        &self,
        provider_connection_test_id: Uuid,
        revision: &ProviderRevision,
    ) -> Result<ProviderPreflightReceipt, DeliveryError> {
        let mut endpoint = self.url.clone();
        endpoint.set_path("/communication/preflight");
        endpoint.set_query(None);
        let response = self
            .client
            .post(endpoint)
            .header("x-gurine-egress-caller", "notification-worker")
            .header(
                "x-gurine-provider-config-id",
                revision.config_id.to_string(),
            )
            .header(
                "x-gurine-provider-config-version",
                revision.config_version.to_string(),
            )
            .header(
                "x-gurine-provider-configuration-digest",
                &revision.configuration_digest,
            )
            .json(&ProviderPreflightRequest {
                provider_connection_test_id,
            })
            .send()
            .await
            .map_err(|_| DeliveryError::Delivery)?;
        if !response.status().is_success() {
            return Err(DeliveryError::Delivery);
        }
        response
            .json::<ProviderPreflightReceipt>()
            .await
            .map_err(|_| DeliveryError::Delivery)
    }

    pub async fn send(&self, message: &EmailMessage) -> Result<String, DeliveryError> {
        self.send_for_channel(message, "EMAIL").await
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ProviderRequest<'a> {
    recipient: &'a str,
    subject: &'a str,
    text_body: &'a str,
    idempotency_key: &'a str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ProviderPollRequest<'a> {
    provider_message_id: &'a str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ProviderPreflightRequest {
    provider_connection_test_id: Uuid,
}

fn sha256_hex(value: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let mut digest = Sha256::new();
    digest.update(value);
    format!("{:x}", digest.finalize())
}
