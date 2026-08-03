async fn evidence_snapshot(
    pool: &PgPool,
    case_id: Uuid,
    run_id: Uuid,
    ids: &[Uuid],
) -> Result<Value, Failure> {
    let value: Value = sqlx::query_scalar!(
        "SELECT COALESCE(jsonb_agg(jsonb_build_object( \
           'id',e.id,'contentSha256',btrim(e.content_sha256::text), \
           'locator',e.source_locator,'updatedAt',e.updated_at, \
           'promptInjectionFlags',COALESCE(d.prompt_injection_flags,'[]'::jsonb), \
           'sourceUses',COALESCE((SELECT jsonb_agg(jsonb_build_object( \
             'sourceUseId',su.source_use_id, \
             'sourceUseSha256',btrim(su.source_use_sha256::text), \
             'parentSourceUseId',su.parent_source_use_id, \
             'parentSourceUseSha256',btrim(su.parent_source_use_sha256::text), \
             'providerReceiptId',su.provider_receipt_id, \
             'useKind',su.use_kind, \
             'sourceKind',su.source_kind, \
             'evidenceSegmentId',COALESCE(su.evidence_segment_id,seg.id), \
             'selectedContentSha256',btrim(COALESCE(su.selected_content_sha256,seg.selected_content_sha256)::text), \
             'selectedContentObjectKey',COALESCE((SELECT seg_bytes.selected_content_object_key FROM raw.evidence_segments seg_bytes \
               WHERE seg_bytes.source_document_id=su.source_document_id \
                 AND seg_bytes.source_asset_id=su.source_asset_id \
                 AND seg_bytes.source_asset_revision=su.source_asset_revision \
                 AND seg_bytes.locator_value=COALESCE(su.locator_value,seg.locator_value) \
                 AND seg_bytes.selected_content_sha256=COALESCE(su.selected_content_sha256,seg.selected_content_sha256) \
               ORDER BY seg_bytes.segment_ordinal LIMIT 1),d.object_key), \
             'selectedContentLocator',COALESCE((SELECT seg_bytes.selected_content_locator FROM raw.evidence_segments seg_bytes \
               WHERE seg_bytes.source_document_id=su.source_document_id \
                 AND seg_bytes.source_asset_id=su.source_asset_id \
                 AND seg_bytes.source_asset_revision=su.source_asset_revision \
                 AND seg_bytes.locator_value=COALESCE(su.locator_value,seg.locator_value) \
                 AND seg_bytes.selected_content_sha256=COALESCE(su.selected_content_sha256,seg.selected_content_sha256) \
               ORDER BY seg_bytes.segment_ordinal LIMIT 1),e.source_locator), \
             'selectedContentMediaType',COALESCE((SELECT seg_bytes.selected_content_media_type FROM raw.evidence_segments seg_bytes \
               WHERE seg_bytes.source_document_id=su.source_document_id \
                 AND seg_bytes.source_asset_id=su.source_asset_id \
                 AND seg_bytes.source_asset_revision=su.source_asset_revision \
                 AND seg_bytes.locator_value=COALESCE(su.locator_value,seg.locator_value) \
                 AND seg_bytes.selected_content_sha256=COALESCE(su.selected_content_sha256,seg.selected_content_sha256) \
               ORDER BY seg_bytes.segment_ordinal LIMIT 1),d.content_type), \
             'selectedContentObjectKey',COALESCE(seg.selected_content_object_key,d.object_key), \
             'selectedContentLocator',COALESCE(seg.selected_content_locator,e.source_locator), \
             'selectedContentMediaType',COALESCE(seg.selected_content_media_type,d.content_type), \
             'locator',jsonb_build_object('kind',COALESCE(su.locator_kind,seg.locator_kind),'value',COALESCE(su.locator_value,seg.locator_value),'sha256',btrim(COALESCE(su.locator_sha256,seg.locator_digest)::text)), \
             'classification',su.classification, \
             'rightsDecision',jsonb_build_object( \
               'bindingKind',su.rights_binding_kind, \
               'assetRightsDecisionId',su.asset_rights_decision_id, \
               'assetRightsDecisionVersion',su.asset_rights_decision_version, \
               'assetRightsDecisionSha256',btrim(su.asset_rights_decision_sha256::text), \
               'accessRight',su.access_right, \
               'privateStorageRight',su.private_storage_right, \
               'modelEgressRight',su.model_egress_right, \
               'modelUseRight',su.model_use_right, \
               'derivativeCreationRight',su.derivative_creation_right, \
               'excerptRight',su.excerpt_right, \
               'redistributionRight',su.redistribution_right, \
               'commercialUseRight',su.commercial_use_right, \
               'publicDisplayRight',su.public_display_right, \
               'policyVersion',su.rights_policy_version, \
               'policySha256',btrim(su.rights_policy_sha256::text), \
               'effectiveAt',su.rights_effective_at, \
               'expiresAt',su.rights_expires_at \
             ) \
           ) ORDER BY su.occurred_at,su.source_use_id) \
           FROM ops.agent_source_uses su \
           JOIN core.dataset_snapshot_members m ON m.id=su.snapshot_member_id \
             AND m.dataset_snapshot_id=su.dataset_snapshot_id \
             AND m.member_digest=su.snapshot_member_digest \
           LEFT JOIN raw.evidence_segments seg ON seg.id=COALESCE(su.evidence_segment_id,m.evidence_segment_id) \
             AND seg.source_document_id=su.source_document_id \
             AND seg.source_asset_id=su.source_asset_id \
             AND seg.source_asset_revision=su.source_asset_revision \
             AND seg.source_content_sha256=su.source_content_sha256 \
           WHERE su.agent_run_id=$3 AND su.use_kind='TOOL_QUERY' \
             AND e.source_document_id=su.source_document_id \
             AND (su.source_kind='DATASET_MEMBER' OR seg.source_document_id IS NOT NULL) \
             AND (su.use_kind='TOOL_QUERY' OR EXISTS(SELECT 1 FROM ops.agent_source_uses parent \
               WHERE parent.agent_run_id=su.agent_run_id \
                 AND parent.source_use_id=su.parent_source_use_id \
                 AND parent.source_use_sha256=su.parent_source_use_sha256)) \
             AND (su.source_kind='DATASET_MEMBER' OR seg.locator_value=e.source_locator OR seg.selected_content_sha256=btrim(e.content_sha256::text)) \
         ),'[]'::jsonb) \
         ) ORDER BY e.id),'[]'::jsonb) \
         FROM editorial.evidence e LEFT JOIN raw.source_documents d ON d.id=e.source_document_id \
         WHERE e.case_id=$1 AND e.id=ANY($2::uuid[]) \
           AND e.verification_status='VERIFIED'",
        case_id,
        ids,
        run_id,
    )
    .fetch_one(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| database(sqlx::Error::Decode(Box::new(sqlx::error::UnexpectedNullError))))?;
    if value.as_array().is_none_or(|rows| rows.len() != ids.len()) {
        return Err(Failure::Terminal(
            "AGENT_EVIDENCE_SCOPE_INVALID",
            case_id.to_string(),
        ));
    }
    Ok(value)
}

