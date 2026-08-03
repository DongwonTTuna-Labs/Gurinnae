#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TransactionIsolation {
    ReadCommitted,
    RepeatableRead,
    Serializable,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TransactionPolicy {
    pub isolation: TransactionIsolation,
    pub retry_on_serialization_failure: bool,
    pub maximum_attempts: u8,
}

impl TransactionPolicy {
    pub const COMMAND: Self = Self {
        isolation: TransactionIsolation::ReadCommitted,
        retry_on_serialization_failure: false,
        maximum_attempts: 1,
    };

    pub const CONCURRENT_COMMAND: Self = Self {
        isolation: TransactionIsolation::Serializable,
        retry_on_serialization_failure: true,
        maximum_attempts: 3,
    };
}
