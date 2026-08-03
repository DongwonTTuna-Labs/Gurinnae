use super::*;

pub(super) struct RightsProjection {
    pub(super) occurred_at: String,
    expires_at: Value,
    dimensions: Value,
    digest: String,
}

pub(super) fn project_rights(
    rights: &Value,
    artifact_id: Uuid,
    asset_id: Uuid,
    content_sha256: &str,
    policy_version: &str,
    source_id: &str,
) -> Result<RightsProjection, Failure> {
    let primary_decision = rights
        .get("primaryDecision")
        .filter(|value| value.is_object())
        .ok_or_else(|| Failure::Terminal("SOURCE_RIGHTS_INVALID", "primaryDecision".to_owned()))?;
    let capability_id = required_uuid(primary_decision, "decisionId")?;
    let capability_version = primary_decision
        .get("decisionVersion")
        .and_then(Value::as_i64)
        .filter(|version| *version > 0)
        .ok_or_else(|| Failure::Terminal("SOURCE_RIGHTS_INVALID", "decisionVersion".to_owned()))?;
    let capability_digest = required_sha256(primary_decision, "decisionSha256")?;
    let capability_decisions = rights
        .get("capabilityDecisions")
        .and_then(Value::as_array)
        .filter(|decisions| !decisions.is_empty())
        .ok_or_else(|| {
            Failure::Terminal("SOURCE_RIGHTS_INVALID", "capabilityDecisions".to_owned())
        })?;
    let capability_decision_set_sha256 = required_sha256(rights, "capabilityDecisionSetSha256")?;
    if sha256(&canonical_bytes(&Value::Array(
        capability_decisions.clone(),
    ))?) != capability_decision_set_sha256
        || !capability_decisions
            .iter()
            .any(|decision| decision == primary_decision)
    {
        return Err(Failure::Terminal(
            "SOURCE_RIGHTS_INVALID",
            "capabilityDecisionSetSha256".to_owned(),
        ));
    }
    let execution_receipt_set_sha256 = required_sha256(rights, "executionReceiptSetSha256")?;
    let occurred_at = required_text(rights, "effectiveAt")?;
    let expires_at = rights.get("expiresAt").cloned().unwrap_or(Value::Null);
    let dimensions = rights
        .get("dimensions")
        .filter(|value| value.is_object())
        .cloned()
        .ok_or_else(|| Failure::Terminal("SOURCE_RIGHTS_INVALID", "dimensions".to_owned()))?;
    let right = |name: &str| required_right(&dimensions, name);
    let identity = json!({
        "schemaVersion":"asset-rights-decision.v1","decisionId":asset_id,"assetId":asset_id,
        "assetSha256":content_sha256,"assetRevision":1,"decisionVersion":1,
        "assetKind":"RESEARCH_ARTIFACT","researchArtifactId":artifact_id,"decisionKind":"GRANT",
        "accessRight":right("accessRight")?,"privateStorageRight":right("privateStorageRight")?,
        "modelEgressRight":right("modelEgressRight")?,"modelUseRight":right("modelUseRight")?,
        "derivativeCreationRight":right("derivativeCreationRight")?,"excerptRight":right("excerptRight")?,
        "redistributionRight":right("redistributionRight")?,"commercialUseRight":right("commercialUseRight")?,
        "publicDisplayRight":right("publicDisplayRight")?,"policyVersion":policy_version,
        "policySha256":sha256(policy_version.as_bytes()),"legalBasisCode":"PUBLIC_RESEARCH",
        "legalBasisReference":source_id,"jurisdiction":"GLOBAL","attributionRequired":false,
        "effectiveAt":occurred_at,"expiresAt":expires_at,"capabilityDecisionId":capability_id,
        "capabilityDecisionVersion":capability_version,"capabilityDecisionSha256":capability_digest,
        "capabilityDecisions":capability_decisions,"capabilityDecisionSetSha256":capability_decision_set_sha256,
        "executionReceiptSetSha256":execution_receipt_set_sha256
    });
    Ok(RightsProjection {
        occurred_at,
        expires_at,
        dimensions,
        digest: sha256(&canonical_bytes(&identity)?),
    })
}

fn required_text(value: &Value, field: &str) -> Result<String, Failure> {
    value
        .get(field)
        .and_then(Value::as_str)
        .filter(|candidate| !candidate.trim().is_empty())
        .map(str::to_owned)
        .ok_or_else(|| Failure::Terminal("SOURCE_RIGHTS_INVALID", field.to_owned()))
}

fn required_uuid(value: &Value, field: &str) -> Result<Uuid, Failure> {
    value
        .get(field)
        .and_then(Value::as_str)
        .and_then(|candidate| Uuid::parse_str(candidate).ok())
        .ok_or_else(|| Failure::Terminal("SOURCE_RIGHTS_INVALID", field.to_owned()))
}

