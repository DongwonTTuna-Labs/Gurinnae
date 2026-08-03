use std::{collections::BTreeMap, sync::Mutex};

use hmac::{Hmac, Mac};
use sha2::Sha256;
use uuid::Uuid;

use crate::{
    BillingCredentialUsePolicy, BillingKeyHandle, BillingKeyMaterial, KeyVersion, ProviderKind,
    SecretText, TestFixtureAuthority, VaultError, secret::SecretBytes,
};

type HmacSha256 = Hmac<Sha256>;

const FIXTURE_SECRET_REFERENCE_VERSION: u64 = 2;

pub trait BillingKeyVault: Send + Sync {
    fn store(
        &self,
        binding_id: Uuid,
        material: BillingKeyMaterial,
        use_policy: BillingCredentialUsePolicy,
    ) -> Result<BillingKeyHandle, VaultError>;

    /// Releases credential material for a provider charge.
    ///
    /// A `SingleCharge` entry is removed atomically before this method returns.
    /// A `Recurring` entry remains available for a later scheduler-owned charge.
    fn take_for_charge(&self, handle: &BillingKeyHandle) -> Result<BillingKeyMaterial, VaultError>;

    fn destroy(&self, handle: &BillingKeyHandle) -> Result<(), VaultError>;
}

struct VaultEntry {
    material: SecretBytes,
    use_policy: BillingCredentialUsePolicy,
}

impl VaultEntry {
    fn destroy(self) {
        self.material.destroy();
    }
}

pub struct InMemoryTestFixtureBillingKeyVault {
    hmac_key: SecretBytes,
    hmac_key_version: KeyVersion,
    entries: Mutex<BTreeMap<Uuid, VaultEntry>>,
}

impl InMemoryTestFixtureBillingKeyVault {
    pub fn new(
        _authority: TestFixtureAuthority,
        hmac_key: Vec<u8>,
        hmac_key_version: KeyVersion,
    ) -> Result<Self, VaultError> {
        if hmac_key.len() < 32 {
            return Err(VaultError::InvalidInput);
        }
        Ok(Self {
            hmac_key: SecretBytes::new(hmac_key),
            hmac_key_version,
            entries: Mutex::new(BTreeMap::new()),
        })
    }

    fn handle(
        &self,
        binding_id: Uuid,
        provider: ProviderKind,
        use_policy: BillingCredentialUsePolicy,
        material: &[u8],
    ) -> Result<BillingKeyHandle, VaultError> {
        let material_hmac = binding_hmac(
            self.hmac_key.expose(),
            binding_id,
            provider,
            use_policy,
            material,
        )?;
        Ok(BillingKeyHandle {
            binding_id,
            provider,
            use_policy,
            secret_reference: fixture_secret_reference(binding_id),
            material_hmac,
            hmac_key_version: self.hmac_key_version.clone(),
        })
    }

    fn verify_handle(
        &self,
        handle: &BillingKeyHandle,
        entry: &VaultEntry,
    ) -> Result<(), VaultError> {
        let expected_reference = fixture_secret_reference(handle.binding_id);
        if handle.secret_reference != expected_reference
            || handle.hmac_key_version != self.hmac_key_version
        {
            return Err(VaultError::Integrity);
        }
        if handle.use_policy != entry.use_policy {
            return Err(VaultError::UsePolicyMismatch);
        }
        let verifier = binding_mac(
            self.hmac_key.expose(),
            handle.binding_id,
            handle.provider,
            handle.use_policy,
            entry.material.expose(),
        )?;
        let provided = decode_hex_32(&handle.material_hmac)?;
        verifier
            .verify_slice(&provided)
            .map_err(|_| VaultError::Integrity)
    }
}

fn fixture_secret_reference(binding_id: Uuid) -> String {
    format!("fixture://billing-key/{binding_id}@v{FIXTURE_SECRET_REFERENCE_VERSION}")
}