fn evidence_without_source_uses(evidence: &Value) -> Result<Value, Failure> {
    let rows = evidence
        .as_array()
        .ok_or_else(|| Failure::Terminal("AGENT_EVIDENCE_SCOPE_INVALID", "array".into()))?;
    let mut sanitized = Vec::with_capacity(rows.len());
    for row in rows {
        let mut object = row
            .as_object()
            .cloned()
            .ok_or_else(|| Failure::Terminal("AGENT_EVIDENCE_SCOPE_INVALID", "object".into()))?;
        object.remove("sourceUses");
        sanitized.push(Value::Object(object));
    }
    Ok(Value::Array(sanitized))
}

/// Return the immutable source-use bindings that are allowed to cross the
/// provider boundary.  A provider request is never allowed to infer these
/// from evidence IDs: every selected segment must have a same-run MODEL_INPUT
/// source-use row (with a linked TOOL_QUERY ancestry when present), a
/// selected-content digest, and an explicit rights decision.
fn ordered_source_use_bindings(evidence: &Value) -> Result<(Vec<Uuid>, usize), Failure> {
    let rows = evidence
        .as_array()
        .ok_or_else(|| Failure::Terminal("AGENT_EVIDENCE_SCOPE_INVALID", "array".into()))?;
    let mut ids = Vec::new();
    let mut segments = 0;
    for row in rows {
        let uses = row
            .get("sourceUses")
            .and_then(Value::as_array)
            .ok_or_else(|| Failure::Terminal("AGENT_SOURCE_USE_MISSING", "sourceUses".into()))?;
        if uses.is_empty() {
            return Err(Failure::Terminal(
                "AGENT_SOURCE_USE_MISSING",
                row.get("id").and_then(Value::as_str).unwrap_or_default().into(),
            ));
        }
        for source_use in uses {
            let (id, source_sha, selected_sha) = validate_source_use_binding(source_use)?;
            if ids.contains(&id) {
                return Err(Failure::Terminal(
                    "AGENT_SOURCE_USE_INVALID",
                    format!("duplicate:{id}:{source_sha}:{}", selected_sha.unwrap_or_default()),
                ));
            }
            ids.push(id);
            segments += 1;
        }
    }
    if ids.is_empty() {
        return Err(Failure::Terminal(
            "AGENT_SOURCE_USE_MISSING",
            "no authorized model-input source uses".into(),
        ));
    }
    Ok((ids, segments))
}

