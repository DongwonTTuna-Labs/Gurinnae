fn decode_tool_request(
    tool_id: &str,
    arguments: Value,
) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    match tool_id {
        "agency.profile" => decode_agency_profile(arguments),
        "claim.language_check" => decode_claim_language_check(arguments),
        "contract.search" => decode_contract_search(arguments),
        "contract.find_comparables" => decode_contract_find_comparables(arguments),
        "entity.lookup" => decode_entity_lookup(arguments),
        "evidence.read" => decode_evidence_read(arguments),
        "evidence.search" => decode_evidence_search(arguments),
        "relationship.neighbors" => decode_relationship_neighbors(arguments),
        "response.read" => decode_response_read(arguments),
        "rule.reproduce" => decode_rule_reproduce(arguments),
        "source.fetch" => decode_source_fetch_request(arguments),
        "source.locator_verify" => decode_source_locator_verify(arguments),
        "supplier.profile" => decode_supplier_profile(arguments),
        _ => Err(Failure::Terminal(
            "PROVIDER_TOOL_CALL_INVALID",
            "toolId".into(),
        )),
    }
}

/// The authority provider schemas are closed V2 documents.  Do not deserialize
/// them directly into the legacy persistence request structs: those structs
/// intentionally use snake_case and contain only the fields needed by the
/// snapshot adapter.  This boundary performs the lossless contract check and
/// then projects the request into the internal type.
fn decode_v2_object(
    mut value: Value,
    schema: &str,
    binding: &gurine_agent_orchestration::runtime::SnapshotBinding,
    fields: &[&str],
) -> Result<serde_json::Map<String, Value>, Failure> {
    let object = value
        .as_object_mut()
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "request.object".into()))?;
    let binding_value = object
        .remove("binding")
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "request.binding".into()))?;
    let actual: gurine_agent_orchestration::runtime::SnapshotBinding =
        serde_json::from_value(binding_value).map_err(tool_decode)?;
    if &actual != binding {
        return Err(Failure::Terminal(
            "PROVIDER_TOOL_CALL_INVALID",
            "binding_mismatch".into(),
        ));
    }
    if object.keys().any(|key| !fields.contains(&key.as_str())) {
        return Err(Failure::Terminal(
            "PROVIDER_TOOL_CALL_INVALID",
            "unknown_field".into(),
        ));
    }
    let schema_version = object
        .get("schemaVersion")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "schemaVersion".into()))?;
    if schema_version != schema {
        return Err(Failure::Terminal(
            "PROVIDER_TOOL_CALL_INVALID",
            "schemaVersion".into(),
        ));
    }
    let run_id = object
        .get("runId")
        .and_then(Value::as_str)
        .and_then(|v| Uuid::parse_str(v).ok())
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "runId".into()))?;
    let snapshot_id = object
        .get("inputSnapshotId")
        .and_then(Value::as_str)
        .and_then(|v| Uuid::parse_str(v).ok())
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "inputSnapshotId".into()))?;
    let snapshot_sha = object
        .get("inputSnapshotSha256")
        .and_then(Value::as_str)
        .filter(|value| is_sha256_text(value))
        .ok_or_else(|| {
            Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "inputSnapshotSha256".into())
        })?;
    if run_id != binding.run_id
        || snapshot_id != binding.input_snapshot_id
        || snapshot_sha != binding.input_snapshot_sha256
    {
        return Err(Failure::Terminal(
            "PROVIDER_TOOL_CALL_INVALID",
            "binding_mismatch".into(),
        ));
    }
    Ok(object.clone())
}

fn internal_binding(
    object: &serde_json::Map<String, Value>,
) -> Result<gurine_agent_orchestration::runtime::SnapshotBinding, Failure> {
    Ok(gurine_agent_orchestration::runtime::SnapshotBinding {
        run_id: Uuid::parse_str(
            object
                .get("runId")
                .and_then(Value::as_str)
                .unwrap_or_default(),
        )
        .map_err(|_| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "runId".into()))?,
        input_snapshot_id: Uuid::parse_str(
            object
                .get("inputSnapshotId")
                .and_then(Value::as_str)
                .unwrap_or_default(),
        )
        .map_err(|_| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "inputSnapshotId".into()))?,
        input_snapshot_sha256: object
            .get("inputSnapshotSha256")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "inputSnapshotSha256".into())
            })?
            .to_owned(),
    })
}

