use std::{env, io};

pub struct Config {
    pub bind: String,
    pub database_url: String,
}

impl Config {
    pub fn from_env(default_bind: &str) -> Result<Self, io::Error> {
        let bind = env::var("HTTP_BIND").unwrap_or_else(|_| default_bind.to_owned());
        if bind.trim().is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "HTTP_BIND is empty",
            ));
        }
        let database_url = env::var("PUBLIC_DATABASE_URL").map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "PUBLIC_DATABASE_URL is missing",
            )
        })?;
        if database_url.trim().is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "PUBLIC_DATABASE_URL is empty",
            ));
        }
        Ok(Self { bind, database_url })
    }
}
