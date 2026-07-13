use std::sync::atomic::{AtomicU64, Ordering};

#[derive(Default)]
pub struct ServiceMetrics {
    requests: AtomicU64,
    failures: AtomicU64,
    jobs_completed: AtomicU64,
    jobs_failed: AtomicU64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct MetricsSnapshot {
    pub requests: u64,
    pub failures: u64,
    pub jobs_completed: u64,
    pub jobs_failed: u64,
}

impl ServiceMetrics {
    pub fn record_request(&self, succeeded: bool) {
        self.requests.fetch_add(1, Ordering::Relaxed);
        if !succeeded {
            self.failures.fetch_add(1, Ordering::Relaxed);
        }
    }

    pub fn record_job(&self, succeeded: bool) {
        if succeeded {
            self.jobs_completed.fetch_add(1, Ordering::Relaxed);
        } else {
            self.jobs_failed.fetch_add(1, Ordering::Relaxed);
        }
    }

    pub fn snapshot(&self) -> MetricsSnapshot {
        MetricsSnapshot {
            requests: self.requests.load(Ordering::Relaxed),
            failures: self.failures.load(Ordering::Relaxed),
            jobs_completed: self.jobs_completed.load(Ordering::Relaxed),
            jobs_failed: self.jobs_failed.load(Ordering::Relaxed),
        }
    }
}
