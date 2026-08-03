use std::{fs::OpenOptions, io::Write, os::unix::fs::OpenOptionsExt, path::PathBuf};

use gurine_email::port::EmailMessage;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use url::Url;
use uuid::Uuid;

#[derive(Clone)]
pub struct SmtpGateway {
    pub(super) client: reqwest::Client,
    pub(super) url: Url,
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

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderPollReceipt {
    pub provider_message_id: String,
    pub asserted_state: String,
    pub provider_evidence_digest: String,
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
