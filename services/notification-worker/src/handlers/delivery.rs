use std::{fs::OpenOptions, io::Write, os::unix::fs::OpenOptionsExt, path::PathBuf};

use gurine_email::port::EmailMessage;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use url::Url;
use uuid::Uuid;

#[derive(Clone)]
pub struct SmtpGateway {
    client: reqwest::Client,
    url: Url,
}

#[derive(Clone)]
pub struct FileGateway {
    outbox: PathBuf,
}

#[derive(Clone, Debug)]
pub struct ProviderBinding {
    pub config_id: Uuid,
    pub config_version: i64,
    pub configuration_digest: String,
    pub preflight_id: Uuid,
    pub preflight_digest: String,
}

#[derive(Clone, Debug)]
pub struct ProviderRevision {
    pub config_id: Uuid,
    pub config_version: i64,
    pub configuration_digest: String,
}

#[derive(Clone)]
pub enum DeliveryGateway {
    File(FileGateway),
    Smtp(SmtpGateway),
}

#[derive(Debug, Error)]
pub enum DeliveryError {
    #[error("SMTP gateway initialization failed")]
    Initialization,
    #[error("SMTP gateway delivery failed")]
    Delivery,
    #[error("provider status poll is unsupported")]
    PollUnsupported,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderPreflightReceipt {
    pub provider_connection_test_id: Uuid,
    pub provider_config_id: Uuid,
    pub provider_config_version: i64,
    pub receipt_id: Uuid,
    pub receipt_digest: String,
    pub status: String,
}

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

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct FileEnvelope<'a> {
    provider_message_id: &'a str,
    channel: &'a str,
    from: &'a str,
    to: &'a str,
    subject: &'a str,
    text_body: &'a str,
    html_body: &'a str,
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

