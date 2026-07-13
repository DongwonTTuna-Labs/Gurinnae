use sqlx::PgPool;

use crate::rate_limit::PublicReadRateLimiter;

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    pub public_read_rate_limiter: PublicReadRateLimiter,
}

impl AppState {
    pub fn new(pool: PgPool) -> Self {
        Self {
            pool,
            public_read_rate_limiter: PublicReadRateLimiter::default(),
        }
    }
}
