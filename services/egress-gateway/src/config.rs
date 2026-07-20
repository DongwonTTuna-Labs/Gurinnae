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
    pub public_research_hosts: BTreeSet<String>,
    pub ai_hosts: BTreeSet<String>,
    pub challenge_hosts: BTreeSet<String>,
    pub object_store: Option<ObjectStoreConfig>,
    pub smtp_url: Option<String>,
    pub data_go_kr_service_key: Option<String>,
    pub open_dart_api_key: Option<String>,
    pub brave_search_api_key: Option<String>,
    pub openai_api_key: Option<String>,
    pub anthropic_api_key: Option<String>,
    pub google_api_key: Option<String>,
    /// Database read path used for durable AI/communication kill-switch
    /// enforcement.  Production refuses to start without it.
    pub database_url: Option<String>,
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
        let (environment, bind, oidc_issuer_host) = base_environment()?;
        let (source_hosts, source_host_bindings, public_research_hosts) = source_config()?;
        let ai_hosts = host_list("AI_PROVIDER_HOSTS")?;
        let challenge_hosts = challenge_config(&environment)?;
        let object_store = object_store_config(&environment)?;
        let smtp_url = smtp_config()?;
        let database_url = optional("EGRESS_DATABASE_URL");
        if environment == "production" && database_url.is_none() {
            return Err(ConfigError::Missing);
        }
        Ok(Self {
            bind,
            environment,
            oidc_issuer_host: normalize_host(&oidc_issuer_host)?,
            source_hosts,
            source_host_bindings,
            public_research_hosts,
            ai_hosts,
            challenge_hosts,
            object_store,
            smtp_url,
            data_go_kr_service_key: optional("DATA_GO_KR_SERVICE_KEY"),
            open_dart_api_key: optional("OPEN_DART_API_KEY"),
            brave_search_api_key: optional("BRAVE_SEARCH_API_KEY"),
            openai_api_key: optional("OPENAI_API_KEY"),
            anthropic_api_key: optional("ANTHROPIC_API_KEY"),
            google_api_key: optional("GOOGLE_GENERATIVE_AI_API_KEY"),
            database_url,
        })
    }

    pub fn development(&self) -> bool {
        matches!(self.environment.as_str(), "development" | "test")
    }
}

fn base_environment() -> Result<(String, String, String), ConfigError> {
    let environment = env::var("GURINE_ENV").map_err(|_| ConfigError::Missing)?;
    if !matches!(environment.as_str(), "development" | "test" | "production") {
        return Err(ConfigError::Invalid);
    }
    let oidc = env::var("OIDC_ISSUER_HOST").map_err(|_| ConfigError::Missing)?;
    let bind = env::var("HTTP_BIND").unwrap_or_else(|_| "0.0.0.0:8090".to_owned());
    if bind.trim().is_empty() || oidc.trim().is_empty() {
        return Err(ConfigError::Invalid);
    }
    Ok((environment, bind, normalize_host(&oidc)?))
}

#[expect(
    clippy::type_complexity,
    reason = "the closed source policy triple is consumed atomically by configuration"
)]
fn source_config()
-> Result<(BTreeSet<String>, BTreeMap<String, String>, BTreeSet<String>), ConfigError> {
    let mut hosts = BTreeSet::from([
        "apis.data.go.kr".to_owned(),
        "opendart.fss.or.kr".to_owned(),
        "api.search.brave.com".to_owned(),
    ]);
    let mut bindings = BTreeMap::from([
        ("koneps-contracts".to_owned(), "apis.data.go.kr".to_owned()),
        ("koneps-notices".to_owned(), "apis.data.go.kr".to_owned()),
        ("open-dart".to_owned(), "opendart.fss.or.kr".to_owned()),
        (
            "brave-search-web-v1".to_owned(),
            "api.search.brave.com".to_owned(),
        ),
        ("public-research".to_owned(), "*".to_owned()),
    ]);
    let public_research_hosts = host_list("PUBLIC_RESEARCH_HOSTS")?;
    hosts.extend(public_research_hosts.iter().cloned());
    for (name, source_id) in [
        ("ALIO_HOST", "alio"),
        ("LOCAL_FINANCE_HOST", "local-finance"),
        ("AUDIT_RESULTS_HOST", "audit-results"),
    ] {
        if let Some(host) = optional(name) {
            let host = normalize_host(&host)?;
            hosts.insert(host.clone());
            bindings.insert(source_id.to_owned(), host);
        }
    }
    Ok((hosts, bindings, public_research_hosts))
}

fn host_list(name: &'static str) -> Result<BTreeSet<String>, ConfigError> {
    optional(name)
        .unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|host| !host.is_empty())
        .map(normalize_host)
        .collect()
}

fn challenge_config(environment: &str) -> Result<BTreeSet<String>, ConfigError> {
    let mut hosts = BTreeSet::from([
        "challenges.cloudflare.com".to_owned(),
        "api.hcaptcha.com".to_owned(),
    ]);
    if matches!(environment, "development" | "test") {
        hosts.extend(host_list("CHALLENGE_PROVIDER_HOSTS")?);
    }
    Ok(hosts)
}

fn object_store_config(environment: &str) -> Result<Option<ObjectStoreConfig>, ConfigError> {
    match optional("OBJECT_STORE_ADAPTER").as_deref() {
        None => Ok(None),
        Some("filesystem") if matches!(environment, "development" | "test") => {
            Ok(Some(ObjectStoreConfig::Filesystem(PathBuf::from(
                optional("OBJECT_STORE_FILESYSTEM_ROOT")
                    .unwrap_or_else(|| "/var/lib/gurine-objects".to_owned()),
            ))))
        }
        Some("s3" | "egress") => Ok(Some(ObjectStoreConfig::S3 {
            bucket: required("OBJECT_STORE_ATTACHMENT_BUCKET")?,
            region: required("OBJECT_STORE_REGION")?,
            endpoint: optional("OBJECT_STORE_ENDPOINT"),
            access_key_id: required("OBJECT_STORE_ACCESS_KEY_ID")?,
            secret_access_key: required("OBJECT_STORE_SECRET_ACCESS_KEY")?,
        })),
        Some(_) => Err(ConfigError::Invalid),
    }
}

fn smtp_config() -> Result<Option<String>, ConfigError> {
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
    Ok(smtp_url)
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
