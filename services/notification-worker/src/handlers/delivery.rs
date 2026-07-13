use std::{fs::OpenOptions, io::Write, os::unix::fs::OpenOptionsExt, path::PathBuf};

use gurine_email::port::EmailMessage;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use url::Url;

#[derive(Clone)]
pub struct SmtpGateway {
    client: reqwest::Client,
    url: Url,
}

#[derive(Clone)]
pub struct FileGateway {
    outbox: PathBuf,
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
}

#[derive(Serialize)]
struct Request<'a> {
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

    pub async fn send(&self, message: &EmailMessage) -> Result<String, DeliveryError> {
        let response = self
            .client
            .post(self.url.clone())
            .header("x-gurine-egress-caller", "notification-worker")
            .json(&Request {
                from: &message.from,
                to: &message.to,
                subject: &message.subject,
                text_body: &message.text_body,
                html_body: &message.html_body,
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

    async fn send(&self, message: &EmailMessage) -> Result<String, DeliveryError> {
        message.build().map_err(|_| DeliveryError::Delivery)?;
        let outbox = self.outbox.clone();
        let message = message.clone();
        tokio::task::spawn_blocking(move || persist_message(outbox, &message))
            .await
            .map_err(|_| DeliveryError::Delivery)?
    }
}

impl DeliveryGateway {
    pub async fn send(&self, message: &EmailMessage) -> Result<String, DeliveryError> {
        match self {
            Self::File(gateway) => gateway.send(message).await,
            Self::Smtp(gateway) => gateway.send(message).await,
        }
    }
}

fn persist_message(outbox: PathBuf, message: &EmailMessage) -> Result<String, DeliveryError> {
    let id = uuid::Uuid::new_v4();
    let provider_message_id = format!("file:{id}");
    let final_path = outbox.join(format!("{id}.json"));
    let temporary_path = outbox.join(format!(".{id}.tmp"));
    let bytes = serde_json::to_vec_pretty(&FileEnvelope {
        provider_message_id: &provider_message_id,
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
