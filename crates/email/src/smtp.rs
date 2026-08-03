use lettre::{
    AsyncSmtpTransport, AsyncTransport, Tokio1Executor,
    transport::smtp::authentication::Credentials,
};

use crate::port::{EmailError, EmailMessage};

pub struct SmtpConfig<'a> {
    pub relay_host: &'a str,
    pub port: u16,
    pub username: &'a str,
    pub password: &'a str,
}

pub struct SmtpSender {
    transport: AsyncSmtpTransport<Tokio1Executor>,
}

impl SmtpSender {
    pub fn from_url(url: &str) -> Result<Self, EmailError> {
        if !(url.starts_with("smtp://") || url.starts_with("smtps://")) {
            return Err(EmailError::InvalidSmtpConfiguration);
        }
        let transport = AsyncSmtpTransport::<Tokio1Executor>::from_url(url)
            .map_err(|_| EmailError::InvalidSmtpConfiguration)?
            .build();
        Ok(Self { transport })
    }

    pub fn new(config: SmtpConfig<'_>) -> Result<Self, EmailError> {
        if config.relay_host.is_empty()
            || config.port == 0
            || config.username.is_empty()
            || config.password.is_empty()
        {
            return Err(EmailError::InvalidSmtpConfiguration);
        }
        let transport = AsyncSmtpTransport::<Tokio1Executor>::relay(config.relay_host)
            .map_err(|_| EmailError::InvalidSmtpConfiguration)?
            .port(config.port)
            .credentials(Credentials::new(
                config.username.to_owned(),
                config.password.to_owned(),
            ))
            .build();
        Ok(Self { transport })
    }

    pub async fn send(&self, message: &EmailMessage) -> Result<String, EmailError> {
        let response = self
            .transport
            .send(message.build()?)
            .await
            .map_err(|_| EmailError::DeliveryFailed)?;
        Ok(response.message().collect::<Vec<_>>().join(" "))
    }
}
