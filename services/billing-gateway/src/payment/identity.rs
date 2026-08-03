use gurine_payment_providers::{IdempotencyKey, MerchantOrderId, ProviderKind};
use hmac::{Hmac, Mac};
use sha2::Sha256;
use uuid::Uuid;
use zeroize::Zeroizing;

use crate::digest::Sha256Digest;

use super::model::PaymentRuntimeError;

type HmacSha256 = Hmac<Sha256>;

pub(super) struct FixtureIdentityKey {
    key: Zeroizing<Vec<u8>>,
    key_version: String,
}

pub(super) struct FixtureIdentityKeyring {
    current: FixtureIdentityKey,
    previous: Option<FixtureIdentityKey>,
}

pub(super) struct ProviderIdempotency {
    pub value: IdempotencyKey,
    pub hmac: Sha256Digest,
    pub key_version: String,
}

pub(super) struct FixtureClaimIdentity {
    pub merchant_account_hmac: Sha256Digest,
    pub donor_hmac: Sha256Digest,
    pub donor_group_hmac: Sha256Digest,
    pub key_version: String,
}

pub(super) struct ChargeProviderIdentity {
    pub idempotency: ProviderIdempotency,
    pub merchant_order_id: MerchantOrderId,
    pub merchant_order_hmac: Sha256Digest,
}

impl FixtureIdentityKey {
    pub fn try_new(key: Vec<u8>, key_version: String) -> Result<Self, PaymentRuntimeError> {
        if key.len() < 32 || !valid_key_version(&key_version) {
            return Err(PaymentRuntimeError::InvalidRequest);
        }
        Ok(Self {
            key: Zeroizing::new(key),
            key_version,
        })
    }

    pub fn intent_idempotency(
        &self,
        request_id: Uuid,
        request_digest: &Sha256Digest,
    ) -> Result<ProviderIdempotency, PaymentRuntimeError> {
        let raw = self.derived_uuid(
            b"gurine-donation-binding-idempotency.v1\0",
            &[request_id.as_bytes(), request_digest.as_str().as_bytes()],
        )?;
        self.provider_idempotency(raw)
    }

    pub fn claim_identity(
        &self,
        provider: ProviderKind,
        request_id: Uuid,
    ) -> Result<FixtureClaimIdentity, PaymentRuntimeError> {
        let merchant_account_hmac = self.persisted_hmac(
            b"gurine-test-merchant-account.v1\0",
            provider.as_str().as_bytes(),
        )?;
        let donor_hmac = self.persisted_hmac(b"gurine-test-donor.v1\0", request_id.as_bytes())?;
        let donor_group_hmac =
            self.persisted_hmac(b"gurine-test-donor-group.v1\0", request_id.as_bytes())?;
        Ok(FixtureClaimIdentity {
            merchant_account_hmac,
            donor_hmac,
            donor_group_hmac,
            key_version: self.key_version.clone(),
        })
    }

    pub fn charge_identity(
        &self,
        logical_charge_id: Uuid,
        charge_idempotency_key_sha256: &Sha256Digest,
        job_payload_digest: &Sha256Digest,
    ) -> Result<ChargeProviderIdentity, PaymentRuntimeError> {
        let raw = self.derived_uuid(
            b"gurine-donation-charge-idempotency.v1\0",
            &[
                logical_charge_id.as_bytes(),
                charge_idempotency_key_sha256.as_str().as_bytes(),
            ],
        )?;
        let idempotency = self.provider_idempotency(raw)?;
        let merchant_bytes = self.mac(
            b"gurine-merchant-order-id.v1\0",
            &[
                logical_charge_id.as_bytes(),
                job_payload_digest.as_str().as_bytes(),
            ],
        )?;
        let merchant_order_id =
            MerchantOrderId::try_new(format!("gdn_test_{}", &hex_lower(&merchant_bytes)[..40]))?;
        let merchant_order_hmac = self.persisted_hmac(
            b"gurine-merchant-order-id-hmac.v1\0",
            merchant_order_id.as_str().as_bytes(),
        )?;
        Ok(ChargeProviderIdentity {
            idempotency,
            merchant_order_id,
            merchant_order_hmac,
        })
    }

    fn provider_idempotency(&self, raw: Uuid) -> Result<ProviderIdempotency, PaymentRuntimeError> {
        let hmac = self.persisted_hmac(b"gurine-provider-idempotency-hmac.v1\0", raw.as_bytes())?;
        Ok(ProviderIdempotency {
            value: IdempotencyKey::new(raw),
            hmac,
            key_version: self.key_version.clone(),
        })
    }

