use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use thiserror::Error;
use zeroize::Zeroize;

#[derive(Debug, Error)]
pub enum CsrfError {
    #[error("operating system randomness is unavailable")]
    RandomnessUnavailable,
}

pub struct CsrfToken(String);

impl CsrfToken {
    pub fn generate() -> Result<Self, CsrfError> {
        let mut bytes = [0_u8; 32];
        getrandom::fill(&mut bytes).map_err(|_| CsrfError::RandomnessUnavailable)?;
        let token = URL_SAFE_NO_PAD.encode(bytes);
        bytes.zeroize();
        Ok(Self(token))
    }

    pub fn expose_for_cookie_sealing(&self) -> &str {
        &self.0
    }

    pub fn sha256(&self) -> [u8; 32] {
        Sha256::digest(self.0.as_bytes()).into()
    }
}

impl Drop for CsrfToken {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

pub fn verify(candidate: &str, expected_hash: &[u8; 32]) -> bool {
    let candidate_hash: [u8; 32] = Sha256::digest(candidate.as_bytes()).into();
    bool::from(candidate_hash.ct_eq(expected_hash))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mismatch_fails() -> Result<(), CsrfError> {
        let token = CsrfToken::generate()?;
        assert!(verify(token.expose_for_cookie_sealing(), &token.sha256()));
        assert!(!verify("different", &token.sha256()));
        Ok(())
    }
}