fn required_string(object: &serde_json::Map<String, Value>, key: &str) -> Result<String, Failure> {
    object
        .get(key)
        .and_then(Value::as_str)
        .filter(|v| !v.trim().is_empty())
        .map(str::to_owned)
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", key.into()))
}

fn required_uuid(object: &serde_json::Map<String, Value>, key: &str) -> Result<Uuid, Failure> {
    Uuid::parse_str(&required_string(object, key)?)
        .map_err(|_| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", key.into()))
}

fn require_keys(object: &serde_json::Map<String, Value>, keys: &[&str]) -> Result<(), Failure> {
    for key in keys {
        if !object.contains_key(*key) {
            return Err(Failure::Terminal(
                "PROVIDER_TOOL_CALL_INVALID",
                (*key).into(),
            ));
        }
    }
    Ok(())
}

fn uuid_array(
    object: &serde_json::Map<String, Value>,
    key: &str,
    max_items: usize,
) -> Result<Vec<Uuid>, Failure> {
    let values = object
        .get(key)
        .and_then(Value::as_array)
        .filter(|values| values.len() <= max_items)
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", key.into()))?;
    let mut result = Vec::with_capacity(values.len());
    for value in values {
        let id = value
            .as_str()
            .and_then(|text| Uuid::parse_str(text).ok())
            .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", key.into()))?;
        if result.contains(&id) {
            return Err(Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", key.into()));
        }
        result.push(id);
    }
    Ok(result)
}

fn optional_uuid(
    object: &serde_json::Map<String, Value>,
    key: &str,
) -> Result<Option<Uuid>, Failure> {
    match object.get(key) {
        Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Uuid::parse_str(value)
            .map(Some)
            .map_err(|_| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", key.into())),
        _ => Err(Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", key.into())),
    }
}

fn optional_date(
    object: &serde_json::Map<String, Value>,
    key: &str,
) -> Result<Option<String>, Failure> {
    match object.get(key) {
        Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if valid_date(value) => Ok(Some(value.clone())),
        _ => Err(Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", key.into())),
    }
}

fn valid_date(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 10
        && bytes[0..4].iter().all(u8::is_ascii_digit)
        && bytes[4] == b'-'
        && bytes[5..7].iter().all(u8::is_ascii_digit)
        && bytes[7] == b'-'
        && bytes[8..10].iter().all(u8::is_ascii_digit)
}

fn string_array(
    object: &serde_json::Map<String, Value>,
    key: &str,
    max_items: usize,
    max_length: usize,
) -> Result<Vec<String>, Failure> {
    let values = object
        .get(key)
        .and_then(Value::as_array)
        .filter(|values| values.len() <= max_items)
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", key.into()))?;
    let mut result = Vec::with_capacity(values.len());
    for value in values {
        let text = value
            .as_str()
            .filter(|text| !text.trim().is_empty() && text.len() <= max_length)
            .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", key.into()))?;
        if result.iter().any(|existing| existing == text) {
            return Err(Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", key.into()));
        }
        result.push(text.to_owned());
    }
    Ok(result)
}

fn bounded_u8(
    object: &serde_json::Map<String, Value>,
    key: &str,
    minimum: u8,
    maximum: u8,
) -> Result<u8, Failure> {
    object
        .get(key)
        .and_then(Value::as_u64)
        .and_then(|value| u8::try_from(value).ok())
        .filter(|value| (minimum..=maximum).contains(value))
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", key.into()))
}

const CLAIM_LANGUAGE_CHECK_FIELDS: [&str; 12] = [
    "schemaVersion",
    "runId",
    "inputSnapshotId",
    "inputSnapshotSha256",
    "draftText",
    "draftTextSha256",
    "claimType",
    "locale",
    "allowedCitationIds",
    "languagePolicyVersion",
    "languagePolicySha256",
    "maxFindings",
];

const CLAIM_LANGUAGE_CHECK_REQUIRED_FIELDS: [&str; 8] = [
    "draftText",
    "draftTextSha256",
    "claimType",
    "locale",
    "allowedCitationIds",
    "languagePolicyVersion",
    "languagePolicySha256",
    "maxFindings",
];

fn claim_language_check_object(
    value: Value,
) -> Result<
    (
        gurine_agent_orchestration::runtime::SnapshotBinding,
        serde_json::Map<String, Value>,
    ),
    Failure,
> {
    let object = value
        .as_object()
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "request.object".into()))?;
    let binding = internal_binding(object)?;
    let object = decode_v2_object(
        value,
        "claim.language_check.request.v2",
        &binding,
        &CLAIM_LANGUAGE_CHECK_FIELDS,
    )?;
    require_keys(&object, &CLAIM_LANGUAGE_CHECK_REQUIRED_FIELDS)?;
    Ok((binding, object))
}

fn claim_language_check_draft(
    object: &serde_json::Map<String, Value>,
) -> Result<(String, String), Failure> {
    let draft = required_string(object, "draftText")?;
    let draft_text_sha256 = required_string(object, "draftTextSha256")?;
    if draft.len() > 10_000 || draft_text_sha256 != sha256(draft.as_bytes()) {
        return Err(Failure::Terminal(
            "PROVIDER_TOOL_CALL_INVALID",
            "draftTextSha256".into(),
        ));
    }
    Ok((draft, draft_text_sha256))
}

fn claim_language_check_type(
    object: &serde_json::Map<String, Value>,
) -> Result<gurine_agent_orchestration::runtime::ClaimType, Failure> {
    use gurine_agent_orchestration::runtime::ClaimType;
    let claim_type = match required_string(object, "claimType")?.as_str() {
        "FACT" => ClaimType::Fact,
        "CALCULATION" => ClaimType::Calculation,
        "INFERENCE" => ClaimType::Inference,
        "LIMITATION" => ClaimType::Limitation,
        "OFFICIAL_OUTCOME" => ClaimType::OfficialOutcome,
        _ => {
            return Err(Failure::Terminal(
                "PROVIDER_TOOL_CALL_INVALID",
                "claimType".into(),
            ));
        }
    };
    Ok(claim_type)
}

fn claim_language_check_locale(
    object: &serde_json::Map<String, Value>,
) -> Result<gurine_agent_orchestration::runtime::ClaimLocale, Failure> {
    use gurine_agent_orchestration::runtime::ClaimLocale;
    let locale = match required_string(object, "locale")?.as_str() {
        "ko-KR" => ClaimLocale::KoKr,
        "en-US" => ClaimLocale::EnUs,
        _ => {
            return Err(Failure::Terminal(
                "PROVIDER_TOOL_CALL_INVALID",
                "locale".into(),
            ));
        }
    };
    Ok(locale)
}

fn claim_language_check_policy(
    object: &serde_json::Map<String, Value>,
) -> Result<(String, String), Failure> {
    use gurine_publication_policy::language::{LANGUAGE_POLICY_VERSION, language_policy_sha256};
    let language_policy_version = required_string(object, "languagePolicyVersion")?;
    let language_policy_digest = required_string(object, "languagePolicySha256")?;
    if language_policy_version != LANGUAGE_POLICY_VERSION
        || language_policy_digest != language_policy_sha256()
    {
        return Err(Failure::Terminal(
            "PROVIDER_TOOL_CALL_INVALID",
            "languagePolicyVersion".into(),
        ));
    }
    Ok((language_policy_version, language_policy_digest))
}

fn decode_claim_language_check(
    value: Value,
) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    use gurine_agent_orchestration::runtime::{ClaimLanguageCheckRequest, ToolRequest};
    let (binding, object) = claim_language_check_object(value)?;
    let (draft_text, draft_text_sha256) = claim_language_check_draft(&object)?;
    let claim_type = claim_language_check_type(&object)?;
    let locale = claim_language_check_locale(&object)?;
    let allowed_citation_ids = uuid_array(&object, "allowedCitationIds", 100)?;
    let (language_policy_version, language_policy_sha256) = claim_language_check_policy(&object)?;
    let max_findings = bounded_u8(&object, "maxFindings", 1, 50)?;
    Ok(ToolRequest::ClaimLanguageCheck(ClaimLanguageCheckRequest {
        binding,
        draft_text,
        draft_text_sha256,
        claim_type,
        locale,
        allowed_citation_ids,
        language_policy_version,
        language_policy_sha256,
        max_findings,
    }))
}

fn decode_contract_search(
    value: Value,
) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    use gurine_agent_orchestration::runtime::{
        ContractEntityKind, ContractSearchRequest, ToolRequest,
    };
    let fields = [
        "schemaVersion",
        "runId",
        "inputSnapshotId",
        "inputSnapshotSha256",
        "entityKind",
        "entityId",
        "fromDate",
        "toDate",
        "procurementMethods",
        "limit",
    ];
    let object = value
        .as_object()
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "request.object".into()))?;
    let binding = internal_binding(object)?;
    let object = decode_v2_object(value, "contract.search.request.v2", &binding, &fields)?;
    require_keys(&object, &fields[4..])?;
    let entity_kind = match required_string(&object, "entityKind")?.as_str() {
        "ANY" => ContractEntityKind::Any,
        "AGENCY" => ContractEntityKind::Agency,
        "SUPPLIER" => ContractEntityKind::Supplier,
        _ => {
            return Err(Failure::Terminal(
                "PROVIDER_TOOL_CALL_INVALID",
                "entityKind".into(),
            ));
        }
    };
    let entity_id = optional_uuid(&object, "entityId")?;
    if matches!(entity_kind, ContractEntityKind::Any) != entity_id.is_none() {
        return Err(Failure::Terminal(
            "PROVIDER_TOOL_CALL_INVALID",
            "entityId".into(),
        ));
    }
    let from_date = optional_date(&object, "fromDate")?;
    let to_date = optional_date(&object, "toDate")?;
    if from_date
        .as_ref()
        .zip(to_date.as_ref())
        .is_some_and(|(from, to)| from > to)
    {
        return Err(Failure::Terminal(
            "PROVIDER_TOOL_CALL_INVALID",
            "dateRange".into(),
        ));
    }
    Ok(ToolRequest::ContractSearch(ContractSearchRequest {
        binding,
        entity_kind,
        entity_id,
        from_date,
        to_date,
        procurement_methods: string_array(&object, "procurementMethods", 20, 200)?,
        limit: bounded_u8(&object, "limit", 1, 50)?,
    }))
}

