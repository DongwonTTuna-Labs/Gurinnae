use super::*;

#[test]
fn economics_create_and_update_preserve_the_compiler_authoritative_public_target()
-> Result<(), &'static str> {
    for operation in ["createActionProposal", "updateActionDraft"] {
        let normalized =
            normalize_owner_payload(operation, public_action_payload("ECONOMICS_IMPORT"));
        let target = normalized
            .get("draft")
            .and_then(Value::as_object)
            .and_then(|draft| draft.get("target"))
            .and_then(Value::as_object)
            .ok_or("normalized TEST_FIXTURE target missing")?;

        assert_eq!(target.len(), 3);
        assert_eq!(
            target.get("targetType"),
            Some(&json!("ECONOMICS_IMPORT"))
        );
        assert_eq!(
            target.get("targetId"),
            Some(&json!("test-fixture-import"))
        );
        assert_eq!(target.get("expectedVersion"), Some(&Value::Null));
        for legacy_key in ["type", "id", "version"] {
            assert!(!target.contains_key(legacy_key));
        }
    }
    Ok(())
}

#[test]
fn non_economics_create_and_update_keep_the_legacy_owner_target_shape()
-> Result<(), &'static str> {
    for operation in ["createActionProposal", "updateActionDraft"] {
        let normalized = normalize_owner_payload(operation, public_action_payload("TASK"));
        let target = normalized
            .get("draft")
            .and_then(Value::as_object)
            .and_then(|draft| draft.get("target"))
            .and_then(Value::as_object)
            .ok_or("normalized TEST_FIXTURE target missing")?;

        assert_eq!(target.len(), 3);
        assert_eq!(target.get("type"), Some(&json!("ECONOMICS_IMPORT")));
        assert_eq!(target.get("id"), Some(&json!("test-fixture-import")));
        assert_eq!(target.get("version"), Some(&Value::Null));
        for public_key in ["targetType", "targetId", "expectedVersion"] {
            assert!(!target.contains_key(public_key));
        }
    }
    Ok(())
}

#[test]
fn unrelated_owner_payload_does_not_rewrite_action_target_keys() {
    let original = public_action_payload("ECONOMICS_IMPORT");
    assert_eq!(
        normalize_owner_payload("submitActionForReview", original.clone()),
        original
    );
}

fn public_action_payload(kind: &str) -> Value {
    json!({
        "actionKind": "ECONOMICS_IMPORT",
        "draft": {
            "kind": kind,
            "target": {
                "targetType": "ECONOMICS_IMPORT",
                "targetId": "test-fixture-import",
                "expectedVersion": null
            }
        }
    })
}
