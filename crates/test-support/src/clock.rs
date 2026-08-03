use std::sync::Mutex;

use gurine_application::ports::Clock;
use time::{Duration, OffsetDateTime};

pub struct TestClock {
    now: Mutex<OffsetDateTime>,
}

impl TestClock {
    pub fn new(now: OffsetDateTime) -> Self {
        Self {
            now: Mutex::new(now),
        }
    }

    pub fn advance(&self, duration: Duration) -> bool {
        self.now.lock().map(|mut now| *now += duration).is_ok()
    }
}

impl Clock for TestClock {
    fn now(&self) -> OffsetDateTime {
        self.now
            .lock()
            .map(|now| *now)
            .unwrap_or(OffsetDateTime::UNIX_EPOCH)
    }
}