fn decode_supplier_profile(
    value: Value,
) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    use gurine_agent_orchestration::runtime::{SupplierProfileRequest, ToolRequest};
    let fields = [
        "schemaVersion",
        "runId",
        "inputSnapshotId",
        "inputSnapshotSha256",
        "supplierId",
    ];
    let object = value
        .as_object()
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "request.object".into()))?;
    let binding = internal_binding(object)?;
    let object = decode_v2_object(value, "supplier.profile.request.v2", &binding, &fields)?;
    require_keys(&object, &["supplierId"])?;
    Ok(ToolRequest::SupplierProfile(SupplierProfileRequest {
        binding,
        supplier_id: required_uuid(&object, "supplierId")?,
    }))
}

fn decode_agency_profile(
    value: Value,
) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    use gurine_agent_orchestration::runtime::{AgencyProfileRequest, ToolRequest};
    let fields = [
        "schemaVersion",
        "runId",
        "inputSnapshotId",
        "inputSnapshotSha256",
        "agencyId",
    ];
    let object = value
        .as_object()
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "request.object".into()))?;
    let binding = internal_binding(object)?;
    let object = decode_v2_object(value, "agency.profile.request.v2", &binding, &fields)?;
    require_keys(&object, &["agencyId"])?;
    Ok(ToolRequest::AgencyProfile(AgencyProfileRequest {
        binding,
        agency_id: required_uuid(&object, "agencyId")?,
    }))
}

include!("analysis_tool_decode_relationship.rs");
include!("analysis_tool_decode_other.rs");