/// Collapse the exact model-input source classifications to the only two
/// classes an external provider may receive.  A forbidden or unknown class
/// is rejected before a provider turn, budget reservation, or network send is
/// persisted; it is never relabelled as INTERNAL.
fn external_provider_classification(evidence: &Value) -> Result<&'static str, Failure> {
    let rows = evidence
        .as_array()
        .ok_or_else(|| Failure::Terminal("AGENT_EVIDENCE_SCOPE_INVALID", "array".into()))?;
    let mut classification = "PUBLIC";
    let mut source_count = 0_usize;
    for row in rows {
        let uses = row
            .get("sourceUses")
            .and_then(Value::as_array)
            .ok_or_else(|| Failure::Terminal("AGENT_SOURCE_USE_MISSING", "sourceUses".into()))?;
        for source_use in uses {
            let source_classification = source_use
                .get("classification")
                .and_then(Value::as_str)
                .ok_or_else(|| {
                    Failure::Terminal(
                        "AGENT_SOURCE_CLASSIFICATION_INVALID",
                        "classification".into(),
                    )
                })?;
            match source_classification {
                "PUBLIC" => {}
                "INTERNAL" => classification = "INTERNAL",
                "RESTRICTED" | "PERSONAL_DATA" | "LEGAL_HOLD" => {
                    return Err(Failure::Terminal(
                        "AGENT_SOURCE_CLASSIFICATION_BLOCKED",
                        source_classification.to_owned(),
                    ));
                }
                _ => {
                    return Err(Failure::Terminal(
                        "AGENT_SOURCE_CLASSIFICATION_INVALID",
                        source_classification.to_owned(),
                    ));
                }
            }
            source_count += 1;
        }
    }
    if source_count == 0 {
        return Err(Failure::Terminal(
            "AGENT_SOURCE_USE_MISSING",
            "no classified model-input source uses".into(),
        ));
    }
    Ok(classification)
}