impl std::fmt::Debug for InMemoryTestFixtureBillingKeyVault {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("InMemoryTestFixtureBillingKeyVault")
            .field("hmac_key", &"<redacted>")
            .field("hmac_key_version", &self.hmac_key_version)
            .finish_non_exhaustive()
    }
}

impl BillingKeyVault for InMemoryTestFixtureBillingKeyVault {
    fn store(
        &self,
        binding_id: Uuid,
        material: BillingKeyMaterial,
        use_policy: BillingCredentialUsePolicy,
    ) -> Result<BillingKeyHandle, VaultError> {
        let provider = material.provider();
        let encoded = SecretBytes::new(encode_material(material));
        let handle = self.handle(binding_id, provider, use_policy, encoded.expose())?;
        let mut entries = self.entries.lock().map_err(|_| VaultError::Unavailable)?;
        if let Some(existing) = entries.get(&binding_id) {
            if existing.use_policy != use_policy {
                return Err(VaultError::UsePolicyMismatch);
            }
            if existing.material.expose() != encoded.expose() {
                return Err(VaultError::Integrity);
            }
            return Ok(handle);
        }
        entries.insert(
            binding_id,
            VaultEntry {
                material: encoded,
                use_policy,
            },
        );
        Ok(handle)
    }

    fn take_for_charge(&self, handle: &BillingKeyHandle) -> Result<BillingKeyMaterial, VaultError> {
        let mut entries = self.entries.lock().map_err(|_| VaultError::Unavailable)?;
        let entry = entries.get(&handle.binding_id).ok_or(VaultError::Missing)?;
        self.verify_handle(handle, entry)?;
        if handle.use_policy == BillingCredentialUsePolicy::Recurring {
            return decode_material(entry.material.expose(), handle.provider);
        }
        let entry = entries
            .remove(&handle.binding_id)
            .ok_or(VaultError::Missing)?;
        let material = decode_material(entry.material.expose(), handle.provider);
        entry.destroy();
        material
    }

