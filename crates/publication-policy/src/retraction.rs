#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Retraction {
    pub tombstone_title: String,
    pub public_reason: String,
    pub superseded_revision: u32,
}

pub fn create(title: String, reason: String, superseded_revision: u32) -> Option<Retraction> {
    if title.trim().is_empty() || reason.trim().is_empty() || superseded_revision == 0 {
        return None;
    }
    Some(Retraction {
        tombstone_title: title,
        public_reason: reason,
        superseded_revision,
    })
}
