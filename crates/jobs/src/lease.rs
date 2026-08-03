use time::OffsetDateTime;
use uuid::Uuid;

use crate::fencing::Fence;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct JobLease {
    pub job_id: Uuid,
    pub worker_id: String,
    pub fence: Fence,
    pub expires_at: OffsetDateTime,
}

impl JobLease {
    pub fn active_at(&self, now: OffsetDateTime) -> bool {
        !self.worker_id.is_empty() && self.fence.fencing_token > 0 && now < self.expires_at
    }
}