fn validate_source_use_binding(
    source_use: &Value,
) -> Result<(Uuid, String, Option<String>), Failure> {
    let id = source_use
        .get("sourceUseId")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| Failure::Terminal("AGENT_SOURCE_USE_INVALID", "sourceUseId".into()))?;
    let source_sha = source_use
        .get("sourceUseSha256")
        .and_then(Value::as_str)
        .filter(|value| value.len() == 64 && value.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()))
        .ok_or_else(|| Failure::Terminal("AGENT_SOURCE_USE_INVALID", "sourceUseSha256".into()))?
        .to_owned();
    let use_kind = source_use.get("useKind").and_then(Value::as_str).unwrap_or("");
    let source_kind = source_use.get("sourceKind").and_then(Value::as_str).unwrap_or("");
    let root_query = use_kind == "TOOL_QUERY"
        && matches!(source_kind, "DATASET_MEMBER" | "EVIDENCE_SEGMENT");
    let has_provider_receipt = source_use
        .get("providerReceiptId")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .is_some();
    let has_parent = source_use.get("parentSourceUseId").and_then(Value::as_str).is_some()
        && source_use.get("parentSourceUseSha256").and_then(Value::as_str).is_some();
    if !root_query && (!has_provider_receipt || !has_parent) {
        return Err(Failure::Terminal(
            "AGENT_SOURCE_USE_INVALID",
            format!("{id}:provider-parent-binding"),
        ));
    }
    if root_query && (has_provider_receipt || has_parent) {
        return Err(Failure::Terminal("AGENT_SOURCE_USE_INVALID", format!("{id}:root-shape")));
    }
    if !root_query && source_kind != "EVIDENCE_SEGMENT" {
        return Err(Failure::Terminal("AGENT_SOURCE_USE_INVALID", format!("{id}:sourceKind")));
    }
    let selected_sha = source_use
        .get("selectedContentSha256")
        .and_then(Value::as_str)
        .filter(|value| value.len() == 64 && value.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()))
        .map(str::to_owned);
    if !root_query && selected_sha.is_none() {
        return Err(Failure::Terminal("AGENT_SOURCE_USE_INVALID", "selectedContentSha256".into()));
    }
    let rights = source_use
        .get("rightsDecision")
        .and_then(Value::as_object)
        .ok_or_else(|| Failure::Terminal("AGENT_SOURCE_USE_RIGHTS_MISSING", id.to_string()))?;
    for key in ["modelEgressRight", "modelUseRight", "derivativeCreationRight"] {
        if rights.get(key).and_then(Value::as_str) != Some("ALLOW") {
            return Err(Failure::Terminal(
                "AGENT_SOURCE_USE_RIGHTS_DENIED",
                format!("{id}:{key}"),
            ));
        }
    }
    Ok((id, source_sha, selected_sha))
}

#[cfg(test)]
mod source_use_tests {
    use super::*;

    fn evidence_with_rights(rights: &str) -> Value {
        json!([{
            "id": "00000000-0000-0000-0000-000000000001",
            "sourceUses": [{
                "sourceUseId": "00000000-0000-0000-0000-000000000002",
                "sourceUseSha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "useKind": "MODEL_INPUT",
                "sourceKind": "EVIDENCE_SEGMENT",
                "providerReceiptId": "00000000-0000-0000-0000-000000000003",
                "parentSourceUseId": "00000000-0000-0000-0000-000000000004",
                "parentSourceUseSha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
                "selectedContentSha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                "classification": "INTERNAL",
                "rightsDecision": {
                    "modelEgressRight": rights,
                    "modelUseRight": "ALLOW",
                    "derivativeCreationRight": "ALLOW"
                }
            }]
        }])
    }

    #[test]
    fn source_use_binding_is_ordered_and_counted() {
        let result = ordered_source_use_bindings(&evidence_with_rights("ALLOW"));
        assert!(result.is_ok(), "valid source-use binding was rejected");
        let (ids, count) = match result {
            Ok(value) => value,
            Err(_) => return,
        };
        assert_eq!(count, 1);
        assert_eq!(ids, vec![Uuid::from_u128(2)]);
    }