    fn derived_uuid(&self, domain: &[u8], values: &[&[u8]]) -> Result<Uuid, PaymentRuntimeError> {
        let digest = self.mac(domain, values)?;
        let mut bytes = [0_u8; 16];
        bytes.copy_from_slice(&digest[..16]);
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        Ok(Uuid::from_bytes(bytes))
    }

    fn persisted_hmac(
        &self,
        domain: &[u8],
        value: &[u8],
    ) -> Result<Sha256Digest, PaymentRuntimeError> {
        hex_lower(&self.mac(domain, &[value])?)
            .parse()
            .map_err(|_| PaymentRuntimeError::OwnerFunction)
    }

    fn mac(&self, domain: &[u8], values: &[&[u8]]) -> Result<Vec<u8>, PaymentRuntimeError> {
        let mut mac = HmacSha256::new_from_slice(&self.key)
            .map_err(|_| PaymentRuntimeError::InvalidRequest)?;
        mac.update(domain);
        for value in values {
            mac.update(value);
        }
        Ok(mac.finalize().into_bytes().to_vec())
    }
}

impl FixtureIdentityKeyring {
    pub fn try_new(
        current: FixtureIdentityKey,
        previous: Option<FixtureIdentityKey>,
    ) -> Result<Self, PaymentRuntimeError> {
        if previous.as_ref().is_some_and(|value| {
            value.key_version == current.key_version
                || value.key.as_slice() == current.key.as_slice()
        }) {
            return Err(PaymentRuntimeError::InvalidRequest);
        }
        Ok(Self { current, previous })
    }

    pub fn current(&self) -> &FixtureIdentityKey {
        &self.current
    }

    pub fn candidates(&self) -> impl Iterator<Item = &FixtureIdentityKey> {
        std::iter::once(&self.current).chain(self.previous.iter())
    }

    pub fn previous_for_version(&self, version: &str) -> Option<&FixtureIdentityKey> {
        self.previous
            .as_ref()
            .filter(|key| key.key_version == version)
    }
}

fn valid_key_version(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 100
        && !value
            .bytes()
            .any(|byte| byte.is_ascii_control() || byte.is_ascii_whitespace())
}

fn hex_lower(bytes: &[u8]) -> String {
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        use std::fmt::Write as _;
        let _ = write!(output, "{byte:02x}");
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixture_identities_are_domain_separated_and_reproducible() -> Result<(), PaymentRuntimeError>
    {
        let key =
            FixtureIdentityKey::try_new(vec![7_u8; 32], "test-fixture-identity-v1".to_owned())?;
        let request_id = Uuid::from_u128(0x6601);
        let digest = Sha256Digest::of(b"request");
        let first = key.intent_idempotency(request_id, &digest)?;
        let second = key.intent_idempotency(request_id, &digest)?;
        assert_eq!(first.value, second.value);
        assert_eq!(first.hmac, second.hmac);
        assert_eq!(first.key_version, "test-fixture-identity-v1");

        let charge = key.charge_identity(request_id, &digest, &Sha256Digest::of(b"job"))?;
        assert_ne!(first.value, charge.idempotency.value);
        assert!(charge.merchant_order_id.as_str().starts_with("gdn_test_"));
        assert_ne!(charge.idempotency.hmac, charge.merchant_order_hmac);

        let claim = key.claim_identity(ProviderKind::Stripe, request_id)?;
        let replay = key.claim_identity(ProviderKind::Stripe, request_id)?;
        let other_provider = key.claim_identity(ProviderKind::KakaoPay, request_id)?;
        assert_eq!(claim.merchant_account_hmac, replay.merchant_account_hmac);
        assert_ne!(
            claim.merchant_account_hmac,
            other_provider.merchant_account_hmac
        );
        assert_ne!(claim.donor_hmac, claim.donor_group_hmac);
        assert_eq!(claim.key_version, "test-fixture-identity-v1");
        Ok(())
    }

    #[test]
    fn keyring_requires_distinct_explicit_versions_and_material() {
        let current = FixtureIdentityKey::try_new(vec![7_u8; 32], "current".to_owned());
        let same_material = FixtureIdentityKey::try_new(vec![7_u8; 32], "previous".to_owned());
        assert!(matches!(
            current.and_then(|value| FixtureIdentityKeyring::try_new(value, same_material.ok())),
            Err(PaymentRuntimeError::InvalidRequest)
        ));

        let current = FixtureIdentityKey::try_new(vec![7_u8; 32], "same".to_owned());
        let same_version = FixtureIdentityKey::try_new(vec![8_u8; 32], "same".to_owned());
        assert!(matches!(
            current.and_then(|value| FixtureIdentityKeyring::try_new(value, same_version.ok())),
            Err(PaymentRuntimeError::InvalidRequest)
        ));
    }
}
