fn model_use_rights_decision_set_sha256(evidence: &Value) -> Result<String, Failure> {
    let evidence_rows = evidence
        .as_array()
        .ok_or_else(|| Failure::Terminal("AGENT_EVIDENCE_SCOPE_INVALID", "array".into()))?;
    let mut decisions = std::collections::BTreeMap::new();
    for evidence_row in evidence_rows {
        let source_uses = evidence_row
            .get("sourceUses")
            .and_then(Value::as_array)
            .ok_or_else(|| Failure::Terminal("AGENT_SOURCE_USE_MISSING", "sourceUses".into()))?;
        for source_use in source_uses {
            let source_use_id = source_use
                .get("sourceUseId")
                .and_then(Value::as_str)
                .and_then(|value| Uuid::parse_str(value).ok())
                .ok_or_else(|| {
                    Failure::Terminal("AGENT_SOURCE_USE_INVALID", "sourceUseId".into())
                })?;
            let rights_decision = source_use
                .get("rightsDecision")
                .and_then(Value::as_object)
                .cloned()
                .ok_or_else(|| {
                    Failure::Terminal(
                        "AGENT_SOURCE_USE_RIGHTS_MISSING",
                        source_use_id.to_string(),
                    )
                })?;
            if decisions
                .insert(source_use_id, Value::Object(rights_decision))
                .is_some()
            {
                return Err(Failure::Terminal(
                    "AGENT_SOURCE_USE_INVALID",
                    format!("duplicate:{source_use_id}"),
                ));
            }
        }
    }
    if decisions.is_empty() {
        return Err(Failure::Terminal(
            "AGENT_SOURCE_USE_MISSING",
            "rights decisions".into(),
        ));
    }
    let canonical_set = decisions
        .into_iter()
        .map(|(source_use_id, rights_decision)| {
            json!({
                "rightsDecision": rights_decision,
                "sourceUseId": source_use_id,
            })
        })
        .collect::<Vec<_>>();
    Ok(sha256(&canonical_bytes(&Value::Array(canonical_set))?))
}

fn bound_model_use_rights_decision_set_sha256(
    evidence: &Value,
    persisted_sha256: &str,
) -> Result<String, Failure> {
    let actual_sha256 = model_use_rights_decision_set_sha256(evidence)?;
    if actual_sha256 != persisted_sha256 {
        return Err(Failure::Terminal(
            "AGENT_SOURCE_USE_INVALID",
            "rights decision set digest mismatch".into(),
        ));
    }
    Ok(actual_sha256)
}

#[cfg(test)]
mod rights_decision_set_tests {
    use super::*;

    fn source_use(id: u128, decision: &str) -> Value {
        json!({
            "sourceUseId": Uuid::from_u128(id),
            "rightsDecision": {
                "decision": decision,
                "modelEgressRight": "ALLOW",
                "modelUseRight": "ALLOW",
                "policyVersion": "rights-v2"
            }
        })
    }

    #[test]
    fn persisted_turn_and_receipt_share_the_actual_canonical_rights_set() {
        let first = source_use(1, "ALLOW_WITH_ATTRIBUTION");
        let second = source_use(2, "ALLOW");
        let evidence = json!([{"sourceUses":[second.clone(), first.clone()]}]);
        let reversed = json!([{"sourceUses":[first, second]}]);
        let persisted = model_use_rights_decision_set_sha256(&evidence);
        let reversed = model_use_rights_decision_set_sha256(&reversed);
        assert!(
            matches!((&persisted, &reversed), (Ok(left), Ok(right)) if left == right),
            "the canonical set must be independent of evidence traversal order",
        );
        let Ok(persisted) = persisted else {
            return;
        };
        assert!(matches!(
            bound_model_use_rights_decision_set_sha256(&evidence, &persisted),
            Ok(bound) if bound == persisted
        ));
    }

    #[test]
    fn rights_set_binding_fails_closed_for_missing_duplicate_or_changed_evidence() {
        let authorized_source_use = source_use(1, "ALLOW");
        let evidence = json!([{"sourceUses":[authorized_source_use.clone()]}]);
        let Ok(persisted) = model_use_rights_decision_set_sha256(&evidence) else {
            return;
        };
        let changed = json!([{"sourceUses":[source_use(1, "DENY")]}]);
        assert!(bound_model_use_rights_decision_set_sha256(&changed, &persisted).is_err());
        assert!(model_use_rights_decision_set_sha256(&json!([])).is_err());
        assert!(model_use_rights_decision_set_sha256(
            &json!([{"sourceUses":[authorized_source_use.clone(),authorized_source_use]}])
        )
        .is_err());
        assert!(model_use_rights_decision_set_sha256(
            &json!([{"sourceUses":[{"sourceUseId":Uuid::from_u128(1)}]}])
        )
        .is_err());
    }
}