    fn destroy(&self, handle: &BillingKeyHandle) -> Result<(), VaultError> {
        let mut entries = self.entries.lock().map_err(|_| VaultError::Unavailable)?;
        let entry = entries.get(&handle.binding_id).ok_or(VaultError::Missing)?;
        self.verify_handle(handle, entry)?;
        let entry = entries
            .remove(&handle.binding_id)
            .ok_or(VaultError::Missing)?;
        entry.destroy();
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct DisabledLiveBillingKeyVault;

impl BillingKeyVault for DisabledLiveBillingKeyVault {
    fn store(
        &self,
        _binding_id: Uuid,
        _material: BillingKeyMaterial,
        _use_policy: BillingCredentialUsePolicy,
    ) -> Result<BillingKeyHandle, VaultError> {
        Err(VaultError::LiveVaultDisabled)
    }

    fn take_for_charge(
        &self,
        _handle: &BillingKeyHandle,
    ) -> Result<BillingKeyMaterial, VaultError> {
        Err(VaultError::LiveVaultDisabled)
    }

    fn destroy(&self, _handle: &BillingKeyHandle) -> Result<(), VaultError> {
        Err(VaultError::LiveVaultDisabled)
    }
}

fn binding_hmac(
    key: &[u8],
    binding_id: Uuid,
    provider: ProviderKind,
    use_policy: BillingCredentialUsePolicy,
    material: &[u8],
) -> Result<String, VaultError> {
    let mac = binding_mac(key, binding_id, provider, use_policy, material)?;
    Ok(hex_lower(&mac.finalize().into_bytes()))
}

fn binding_mac(
    key: &[u8],
    binding_id: Uuid,
    provider: ProviderKind,
    use_policy: BillingCredentialUsePolicy,
    material: &[u8],
) -> Result<HmacSha256, VaultError> {
    let mut mac = HmacSha256::new_from_slice(key).map_err(|_| VaultError::InvalidInput)?;
    mac.update(b"gurine-payment-method-binding.v2\0");
    mac.update(binding_id.as_bytes());
    mac.update(b"\0");
    mac.update(provider.as_str().as_bytes());
    mac.update(b"\0");
    mac.update(use_policy.as_str().as_bytes());
    mac.update(b"\0");
    mac.update(material);
    Ok(mac)
}

fn encode_material(material: BillingKeyMaterial) -> Vec<u8> {
    let provider = material.provider();
    let first = material.first_secret().as_bytes();
    let second = material.second_secret().as_bytes();
    let mut encoded = Vec::with_capacity(64 + first.len() + second.len());
    encoded.extend_from_slice(b"gurine-payment-method-material.v1\0");
    encoded.extend_from_slice(provider.as_str().as_bytes());
    encoded.push(0);
    push_field(&mut encoded, first);
    push_field(&mut encoded, second);
    encoded
}

fn push_field(encoded: &mut Vec<u8>, value: &[u8]) {
    encoded.extend_from_slice(&(value.len() as u64).to_be_bytes());
    encoded.extend_from_slice(value);
}

fn decode_material(
    encoded: &[u8],
    expected_provider: ProviderKind,
) -> Result<BillingKeyMaterial, VaultError> {
    const PREFIX: &[u8] = b"gurine-payment-method-material.v1\0";
    let after_prefix = encoded.strip_prefix(PREFIX).ok_or(VaultError::Integrity)?;
    let provider_end = after_prefix
        .iter()
        .position(|byte| *byte == 0)
        .ok_or(VaultError::Integrity)?;
    let provider =
        std::str::from_utf8(&after_prefix[..provider_end]).map_err(|_| VaultError::Integrity)?;
    if provider != expected_provider.as_str() {
        return Err(VaultError::Integrity);
    }
    let fields = &after_prefix[provider_end + 1..];
    let (first, remaining) = take_field(fields)?;
    let (second, trailing) = take_field(remaining)?;
    if !trailing.is_empty() {
        return Err(VaultError::Integrity);
    }
    let first = String::from_utf8(first.to_vec()).map_err(|_| VaultError::Integrity)?;
    let second = String::from_utf8(second.to_vec()).map_err(|_| VaultError::Integrity)?;
    let first = SecretText::try_new(first).map_err(|_| VaultError::Integrity)?;
    let second = SecretText::try_new(second).map_err(|_| VaultError::Integrity)?;
    Ok(match expected_provider {
        ProviderKind::TossPayments => BillingKeyMaterial::TossPayments {
            billing_key: first,
            customer_key: second,
        },
        ProviderKind::KakaoPay => BillingKeyMaterial::KakaoPay {
            subscription_id: first,
            partner_user_id: second,
        },
        ProviderKind::Stripe => BillingKeyMaterial::Stripe {
            customer_id: first,
            payment_method_id: second,
        },
    })
}

fn take_field(bytes: &[u8]) -> Result<(&[u8], &[u8]), VaultError> {
    let length_bytes: [u8; 8] = bytes
        .get(..8)
        .ok_or(VaultError::Integrity)?
        .try_into()
        .map_err(|_| VaultError::Integrity)?;
    let length =
        usize::try_from(u64::from_be_bytes(length_bytes)).map_err(|_| VaultError::Integrity)?;
    let end = 8_usize.checked_add(length).ok_or(VaultError::Integrity)?;
    let value = bytes.get(8..end).ok_or(VaultError::Integrity)?;
    let remaining = bytes.get(end..).ok_or(VaultError::Integrity)?;
    Ok((value, remaining))
}

fn decode_hex_32(value: &str) -> Result<[u8; 32], VaultError> {
    if value.len() != 64 {
        return Err(VaultError::Integrity);
    }
    let mut output = [0_u8; 32];
    for (index, pair) in value.as_bytes().chunks_exact(2).enumerate() {
        let high = hex_nibble(pair[0]).ok_or(VaultError::Integrity)?;
        let low = hex_nibble(pair[1]).ok_or(VaultError::Integrity)?;
        output[index] = (high << 4) | low;
    }
    Ok(output)
}

fn hex_nibble(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        _ => None,
    }
}

fn hex_lower(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(char::from(HEX[usize::from(byte >> 4)]));
        output.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    output
}
