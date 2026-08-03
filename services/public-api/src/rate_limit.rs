use std::{
    collections::HashMap,
    net::IpAddr,
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};

use sha2::{Digest, Sha256};

const PUBLIC_READ_ATTEMPTS_PER_MINUTE: u32 = 6_000;
const WINDOW_SECONDS: u64 = 60;
const MAX_BUCKETS: usize = 50_000;

#[derive(Clone)]
pub struct PublicReadRateLimiter {
    inner: Arc<Mutex<HashMap<[u8; 32], Bucket>>>,
    attempts: u32,
    window_seconds: u64,
    max_buckets: usize,
}

#[derive(Clone, Copy)]
struct Bucket {
    count: u32,
    reset_at: u64,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Decision {
    Allowed,
    Limited { retry_after_seconds: u64 },
}

#[derive(Debug, PartialEq, Eq)]
pub struct RateLimitUnavailable;

impl Default for PublicReadRateLimiter {
    fn default() -> Self {
        Self::new(PUBLIC_READ_ATTEMPTS_PER_MINUTE, WINDOW_SECONDS, MAX_BUCKETS)
    }
}

impl PublicReadRateLimiter {
    fn new(attempts: u32, window_seconds: u64, max_buckets: usize) -> Self {
        Self {
            inner: Arc::new(Mutex::new(HashMap::new())),
            attempts,
            window_seconds,
            max_buckets,
        }
    }

    pub fn check(&self, address: IpAddr) -> Result<Decision, RateLimitUnavailable> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| RateLimitUnavailable)?
            .as_secs();
        self.check_at(address, now)
    }

    fn check_at(&self, address: IpAddr, now: u64) -> Result<Decision, RateLimitUnavailable> {
        let key: [u8; 32] = Sha256::digest(address.to_string().as_bytes()).into();
        let mut buckets = self.inner.lock().map_err(|_| RateLimitUnavailable)?;
        if buckets.len() >= self.max_buckets {
            buckets.retain(|_, bucket| bucket.reset_at > now);
        }
        if !buckets.contains_key(&key) && buckets.len() >= self.max_buckets {
            return Ok(Decision::Limited {
                retry_after_seconds: self.window_seconds,
            });
        }
        let bucket = buckets.entry(key).or_insert(Bucket {
            count: 0,
            reset_at: now.saturating_add(self.window_seconds),
        });
        if bucket.reset_at <= now {
            *bucket = Bucket {
                count: 0,
                reset_at: now.saturating_add(self.window_seconds),
            };
        }
        if bucket.count >= self.attempts {
            return Ok(Decision::Limited {
                retry_after_seconds: bucket.reset_at.saturating_sub(now).max(1),
            });
        }
        bucket.count = bucket.count.saturating_add(1);
        Ok(Decision::Allowed)
    }
}

#[cfg(test)]
mod tests {
    use std::net::{IpAddr, Ipv4Addr};

    use super::{Decision, PublicReadRateLimiter};

    #[test]
    fn limits_each_address_and_reopens_after_the_window() {
        let limiter = PublicReadRateLimiter::new(2, 60, 100);
        let first = IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10));
        let second = IpAddr::V4(Ipv4Addr::new(192, 0, 2, 11));
        assert_eq!(limiter.check_at(first, 100), Ok(Decision::Allowed));
        assert_eq!(limiter.check_at(first, 101), Ok(Decision::Allowed));
        assert_eq!(
            limiter.check_at(first, 102),
            Ok(Decision::Limited {
                retry_after_seconds: 58
            })
        );
        assert_eq!(limiter.check_at(second, 102), Ok(Decision::Allowed));
        assert_eq!(limiter.check_at(first, 160), Ok(Decision::Allowed));
    }
}
