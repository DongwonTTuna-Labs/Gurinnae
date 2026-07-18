async fn evidence_snapshot(
    pool: &PgPool,
    case_id: Uuid,
    run_id: Uuid,
    ids: &[Uuid],
) -> Result<Value, Failure> {
    let value: Value = sqlx::query_scalar(
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
    )
    .bind(case_id)
    .bind(ids)
    .bind(run_id)
    .fetch_one(pool)
    .await
    .map_err(database)?;
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

fn blocked_output(status: &str, reason: &str) -> Value {
    json!({
        "status":status,
        "summary":"정책 또는 검증 조건을 충족하지 못해 결론을 생성하지 않았습니다.",
        "citations":[],"unknowns":[],"abstention_reasons":[reason],"recommended_actions":[]
    })
}

/// A local deterministic double is available only in non-production
/// environments. It supplies a complete provider-shaped result so policy
/// checks (prompt-injection, citation scope, and budget fences) can be tested
/// without pretending that a real external model was called.
fn deterministic_output(evidence: &Value) -> Value {
    let Some(first) = evidence.as_array().and_then(|items| items.first()) else {
        return blocked_output("ABSTAINED", "EVIDENCE_REQUIRED");
    };
    json!({
        "status":"COMPLETED",
        "summary":"검증된 편집 근거 snapshot을 읽기 전용으로 확인했습니다. 사람의 독립 검토가 필요합니다.",
        "citations":[{"evidence_id":first["id"],"locator":first["locator"],"supports":"검토 대상 근거 snapshot"}],
        "unknowns":[],"abstention_reasons":[],"recommended_actions":[]
    })
}

fn validate_agent_output(value: &Value) -> Result<(), Failure> {
    const REQUIRED: &[&str] = &[
        "status",
        "summary",
        "citations",
        "unknowns",
        "abstention_reasons",
    ];
    const ALLOWED: &[&str] = &[
        "status",
        "summary",
        "citations",
        "unknowns",
        "abstention_reasons",
        "recommended_actions",
        "comparables",
        "hypotheses",
        "alternative_explanations",
        "draft_claims",
        "verification_results",
    ];
    validate_object(
        value,
        ObjectSchema {
            required: REQUIRED,
            allowed: ALLOWED,
        },
    )
    .map_err(|error| Failure::Terminal("AGENT_OUTPUT_SCHEMA_INVALID", error.to_string()))?;
    let status = value.get("status").and_then(Value::as_str);
    if !matches!(
        status,
        Some("COMPLETED" | "ABSTAINED" | "POLICY_BLOCKED" | "BUDGET_BLOCKED")
    ) || value.get("summary").and_then(Value::as_str).is_none()
        || value.get("citations").and_then(Value::as_array).is_none()
        || value.get("unknowns").and_then(Value::as_array).is_none()
        || value
            .get("abstention_reasons")
            .and_then(Value::as_array)
            .is_none()
    {
        return Err(Failure::Terminal(
            "AGENT_OUTPUT_SCHEMA_INVALID",
            "field type".into(),
        ));
    }
    for citation in value["citations"].as_array().into_iter().flatten() {
        if citation
            .get("evidence_id")
            .and_then(Value::as_str)
            .is_none()
            || citation.get("locator").and_then(Value::as_str).is_none()
            || citation.get("supports").and_then(Value::as_str).is_none()
        {
            return Err(Failure::Terminal(
                "AGENT_OUTPUT_SCHEMA_INVALID",
                "citation".into(),
            ));
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

/// RFC 8785-compatible canonical JSON for the value shapes used by the
/// provider/addendum contracts.  Objects are sorted by UTF-16 code units and
/// numbers are kept in serde_json's lossless representation; provider
/// contracts only admit integer quantities, so no binary floating point
/// normalization is necessary here.
fn canonical_bytes(value: &Value) -> Result<Vec<u8>, Failure> {
    let mut out = String::new();
    write_jcs(value, &mut out)?;
    Ok(out.into_bytes())
}

fn write_jcs(value: &Value, out: &mut String) -> Result<(), Failure> {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(value) => out.push_str(if *value { "true" } else { "false" }),
        Value::Number(value) => {
            if !value.is_i64() && !value.is_u64() {
                return Err(Failure::Terminal(
                    "JSON_SERIALIZATION_FAILED",
                    "provider canonical JSON does not accept non-integer numbers".into(),
                ));
            }
            out.push_str(&value.to_string());
        }
        Value::String(value) => {
            let encoded = serde_json::to_string(value)
                .map_err(|error| Failure::Terminal("JSON_SERIALIZATION_FAILED", error.to_string()))?;
            out.push_str(&encoded);
        }
        Value::Array(values) => {
            out.push('[');
            for (index, value) in values.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_jcs(value, out)?;
            }
            out.push(']');
        }
        Value::Object(values) => {
            let mut keys = values.keys().collect::<Vec<_>>();
            keys.sort_by(|left, right| {
                left.encode_utf16().cmp(right.encode_utf16())
            });
            out.push('{');
            for (index, key) in keys.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                let encoded = serde_json::to_string(key)
                    .map_err(|error| Failure::Terminal("JSON_SERIALIZATION_FAILED", error.to_string()))?;
                out.push_str(&encoded);
                out.push(':');
                let Some(value) = values.get(*key) else {
                    return Err(Failure::Terminal(
                        "JSON_SERIALIZATION_FAILED",
                        "object key disappeared during canonicalization".into(),
                    ));
                };
                write_jcs(value, out)?;
            }
            out.push('}');
        }
    }
    Ok(())
}

fn sha256(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn database(error: sqlx::Error) -> Failure {
    Failure::Retryable("DATABASE_UNAVAILABLE", error.to_string())
}
