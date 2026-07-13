use std::sync::atomic::{AtomicU32, Ordering};

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chacha20poly1305::{
    ChaCha20Poly1305, Key, Nonce,
    aead::{Aead, KeyInit, Payload},
};
use thiserror::Error;
use zeroize::Zeroize;

use crate::assertion::canonical::key_id;

const MAX_ENCRYPTIONS_PER_KEY: u32 = 16_777_216;

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum EnvelopeError {
    #[error("envelope format is invalid")]
    InvalidEnvelope,
    #[error("envelope version is unsupported")]
    UnsupportedVersion,
    #[error("envelope key id is unknown")]
    UnknownKeyId,
    #[error("authenticated decryption failed")]
    AuthenticatedDecryptionFailed,
    #[error("encryption limit for this key has been reached")]
    KeyUsageLimit,
    #[error("operating system randomness is unavailable")]
    RandomnessUnavailable,
}

pub struct EnvelopeKey {
    bytes: [u8; 32],
    kid: String,
    encryptions: AtomicU32,
}

impl EnvelopeKey {
    pub fn new(bytes: [u8; 32]) -> Self {
        let kid = key_id(&bytes);
        Self {
            bytes,
            kid,
            encryptions: AtomicU32::new(0),
        }
    }
}

impl Drop for EnvelopeKey {
    fn drop(&mut self) {
        self.bytes.zeroize();
    }
}

pub struct EnvelopeKeyRing {
    pub current: EnvelopeKey,
    pub previous: Option<EnvelopeKey>,
}

pub fn encrypt(
    prefix: &str,
    key: &EnvelopeKey,
    aad_parts: &[&str],
    plaintext: &[u8],
) -> Result<String, EnvelopeError> {
    let mut nonce = [0_u8; 12];
    getrandom::fill(&mut nonce).map_err(|_| EnvelopeError::RandomnessUnavailable)?;
    encrypt_with_nonce(prefix, key, aad_parts, plaintext, nonce)
}

pub fn encrypt_with_nonce(
    prefix: &str,
    key: &EnvelopeKey,
    aad_parts: &[&str],
    plaintext: &[u8],
    nonce: [u8; 12],
) -> Result<String, EnvelopeError> {
    key.encryptions
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
            (count < MAX_ENCRYPTIONS_PER_KEY).then_some(count + 1)
        })
        .map_err(|_| EnvelopeError::KeyUsageLimit)?;
    let key_ref: &Key = (&key.bytes).into();
    let nonce_ref: &Nonce = (&nonce).into();
    let cipher = ChaCha20Poly1305::new(key_ref);
    let aad = aad_parts.join("\0");
    let ciphertext = cipher
        .encrypt(
            nonce_ref,
            Payload {
                msg: plaintext,
                aad: aad.as_bytes(),
            },
        )
        .map_err(|_| EnvelopeError::AuthenticatedDecryptionFailed)?;
    Ok(format!(
        "{prefix}.{}.{}.{}",
        key.kid,
        URL_SAFE_NO_PAD.encode(nonce),
        URL_SAFE_NO_PAD.encode(ciphertext)
    ))
}

pub fn decrypt(
    expected_prefix: &str,
    keys: &EnvelopeKeyRing,
    aad_parts: &[&str],
    token: &str,
) -> Result<Vec<u8>, EnvelopeError> {
    let mut segments = token.split('.');
    let prefix = segments.next().ok_or(EnvelopeError::InvalidEnvelope)?;
    let kid = segments.next().ok_or(EnvelopeError::InvalidEnvelope)?;
    let nonce_segment = segments.next().ok_or(EnvelopeError::InvalidEnvelope)?;
    let ciphertext_segment = segments.next().ok_or(EnvelopeError::InvalidEnvelope)?;
    if segments.next().is_some() {
        return Err(EnvelopeError::InvalidEnvelope);
    }
    if prefix != expected_prefix {
        return Err(EnvelopeError::UnsupportedVersion);
    }
    let key = if keys.current.kid == kid {
        &keys.current
    } else {
        keys.previous
            .as_ref()
            .filter(|key| key.kid == kid)
            .ok_or(EnvelopeError::UnknownKeyId)?
    };
    let nonce = URL_SAFE_NO_PAD
        .decode(nonce_segment)
        .map_err(|_| EnvelopeError::InvalidEnvelope)?;
    let ciphertext = URL_SAFE_NO_PAD
        .decode(ciphertext_segment)
        .map_err(|_| EnvelopeError::InvalidEnvelope)?;
    let nonce_bytes: [u8; 12] = nonce
        .as_slice()
        .try_into()
        .map_err(|_| EnvelopeError::InvalidEnvelope)?;
    if ciphertext.len() < 16 {
        return Err(EnvelopeError::InvalidEnvelope);
    }
    let key_ref: &Key = (&key.bytes).into();
    let nonce_ref: &Nonce = (&nonce_bytes).into();
    let cipher = ChaCha20Poly1305::new(key_ref);
    let aad = aad_parts.join("\0");
    cipher
        .decrypt(
            nonce_ref,
            Payload {
                msg: &ciphertext,
                aad: aad.as_bytes(),
            },
        )
        .map_err(|_| EnvelopeError::AuthenticatedDecryptionFailed)
}