    #[test]
    fn external_classification_is_closed_and_conservative() {
        let mut public = evidence_with_rights("ALLOW");
        public[0]["sourceUses"][0]["classification"] = json!("PUBLIC");
        assert!(matches!(
            external_provider_classification(&public),
            Ok("PUBLIC")
        ));

        let mut mixed = public.clone();
        let mut internal = mixed[0]["sourceUses"][0].clone();
        internal["sourceUseId"] = json!("00000000-0000-0000-0000-000000000005");
        internal["classification"] = json!("INTERNAL");
        if let Some(uses) = mixed[0]["sourceUses"].as_array_mut() {
            uses.push(internal);
        }
        assert!(matches!(
            external_provider_classification(&mixed),
            Ok("INTERNAL")
        ));
    }

    #[test]
    fn forbidden_external_classifications_fail_closed() {
        for classification in ["RESTRICTED", "PERSONAL_DATA", "LEGAL_HOLD"] {
            let mut evidence = evidence_with_rights("ALLOW");
            evidence[0]["sourceUses"][0]["classification"] = json!(classification);
            assert!(matches!(
                external_provider_classification(&evidence),
                Err(Failure::Terminal("AGENT_SOURCE_CLASSIFICATION_BLOCKED", detail))
                    if detail == classification
            ));
        }
    }

    #[test]
    fn research_artifact_is_never_a_direct_provider_content_source() {
        let mut evidence = evidence_with_rights("ALLOW");
        evidence[0]["sourceUses"][0]["sourceKind"] = json!("RESEARCH_ARTIFACT");
        evidence[0]["sourceUses"][0]["classification"] = json!("PUBLIC");
        assert!(matches!(
            ordered_source_use_bindings(&evidence),
            Err(Failure::Terminal("AGENT_SOURCE_USE_INVALID", detail))
                if detail.ends_with(":sourceKind")
        ));
    }

    #[test]
    fn missing_source_use_fails_closed() {
        let result = ordered_source_use_bindings(&json!([{
            "id": "00000000-0000-0000-0000-000000000001",
            "sourceUses": []
        }]));
        assert!(matches!(result, Err(Failure::Terminal("AGENT_SOURCE_USE_MISSING", _))));
    }

    #[test]
    fn denied_model_egress_never_reaches_provider() {
        let result = ordered_source_use_bindings(&evidence_with_rights("DENY"));
        assert!(matches!(result, Err(Failure::Terminal("AGENT_SOURCE_USE_RIGHTS_DENIED", _))));
    }
}

/// A local deterministic double is available only in non-production
/// environments. It supplies a complete provider-shaped result so policy
/// checks (prompt-injection, citation scope, and budget fences) can be tested
/// without pretending that a real external model was called.
fn deterministic_output(agent_type: &str, evidence: &Value) -> Value {
    let Some(first) = evidence.as_array().and_then(|items| items.first()) else {
        return blocked_output_for(agent_type, "ABSTAINED", "EVIDENCE_REQUIRED");
    };
    // The same immutable bundle is compiled into the product adapter and the
    // 50-case hard gate. Containerized development therefore cannot drift
    // from host fixtures or require a runtime source-tree mount.
    let case_id = format!("{agent_type}-01-valid");
    let Ok(mut output) = embedded_provider_response(&case_id) else {
        return blocked_output_for(agent_type, "POLICY_BLOCKED", "DETERMINISTIC_FIXTURE_INVALID");
    };
    let Some(evidence_id) = first.get("id").and_then(Value::as_str) else {
        return blocked_output_for(
            agent_type,
            "POLICY_BLOCKED",
            "DETERMINISTIC_FIXTURE_CITATION_MISSING",
        );
    };
    let Some(locator) = first.get("locator").and_then(Value::as_str) else {
        return blocked_output_for(
            agent_type,
            "POLICY_BLOCKED",
            "DETERMINISTIC_FIXTURE_CITATION_MISSING",
        );
    };
    let supports = output
        .pointer("/citations/0/supports")
        .and_then(Value::as_str)
        .unwrap_or("검토 대상 근거 snapshot");
    output["citations"] = json!([{
        "evidence_id": evidence_id,
        "locator": locator,
        "supports": supports
    }]);
    for (field, id_field) in [
        ("hypotheses", "supporting_evidence_ids"),
        ("challenges", "evidence_ids"),
        ("claims", "evidence_ids"),
        ("claim_results", "verified_evidence_ids"),
    ] {
        for item in output
            .get_mut(field)
            .and_then(Value::as_array_mut)
            .into_iter()
            .flatten()
        {
            item[id_field] = json!([evidence_id]);
            if field == "hypotheses" {
                item["contradicting_evidence_ids"] = json!([]);
            }
        }
    }
    output
}