fn required_sha256(value: &Value, field: &str) -> Result<String, Failure> {
    value
        .get(field)
        .and_then(Value::as_str)
        .filter(|candidate| {
            candidate.len() == 64
                && candidate
                    .bytes()
                    .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
        })
        .map(str::to_owned)
        .ok_or_else(|| Failure::Terminal("SOURCE_RIGHTS_INVALID", field.to_owned()))
}

fn required_right<'a>(dimensions: &'a Value, field: &str) -> Result<&'a str, Failure> {
    dimensions
        .get(field)
        .and_then(Value::as_str)
        .filter(|value| matches!(*value, "ALLOW" | "DENY" | "UNKNOWN"))
        .ok_or_else(|| Failure::Terminal("SOURCE_RIGHTS_INVALID", field.to_owned()))
}

pub(super) struct SourceUseRootInput<'a> {
    pub(super) source_use_id: Uuid,
    pub(super) turn: &'a ProviderTurnIdentity,
    pub(super) call: &'a gurine_agent_orchestration::runtime::ToolCall,
    pub(super) artifact_id: Uuid,
    pub(super) asset_id: Uuid,
    pub(super) fetch_id: Uuid,
    pub(super) artifact_sha256: &'a str,
    pub(super) content_sha256: &'a str,
    pub(super) locator: &'a str,
    pub(super) rights: &'a RightsProjection,
}

pub(super) fn build_source_use_root(input: &SourceUseRootInput<'_>) -> Value {
    let SourceUseRootInput {
        source_use_id,
        turn,
        call,
        artifact_id,
        asset_id,
        fetch_id,
        artifact_sha256,
        content_sha256,
        locator,
        rights,
    } = input;
    json!({
        "schemaVersion":"source-use.v2","sourceUseId":source_use_id,"agentRunId":turn.run_id,
        "providerTurnId":turn.turn_id,"toolCallId":call.call_id,"parentSourceUseId":Value::Null,
        "parentSourceUseSha256":Value::Null,"useKind":"TOOL_QUERY","sourceKind":"RESEARCH_ARTIFACT",
        "sourceIdentity":{"kind":"RESEARCH_ARTIFACT","researchArtifactId":artifact_id,"assetId":asset_id,
            "assetRevision":1,"artifactSha256":artifact_sha256,"contentSha256":content_sha256,"sourceFetchId":fetch_id},
        "locator":{"kind":"HTML_CSS_SELECTOR","value":locator,"locatorSha256":sha256(locator.as_bytes())},
        "selectedContentSha256":content_sha256,"classification":INITIAL_RESEARCH_CLASSIFICATION,
        "rightsDecision":source_use_rights_decision(*asset_id, rights),
        "providerReceiptId":Value::Null,"occurredAt":rights.occurred_at
    })
}

