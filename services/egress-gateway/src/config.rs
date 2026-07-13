use std::{
    collections::{BTreeMap, BTreeSet},
    env,
    path::PathBuf,
};

use thiserror::Error;

#[derive(Clone)]
pub struct Config {
    pub bind: String,
    pub environment: String,
    pub oidc_issuer_host: String,
    pub source_hosts: BTreeSet<String>,
    pub source_host_bindings: BTreeMap<String, String>,
    pub ai_hosts: BTreeSet<String>,
    pub challenge_hosts: BTreeSet<String>,
    pub object_store: Option<ObjectStoreConfig>,
    pub smtp_url: Option<String>,
    pub data_go_kr_service_key: Option<String>,
    pub open_dart_api_key: Option<String>,
    pub openai_api_key: Option<String>,
    pub anthropic_api_key: Option<String>,
    pub google_api_key: Option<String>,
}

#[derive(Clone)]
pub enum ObjectStoreConfig {
    Filesystem(PathBuf),
    S3 {
        bucket: String,
        region: String,
        endpoint: Option<String>,
        access_key_id: String,
        secret_access_key: String,
    },
}

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("required egress configuration is missing")]
    Missing,
    #[error("egress configuration is invalid")]
    Invalid,
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        let environment = env::var("GURINE_ENV").map_err(|_| ConfigError::Missing)?;
        if !matches!(environment.as_str(), "development" | "test" | "production") {
            return Err(ConfigError::Invalid);
        }
        let oidc_issuer_host = env::var("OIDC_ISSUER_HOST").map_err(|_| ConfigError::Missing)?;
        let bind = env::var("HTTP_BIND").unwrap_or_else(|_| "0.0.0.0:8090".to_owned());
        if bind.trim().is_empty() || oidc_issuer_host.trim().is_empty() {
            return Err(ConfigError::Invalid);
        }
        let mut source_hosts = ["apis.data.go.kr", "opendart.fss.or.kr"]
            .into_iter()
            .map(str::to_owned)
            .collect::<BTreeSet<_>>();
        let mut source_host_bindings = BTreeMap::from([
            ("koneps-contracts".to_owned(), "apis.data.go.kr".to_owned()),
            ("koneps-notices".to_owned(), "apis.data.go.kr".to_owned()),
            ("open-dart".to_owned(), "opendart.fss.or.kr".to_owned()),
        ]);
        for (name, source_id) in [
            ("ALIO_HOST", "alio"),
            ("LOCAL_FINANCE_HOST", "local-finance"),
            ("AUDIT_RESULTS_HOST", "audit-results"),
        ] {
            if let Some(host) = optional(name) {
                let host = normalize_host(&host)?;
                source_hosts.insert(host.clone());
                source_host_bindings.insert(source_id.to_owned(), host);
            }
        }
        let ai_hosts = optional("AI_PROVIDER_HOSTS")
            .unwrap_or_default()
            .split(',')
            .map(str::trim)
            .filter(|host| !host.is_empty())
            .map(normalize_host)
            .collect::<Result<BTreeSet<_>, _>>()?;
        let mut challenge_hosts = ["challenges.cloudflare.com", "api.hcaptcha.com"]
            .into_iter()
            .map(str::to_owned)
            .collect::<BTreeSet<_>>();
        if matches!(environment.as_str(), "development" | "test") {
            for host in optional("CHALLENGE_PROVIDER_HOSTS")
                .unwrap_or_default()
                .split(',')
                .map(str::trim)
                .filter(|host| !host.is_empty())
            {
                challenge_hosts.insert(normalize_host(host)?);
            }
        }
        let object_store = match optional("OBJECT_STORE_ADAPTER").as_deref() {
            None => None,
            Some("filesystem") if matches!(environment.as_str(), "development" | "test") => {
                Some(ObjectStoreConfig::Filesystem(PathBuf::from(
                    optional("OBJECT_STORE_FILESYSTEM_ROOT")
                        .unwrap_or_else(|| "/var/lib/gurine-objects".to_owned()),
                )))
            }
            Some("s3" | "egress") => Some(ObjectStoreConfig::S3 {
                bucket: required("OBJECT_STORE_ATTACHMENT_BUCKET")?,
                region: required("OBJECT_STORE_REGION")?,
                endpoint: optional("OBJECT_STORE_ENDPOINT"),
                access_key_id: required("OBJECT_STORE_ACCESS_KEY_ID")?,
                secret_access_key: required("OBJECT_STORE_SECRET_ACCESS_KEY")?,
            }),
            Some(_) => return Err(ConfigError::Invalid),
        };
        let smtp_url = optional("SMTP_URL");
        if let Some(url) = smtp_url.as_deref() {
            let parsed = url::Url::parse(url).map_err(|_| ConfigError::Invalid)?;
            if !matches!(parsed.scheme(), "smtp" | "smtps")
                || parsed.host_str().is_none()
                || optional("SMTP_HOST").is_some_and(|host| {
                    parsed
                        .host_str()
                        .is_none_or(|value| !value.eq_ignore_ascii_case(&host))
                })
            {
                return Err(ConfigError::Invalid);
            }
        }
        Ok(Self {
            bind,
            environment,
            oidc_issuer_host: normalize_host(&oidc_issuer_host)?,
            source_hosts,
            source_host_bindings,
            ai_hosts,
            challenge_hosts,
            object_store,
            smtp_url,
            data_go_kr_service_key: optional("DATA_GO_KR_SERVICE_KEY"),
            open_dart_api_key: optional("OPEN_DART_API_KEY"),
            openai_api_key: optional("OPENAI_API_KEY"),
            anthropic_api_key: optional("ANTHROPIC_API_KEY"),
            google_api_key: optional("GOOGLE_GENERATIVE_AI_API_KEY"),
        })
    }

    pub fn development(&self) -> bool {
        matches!(self.environment.as_str(), "development" | "test")
    }
}

fn required(name: &'static str) -> Result<String, ConfigError> {
    optional(name).ok_or(ConfigError::Missing)
}

fn optional(name: &'static str) -> Option<String> {
    env::var(name).ok().filter(|value| !value.trim().is_empty())
}

fn normalize_host(value: &str) -> Result<String, ConfigError> {
    let host = value.trim().trim_end_matches('.').to_ascii_lowercase();
    if host.is_empty()
        || host.parse::<std::net::IpAddr>().is_ok()
        || !host
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-'))
    {
        Err(ConfigError::Invalid)
    } else {
        Ok(host)
    }
}
