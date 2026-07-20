//! Provider credential resolution bound to the immutable provider revision.
//!
//! The database stores only an opaque, version-qualified resolver reference.
//! The corresponding token is injected into the egress process by the same
//! deployment secret resolver.  Both the reference and the source marker are
//! compared before the token is handed to an adapter; a missing or stale
//! marker fails closed.  No token is ever returned in a `Debug` value or
//! evidence record.

use sha2::{Digest, Sha256};
use thiserror::Error;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum CredentialResolutionError {
    #[error("provider credential secret reference is missing")]
    MissingReference,
    #[error("provider credential secret reference is not version pinned")]
    InvalidReference,
    #[error("provider credential source marker is missing")]
    MissingSourceMarker,
    #[error("provider credential source marker does not match the approved reference")]
    SourceMismatch,
    #[error("provider credential token is missing")]
    MissingToken,
}

/// A resolved credential intentionally exposes only the token-consuming
/// operation and a non-secret digest for diagnostics/evidence.
pub struct ResolvedCredential {
    token: String,
    reference_digest: String,
}

impl std::fmt::Debug for ResolvedCredential {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ResolvedCredential")
            .field("token", &"<redacted>")
            .field("reference_digest", &self.reference_digest)
            .finish()
    }
}

impl ResolvedCredential {
    pub fn token(&self) -> &str {
        &self.token
    }

    pub fn reference_digest(&self) -> &str {
        &self.reference_digest
    }
}

/// Resolve a channel credential from the process environment.
///
/// `TOKEN_SECRET_REFERENCE` is the deployment's selected immutable resolver
/// identifier. `TOKEN_SOURCE` is emitted by the secret-manager sidecar when it
/// materialises `TOKEN`; requiring both to be equal prevents a token from an
/// older rotation from being paired with a current provider revision.
pub fn resolve_from_environment(
    channel: &str,
) -> Result<ResolvedCredential, CredentialResolutionError> {
    let prefix = format!("COMMUNICATION_{}_", channel);
    let reference = std::env::var(format!("{prefix}TOKEN_SECRET_REFERENCE"))
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or(CredentialResolutionError::MissingReference)?;
    let source = std::env::var(format!("{prefix}TOKEN_SOURCE"))
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or(CredentialResolutionError::MissingSourceMarker)?;
    let token = std::env::var(format!("{prefix}TOKEN"))
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or(CredentialResolutionError::MissingToken)?;
    resolve_parts(&reference, &source, &token)
}

pub fn resolve_parts(
    reference: &str,
    source: &str,
    token: &str,
) -> Result<ResolvedCredential, CredentialResolutionError> {
    if !is_version_pinned_reference(reference) {
        return Err(CredentialResolutionError::InvalidReference);
    }
    if source != reference {
        return Err(CredentialResolutionError::SourceMismatch);
    }
    if token.trim().is_empty() {
        return Err(CredentialResolutionError::MissingToken);
    }
    Ok(ResolvedCredential {
        token: token.to_owned(),
        reference_digest: format!("{:x}", Sha256::digest(reference.as_bytes())),
    })
}

/// Validate the authority's opaque, immutable resolver-reference shape.
/// Scheme and provider names remain resolver-specific, while a final `@v...`
/// component is mandatory. Mutable aliases, query/fragment material and
/// plaintext-looking values are rejected.
pub fn is_version_pinned_reference(value: &str) -> bool {
    if value.is_empty()
        || value.len() > 500
        || value.bytes().any(|byte| byte.is_ascii_whitespace())
        || value.contains('?')
        || value.contains('#')
        || !value.contains("://")
    {
        return false;
    }
    let Some((base, suffix)) = value.rsplit_once("@v") else {
        return false;
    };
    if suffix.is_empty()
        || suffix.eq_ignore_ascii_case("latest")
        || suffix.eq_ignore_ascii_case("current")
        || !suffix
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return false;
    }
    let body = value
        .split_once("://")
        .map(|(_, rest)| rest)
        .unwrap_or_default();
    !body.is_empty()
        && !body.starts_with('/')
        && !base.contains('@')
        && !body.to_ascii_lowercase().contains("latest")
        && !body.to_ascii_lowercase().contains("current")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_immutable_resolver_reference() {
        assert!(is_version_pinned_reference(
            "vault://prod/telegram-token@v20260719"
        ));
    }

    #[test]
    fn rejects_mutable_aliases_and_plaintext() {
        for value in [
            "vault://prod/telegram-token@latest",
            "vault://prod/telegram-token@vcurrent",
            "telegram-token",
            "s3://prod/telegram-token@v1?raw=true",
            "token-value@v1",
        ] {
            assert!(!is_version_pinned_reference(value), "{value}");
        }
    }

    #[test]
    fn resolver_requires_matching_source_marker() {
        assert_eq!(
            resolve_parts(
                "vault://prod/t@v1",
                "vault://prod/t@v0",
                "redacted-test-token"
            )
            .unwrap_err(),
            CredentialResolutionError::SourceMismatch
        );
        let resolved = resolve_parts(
            "vault://prod/t@v1",
            "vault://prod/t@v1",
            "redacted-test-token",
        )
        .expect("matching source");
        assert_eq!(resolved.token(), "redacted-test-token");
        assert_eq!(resolved.reference_digest().len(), 64);
    }
}