fn source_use_rights_decision(asset_id: Uuid, rights: &RightsProjection) -> Value {
    let right = |name: &str| {
        rights
            .dimensions
            .get(name)
            .and_then(Value::as_str)
            .unwrap_or("UNKNOWN")
    };
    json!({
        "decisionId":asset_id,"decisionVersion":1,"decisionSha256":rights.digest,
        "effectiveAt":rights.occurred_at,"expiresAt":rights.expires_at,
        "accessRight":right("accessRight"),"privateStorageRight":right("privateStorageRight"),
        "modelEgressRight":right("modelEgressRight"),"modelUseRight":right("modelUseRight"),
        "derivativeCreationRight":right("derivativeCreationRight"),"excerptRight":right("excerptRight"),
        "redistributionRight":right("redistributionRight"),"commercialUseRight":right("commercialUseRight"),
        "publicDisplayRight":right("publicDisplayRight")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rights_snapshot() -> Value {
        let primary = json!({
            "capabilityClass":"SOURCE_ACCESS",
            "decisionId":Uuid::from_u128(3),
            "decisionVersion":7,
            "decisionSha256":"b".repeat(64),
            "effectiveAt":"2026-08-01T00:00:00Z",
            "expiresAt":Value::Null,
            "executionReceiptId":Uuid::from_u128(4),
            "executionReceiptSha256":"d".repeat(64)
        });
        let decisions = json!([primary.clone()]);
        let execution_receipts = json!([{
            "capabilityClass":"SOURCE_ACCESS",
            "executionReceiptId":Uuid::from_u128(4),
            "executionReceiptSha256":"d".repeat(64)
        }]);
        json!({
            "primaryDecision":primary,
            "capabilityDecisions":decisions,
            "capabilityDecisionSetSha256":sha256(
                &canonical_bytes(&decisions).expect("canonical decisions")
            ),
            "executionReceiptSetSha256":sha256(
                &canonical_bytes(&execution_receipts).expect("canonical receipts")
            ),
            "effectiveAt":"2026-08-01T00:00:00Z",
            "expiresAt":Value::Null,
            "dimensions":{
                "accessRight":"ALLOW",
                "privateStorageRight":"ALLOW",
                "modelEgressRight":"ALLOW",
                "modelUseRight":"ALLOW",
                "derivativeCreationRight":"UNKNOWN",
                "excerptRight":"UNKNOWN",
                "redistributionRight":"UNKNOWN",
                "commercialUseRight":"UNKNOWN",
                "publicDisplayRight":"UNKNOWN"
            }
        })
    }

    #[test]
    fn asset_rights_digest_covers_complete_database_preimage() {
        let rights = rights_snapshot();
        let projection = project_rights(
            &rights,
            Uuid::from_u128(1),
            Uuid::from_u128(2),
            &"a".repeat(64),
            "source-policy-v2",
            "open-dart",
        )
        .expect("valid rights snapshot");
        let expected = json!({
            "schemaVersion":"asset-rights-decision.v1",
            "decisionId":Uuid::from_u128(2),
            "assetId":Uuid::from_u128(2),
            "assetSha256":"a".repeat(64),
            "assetRevision":1,
            "decisionVersion":1,
            "assetKind":"RESEARCH_ARTIFACT",
            "researchArtifactId":Uuid::from_u128(1),
            "decisionKind":"GRANT",
            "accessRight":"ALLOW",
            "privateStorageRight":"ALLOW",
            "modelEgressRight":"ALLOW",
            "modelUseRight":"ALLOW",
            "derivativeCreationRight":"UNKNOWN",
            "excerptRight":"UNKNOWN",
            "redistributionRight":"UNKNOWN",
            "commercialUseRight":"UNKNOWN",
            "publicDisplayRight":"UNKNOWN",
            "policyVersion":"source-policy-v2",
            "policySha256":sha256(b"source-policy-v2"),
            "legalBasisCode":"PUBLIC_RESEARCH",
            "legalBasisReference":"open-dart",
            "jurisdiction":"GLOBAL",
            "attributionRequired":false,
            "effectiveAt":"2026-08-01T00:00:00Z",
            "expiresAt":Value::Null,
            "capabilityDecisionId":Uuid::from_u128(3),
            "capabilityDecisionVersion":7,
            "capabilityDecisionSha256":"b".repeat(64),
            "capabilityDecisions":rights["capabilityDecisions"].clone(),
            "capabilityDecisionSetSha256":rights["capabilityDecisionSetSha256"].clone(),
            "executionReceiptSetSha256":rights["executionReceiptSetSha256"].clone()
        });
        assert_eq!(
            projection.digest,
            sha256(&canonical_bytes(&expected).expect("canonical asset rights"))
        );
    }

    #[test]
    fn source_use_rights_decision_matches_closed_schema_keys() {
        let projection = projection_from(&rights_snapshot()).expect("valid rights snapshot");
        let decision = source_use_rights_decision(Uuid::from_u128(2), &projection);
        let keys = decision
            .as_object()
            .expect("rights decision")
            .keys()
            .map(String::as_str)
            .collect::<std::collections::BTreeSet<_>>();
        let expected = [
            "accessRight",
            "commercialUseRight",
            "decisionId",
            "decisionSha256",
            "decisionVersion",
            "derivativeCreationRight",
            "effectiveAt",
            "excerptRight",
            "expiresAt",
            "modelEgressRight",
            "modelUseRight",
            "privateStorageRight",
            "publicDisplayRight",
            "redistributionRight",
        ]
        .into_iter()
        .collect::<std::collections::BTreeSet<_>>();
        assert_eq!(keys, expected);
        assert_eq!(decision["decisionId"], json!(Uuid::from_u128(2)));
        assert_eq!(decision["decisionSha256"], projection.digest);
        assert!(decision.get("capabilityDecisionId").is_none());
        assert!(decision.get("capabilityDecisionSetSha256").is_none());
    }

    #[test]
    fn rights_snapshot_requires_nested_primary_and_exact_decision_set() {
        let mut flattened = rights_snapshot();
        flattened
            .as_object_mut()
            .expect("object")
            .remove("primaryDecision");
        flattened["decisionId"] = json!(Uuid::from_u128(3));
        flattened["decisionVersion"] = json!(7);
        flattened["decisionSha256"] = json!("b".repeat(64));
        assert!(projection_from(&flattened).is_err());

        let mut mismatched = rights_snapshot();
        mismatched["capabilityDecisionSetSha256"] = json!("f".repeat(64));
        assert!(projection_from(&mismatched).is_err());

        let mut missing_dimension = rights_snapshot();
        missing_dimension["dimensions"]
            .as_object_mut()
            .expect("dimensions")
            .remove("modelUseRight");
        assert!(projection_from(&missing_dimension).is_err());
    }

    fn projection_from(rights: &Value) -> Result<RightsProjection, Failure> {
        project_rights(
            rights,
            Uuid::from_u128(1),
            Uuid::from_u128(2),
            &"a".repeat(64),
            "source-policy-v2",
            "open-dart",
        )
    }
}