fn blocked_output_for(agent_type: &str, status: &str, reason: &str) -> Value {
    let field = match agent_type {
        "market-researcher" => "comparables",
        "investigator" => "hypotheses",
        "skeptic" => "challenges",
        "claim-drafter" => "claims",
        "citation-verifier" => "claim_results",
        _ => "recommended_actions",
    };
    json!({
        "status": status,
        "summary": "정책 또는 검증 조건을 충족하지 못해 결론을 생성하지 않았습니다.",
        "citations": [],
        "unknowns": [],
        "abstention_reasons": [reason],
        "recommended_actions": [],
        field: []
    })
}

#[cfg(test)]
mod authority_output_tests {
    use super::*;

    #[test]
    fn deterministic_outputs_preserve_the_closed_authority_schema() {
        let evidence = json!([{
            "id": "7a2d7eba-184c-55b0-8955-86cbca587a6a",
            "locator": "control-agent-scope",
            "contentSha256": "7777777777777777777777777777777777777777777777777777777777777777",
            "promptInjectionFlags": [],
            "updatedAt": "2026-07-21T00:00:00Z",
            "sourceUses": []
        }]);
        for agent_type in [
            "market-researcher",
            "investigator",
            "skeptic",
            "claim-drafter",
            "citation-verifier",
        ] {
            let output = deterministic_output(agent_type, &evidence);
            assert!(output.get("schemaVersion").is_none(), "{agent_type}");
            validate_authority_agent_output(agent_type, &output)
                .unwrap_or_else(|error| panic!("{agent_type}: {error}"));
            assert_eq!(
                output.pointer("/citations/0/evidence_id").and_then(Value::as_str),
                Some("7a2d7eba-184c-55b0-8955-86cbca587a6a")
            );
        }
    }
}

