use lettre::{
    Message,
    message::{Mailbox, MultiPart, SinglePart, header::ContentType},
};
use thiserror::Error;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EmailMessage {
    pub from: String,
    pub to: String,
    pub subject: String,
    pub text_body: String,
    pub html_body: String,
}

#[derive(Debug, Error)]
pub enum EmailError {
    #[error("email address or message is invalid")]
    InvalidMessage,
    #[error("SMTP configuration is invalid")]
    InvalidSmtpConfiguration,
    #[error("SMTP delivery failed")]
    DeliveryFailed,
}

impl EmailMessage {
    pub fn build(&self) -> Result<Message, EmailError> {
        if self.subject.trim().is_empty()
            || self.text_body.trim().is_empty()
            || self.html_body.trim().is_empty()
        {
            return Err(EmailError::InvalidMessage);
        }
        let from = mailbox(&self.from)?;
        let to = mailbox(&self.to)?;
        Message::builder()
            .from(from)
            .to(to)
            .subject(&self.subject)
            .multipart(
                MultiPart::alternative()
                    .singlepart(
                        SinglePart::builder()
                            .header(ContentType::TEXT_PLAIN)
                            .body(self.text_body.clone()),
                    )
                    .singlepart(
                        SinglePart::builder()
                            .header(ContentType::TEXT_HTML)
                            .body(self.html_body.clone()),
                    ),
            )
            .map_err(|_| EmailError::InvalidMessage)
    }
}

fn mailbox(value: &str) -> Result<Mailbox, EmailError> {
    value
        .parse::<Mailbox>()
        .map_err(|_| EmailError::InvalidMessage)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_message_with_unicode_display_name() {
        EmailMessage {
            from: "구린네 <no-reply@gurine.invalid>".to_owned(),
            to: "recipient@gurine.test".to_owned(),
            subject: "초대".to_owned(),
            text_body: "초대되었습니다.".to_owned(),
            html_body: "<p>초대되었습니다.</p>".to_owned(),
        }
        .build()
        .expect("standard mailbox display name must be accepted");
    }

    #[test]
    fn rejects_invalid_mailbox() {
        let result = EmailMessage {
            from: "not-an-address".to_owned(),
            to: "recipient@gurine.test".to_owned(),
            subject: "subject".to_owned(),
            text_body: "text".to_owned(),
            html_body: "<p>text</p>".to_owned(),
        }
        .build();
        assert!(matches!(result, Err(EmailError::InvalidMessage)));
    }
}
