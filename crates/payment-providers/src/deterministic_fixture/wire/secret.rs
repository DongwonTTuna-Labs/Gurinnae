use serde::Deserialize;
use zeroize::Zeroize;

#[derive(Deserialize)]
#[serde(transparent)]
pub(super) struct SecretWire(String);

impl SecretWire {
    pub(super) fn expose(&self) -> &str {
        &self.0
    }
}

impl Drop for SecretWire {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}
