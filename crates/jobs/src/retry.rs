use std::time::Duration;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RetryPolicy {
    pub maximum_attempts: u32,
    pub initial_delay: Duration,
    pub maximum_delay: Duration,
}

impl RetryPolicy {
    pub fn delay(self, attempt: u32) -> Option<Duration> {
        if attempt == 0 || attempt >= self.maximum_attempts {
            return None;
        }
        let exponent = attempt.saturating_sub(1).min(31);
        let multiplier = 1_u32 << exponent;
        self.initial_delay
            .checked_mul(multiplier)
            .map(|delay| delay.min(self.maximum_delay))
    }
}