fn validate_agent_output_for(agent_type: Option<&str>, value: &Value) -> Result<(), Failure> {
    if value.get("schemaVersion").is_none() {
        let agent_type = agent_type.ok_or_else(|| {
            Failure::Terminal("AGENT_OUTPUT_SCHEMA_INVALID", "agent type missing".into())
        })?;
        return validate_authority_agent_output(agent_type, value).map_err(|error| {
            Failure::Terminal("AGENT_OUTPUT_SCHEMA_INVALID", error.to_string())
        });
    }
    let schema = value
        .get("schemaVersion")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::Terminal("AGENT_OUTPUT_SCHEMA_INVALID", "schemaVersion".into()))?;
    let expected = match agent_type {
        Some("market-researcher") => "market-research-output.v2",
        Some("investigator") => "investigator-output.v2",
        Some("skeptic") => "skeptic-output.v2",
        Some("claim-drafter") => "claim-draft-output.v2",
        Some("citation-verifier") => "citation-verification-output.v2",
        Some(_) => return Err(Failure::Terminal("AGENT_OUTPUT_SCHEMA_INVALID", "agent".into())),
        None => schema,
    };
    if schema != expected {
        return Err(Failure::Terminal("AGENT_OUTPUT_SCHEMA_INVALID", format!("schemaVersion:{schema}")));
    }
    let required: &[&str] = match schema {
        "market-research-output.v2" => &["schemaVersion", "outcome", "summary", "investigationsPerformed", "citations", "unknowns", "nextActions", "abstentionReasons", "comparables"],
        "investigator-output.v2" => &["schemaVersion", "outcome", "summary", "investigationsPerformed", "citations", "unknowns", "nextActions", "abstentionReasons", "hypotheses", "counterEvidence", "tasks"],
        "skeptic-output.v2" => &["schemaVersion", "outcome", "summary", "investigationsPerformed", "citations", "unknowns", "nextActions", "abstentionReasons", "challenges"],
        "claim-draft-output.v2" => &["schemaVersion", "outcome", "summary", "investigationsPerformed", "citations", "unknowns", "nextActions", "abstentionReasons", "claims", "communications"],
        "citation-verification-output.v2" => &["schemaVersion", "outcome", "summary", "investigationsPerformed", "citations", "unknowns", "nextActions", "abstentionReasons", "claimResults"],
        _ => return Err(Failure::Terminal("AGENT_OUTPUT_SCHEMA_INVALID", "schema".into())),
    };
    validate_object(value, ObjectSchema { required, allowed: required })
        .map_err(|error| Failure::Terminal("AGENT_OUTPUT_SCHEMA_INVALID", error.to_string()))?;
    if !matches!(value.get("outcome").and_then(Value::as_str), Some("COMPLETED" | "ABSTAINED"))
        || value.get("summary").and_then(Value::as_str).is_none_or(|text| text.trim().is_empty())
    {
        return Err(Failure::Terminal("AGENT_OUTPUT_SCHEMA_INVALID", "envelope".into()));
    }
    if let Some(object) = value.as_object() {
        non_empty_field(object, "summary")?;
    }
    for field in &required[3..] {
        if value.get(*field).and_then(Value::as_array).is_none() {
            return Err(Failure::Terminal("AGENT_OUTPUT_SCHEMA_INVALID", (*field).into()));
        }
    }
    let item_schema = schema;
    let agent_field = match schema {
        "market-research-output.v2" => "comparables",
        "investigator-output.v2" => "hypotheses",
        "skeptic-output.v2" => "challenges",
        "claim-draft-output.v2" => "claims",
        "citation-verification-output.v2" => "claimResults",
        _ => "",
    };
    if let Some(items) = value.get(agent_field).and_then(Value::as_array) {
        for item in items {
            validate_agent_item(item_schema, item)?;
        }
    }
    Ok(())
}

fn pointer_uuid(value: &Value, pointer: &str) -> Result<Uuid, Failure> {
    value
        .pointer(pointer)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| Failure::Terminal("INVALID_JOB_PAYLOAD", pointer.to_owned()))
}

fn payload_uuid(value: &Value, key: &str) -> Result<Uuid, Failure> {
    value
        .get(key)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| Failure::Terminal("INVALID_JOB_PAYLOAD", key.to_owned()))
}

fn json_uuids(value: Value) -> Result<Vec<Uuid>, Failure> {
    value
        .as_array()
        .ok_or_else(|| Failure::Terminal("AGENT_EVIDENCE_SCOPE_INVALID", "array".into()))?
        .iter()
        .map(|value| {
            value
                .as_str()
                .and_then(|value| Uuid::parse_str(value).ok())
                .ok_or_else(|| Failure::Terminal("AGENT_EVIDENCE_SCOPE_INVALID", "uuid".into()))
        })
        .collect()
}

fn database(error: sqlx::Error) -> Failure {
    Failure::Retryable("DATABASE_UNAVAILABLE", error.to_string())
}