    async fn send_for_channel_with_binding(
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

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderPollReceipt {
    pub provider_message_id: String,
    pub asserted_state: String,
    pub provider_evidence_digest: String,
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

impl FileGateway {
    pub fn new(outbox: PathBuf) -> Result<Self, DeliveryError> {
        if !outbox.is_absolute() {
            return Err(DeliveryError::Initialization);
        }
        std::fs::create_dir_all(&outbox).map_err(|_| DeliveryError::Initialization)?;
        let metadata = std::fs::metadata(&outbox).map_err(|_| DeliveryError::Initialization)?;
        if !metadata.is_dir() {
            return Err(DeliveryError::Initialization);
        }
        Ok(Self { outbox })
    }

    async fn send_for_channel(
        &self,
        message: &EmailMessage,
        channel: &str,
    ) -> Result<String, DeliveryError> {
        // File mode is an email-only local test adapter.  Persisting a JSON
        // file for Telegram/WhatsApp/LINE/SMS/Kakao would falsely report a
        // provider delivery receipt, so non-email channels fail closed.
        if channel != "EMAIL" {
            return Err(DeliveryError::Delivery);
        }
        message.build().map_err(|_| DeliveryError::Delivery)?;
        let outbox = self.outbox.clone();
        let message = message.clone();
        let channel = channel.to_owned();
        let persisted_channel = channel.clone();
        tokio::task::spawn_blocking(move || persist_message(outbox, &message, &persisted_channel))
            .await
            .map_err(|_| DeliveryError::Delivery)?
    }

    pub async fn send(&self, message: &EmailMessage) -> Result<String, DeliveryError> {
        self.send_for_channel(message, "EMAIL").await
    }
}

impl DeliveryGateway {
    pub async fn send(&self, message: &EmailMessage) -> Result<String, DeliveryError> {
        self.send_for_channel(message, "EMAIL").await
    }

    pub async fn send_for_channel(
        &self,
        message: &EmailMessage,
        channel: &str,
    ) -> Result<String, DeliveryError> {
        match self {
            Self::File(gateway) => gateway.send_for_channel(message, channel).await,
            Self::Smtp(gateway) => gateway.send_for_channel(message, channel).await,
        }
    }

    pub async fn send_for_channel_with_key(
        &self,
        message: &EmailMessage,
        channel: &str,
        idempotency_key: &str,
    ) -> Result<String, DeliveryError> {
        match self {
            Self::File(gateway) => gateway.send_for_channel(message, channel).await,
            Self::Smtp(gateway) => {
                gateway
                    .send_for_channel_with_key(message, channel, idempotency_key)
                    .await
            }
        }
    }

    pub async fn send_for_channel_with_binding(
        &self,
        message: &EmailMessage,
        channel: &str,
        idempotency_key: &str,
        binding: &ProviderBinding,
    ) -> Result<String, DeliveryError> {
        match self {
            Self::File(gateway) => gateway.send_for_channel(message, channel).await,
            Self::Smtp(gateway) => {
                gateway
                    .send_for_channel_with_binding(message, channel, idempotency_key, binding)
                    .await
            }
        }
    }

    pub async fn poll_for_channel_with_binding(
        &self,
        channel: &str,
        provider_message_id: &str,
        binding: &ProviderBinding,
    ) -> Result<ProviderPollReceipt, DeliveryError> {
        match self {
            Self::File(_) => Err(DeliveryError::PollUnsupported),
            Self::Smtp(gateway) => {
                gateway
                    .poll_for_channel_with_binding(channel, provider_message_id, binding)
                    .await
            }
        }
    }

    pub async fn preflight_provider_revision(
        &self,
        provider_connection_test_id: Uuid,
        revision: &ProviderRevision,
    ) -> Result<ProviderPreflightReceipt, DeliveryError> {
        match self {
            Self::File(_) => Err(DeliveryError::Delivery),
            Self::Smtp(gateway) => {
                gateway
                    .preflight_provider_revision(provider_connection_test_id, revision)
                    .await
            }
        }
    }
}

fn persist_message(
    outbox: PathBuf,
    message: &EmailMessage,
    channel: &str,
) -> Result<String, DeliveryError> {
    let id = uuid::Uuid::new_v4();
    let provider_message_id = format!("file:{id}");
    let final_path = outbox.join(format!("{id}.json"));
    let temporary_path = outbox.join(format!(".{id}.tmp"));
    let bytes = serde_json::to_vec_pretty(&FileEnvelope {
        provider_message_id: &provider_message_id,
        channel,
        from: &message.from,
        to: &message.to,
        subject: &message.subject,
        text_body: &message.text_body,
        html_body: &message.html_body,
    })
    .map_err(|_| DeliveryError::Delivery)?;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary_path)
        .map_err(|_| DeliveryError::Delivery)?;
    let result = (|| {
        file.write_all(&bytes)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        std::fs::rename(&temporary_path, &final_path)?;
        OpenOptions::new().read(true).open(&outbox)?.sync_all()?;
        Ok::<(), std::io::Error>(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary_path);
        return Err(DeliveryError::Delivery);
    }
    Ok(provider_message_id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn file_gateway_persists_complete_message_with_private_permissions() {
        use std::os::unix::fs::PermissionsExt;

        let root = std::env::temp_dir().join(format!("gurine-mail-test-{}", uuid::Uuid::new_v4()));
        let gateway = FileGateway::new(root.clone()).expect("file gateway");
        let message = EmailMessage {
            from: "sender@example.com".to_owned(),
            to: "recipient@example.com".to_owned(),
            subject: "subject".to_owned(),
            text_body: "text".to_owned(),
            html_body: "<p>text</p>".to_owned(),
        };
        let provider_id = gateway.send(&message).await.expect("delivery");
        let id = provider_id.strip_prefix("file:").expect("provider prefix");
        let path = root.join(format!("{id}.json"));
        let saved: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&path).expect("saved message"))
                .expect("valid JSON");
        assert_eq!(saved["providerMessageId"], provider_id);
        assert_eq!(saved["to"], message.to);
        assert_eq!(saved["htmlBody"], message.html_body);
        assert_eq!(
            std::fs::metadata(&path)
                .expect("metadata")
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        assert!(std::fs::read_dir(&root).expect("outbox").all(|entry| {
            !entry
                .expect("entry")
                .file_name()
                .to_string_lossy()
                .starts_with('.')
        }));
        std::fs::remove_dir_all(root).expect("cleanup");
    }
}
