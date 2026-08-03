use time::OffsetDateTime;
use uuid::Uuid;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DeliveryStatus {
    Queued,
    Sending,
    Delivered,
    Bounced,
    Failed,
    Suppressed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EmailDelivery {
    pub id: Uuid,
    pub message_type: String,
    pub recipient_hash: String,
    pub template_version: String,
    pub status: DeliveryStatus,
    pub attempt_count: u32,
    pub provider_message_id: Option<String>,
    pub delivered_at: Option<OffsetDateTime>,
}

impl EmailDelivery {
    pub fn begin_attempt(&mut self) -> bool {
        if !matches!(self.status, DeliveryStatus::Queued | DeliveryStatus::Failed) {
            return false;
        }
        self.status = DeliveryStatus::Sending;
        self.attempt_count += 1;
        true
    }

    pub fn delivered(&mut self, provider_message_id: String, at: OffsetDateTime) -> bool {
        if self.status != DeliveryStatus::Sending {
            return false;
        }
        self.status = DeliveryStatus::Delivered;
        self.provider_message_id = Some(provider_message_id);
        self.delivered_at = Some(at);
        true
    }
}
