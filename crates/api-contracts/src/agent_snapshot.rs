use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum AgentSnapshotError {
    #[error("agent snapshot JSON contains a non-integral number")]
    NonIntegralNumber,
    #[error("agent snapshot JSON serialization failed")]
    Serialization(#[from] serde_json::Error),
    #[error("agent snapshot JSON object changed during canonicalization")]
    ObjectKeyDisappeared,
}

/// Build the immutable AGENT_CASE evidence snapshot shared by the control
/// plane and the analysis worker. The run objective is intentionally not part
/// of this identity: authority agent inputs bind `objective` and
/// `evidence_snapshot_hash` as separate fields, while the provider request
/// binds both values semantically.
pub fn agent_case_snapshot(case_id: &str, evidence: &Value) -> Value {
    json!({"caseId": case_id, "evidence": evidence})
}

/// Hash the AGENT_CASE snapshot using the same RFC 8785-compatible subset in
/// every service that produces or verifies it.
pub fn agent_case_snapshot_sha256(
    case_id: &str,
    evidence: &Value,
) -> Result<String, AgentSnapshotError> {
    let snapshot = agent_case_snapshot(case_id, evidence);
    Ok(Sha256::digest(canonical_json_bytes(&snapshot)?)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

fn canonical_json_bytes(value: &Value) -> Result<Vec<u8>, AgentSnapshotError> {
    fn write_value(value: &Value, out: &mut String) -> Result<(), AgentSnapshotError> {
        match value {
            Value::Null => out.push_str("null"),
            Value::Bool(value) => out.push_str(if *value { "true" } else { "false" }),
            Value::Number(value) => {
                if !value.is_i64() && !value.is_u64() {
                    return Err(AgentSnapshotError::NonIntegralNumber);
                }
                out.push_str(&value.to_string());
            }
            Value::String(value) => out.push_str(&serde_json::to_string(value)?),
            Value::Array(values) => {
                out.push('[');
                for (index, value) in values.iter().enumerate() {
                    if index > 0 {
                        out.push(',');
                    }
                    write_value(value, out)?;
                }
                out.push(']');
            }
            Value::Object(values) => {
                let mut keys = values.keys().collect::<Vec<_>>();
                keys.sort_by(|left, right| left.encode_utf16().cmp(right.encode_utf16()));
                out.push('{');
                for (index, key) in keys.iter().enumerate() {
                    if index > 0 {
                        out.push(',');
                    }
                    out.push_str(&serde_json::to_string(key)?);
                    out.push(':');
                    let value = values
                        .get(*key)
                        .ok_or(AgentSnapshotError::ObjectKeyDisappeared)?;
                    write_value(value, out)?;
                }
                out.push('}');
            }
        }
        Ok(())
    }

    let mut output = String::new();
    write_value(value, &mut output)?;
    Ok(output.into_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_contract_has_fixed_cross_service_digest() {
        let evidence = json!([{
            "updatedAt": "2026-07-21T00:00:00Z",
            "promptInjectionFlags": [],
            "locator": "page:7",
            "id": "22222222-2222-4222-8222-222222222222",
            "contentSha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        }]);

        assert_eq!(
            agent_case_snapshot_sha256("11111111-1111-4111-8111-111111111111", &evidence)
                .expect("snapshot must be canonicalizable"),
            "abf6e4180242ce29d6c76b2434c6739fd31a5a16d8aadda27991bb001a34290a"
        );
    }

    #[test]
    fn snapshot_identity_excludes_run_objective() {
        let snapshot = agent_case_snapshot(
            "11111111-1111-4111-8111-111111111111",
            &json!([{"id": "22222222-2222-4222-8222-222222222222"}]),
        );

        assert_eq!(
            snapshot
                .as_object()
                .expect("snapshot object")
                .keys()
                .cloned()
                .collect::<Vec<_>>(),
            vec!["caseId".to_owned(), "evidence".to_owned()]
        );
        assert!(snapshot.get("objective").is_none());
    }
}
