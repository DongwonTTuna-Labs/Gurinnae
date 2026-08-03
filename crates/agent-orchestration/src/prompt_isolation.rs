use serde_json::Value;
use sha2::{Digest, Sha256};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum PromptError {
    #[error("prompt input serialization failed")]
    Serialization,
}

pub fn rendered_hash(prompt: &str, input: &Value) -> Result<String, PromptError> {
    let canonical = serde_json::to_string(input).map_err(|_| PromptError::Serialization)?;
    let rendered = format!("{}\n\nINPUT_JSON\n{}\n", prompt.trim(), canonical);
    Ok(Sha256::digest(rendered.as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

pub fn contains_untrusted_instruction(value: &Value) -> Result<bool, PromptError> {
    let text = serde_json::to_string(value)
        .map_err(|_| PromptError::Serialization)?
        .to_lowercase();
    Ok([
        "ignore previous",
        "system prompt",
        "reveal secret",
        "override policy",
    ]
    .iter()
    .any(|token| text.contains(token)))
}
