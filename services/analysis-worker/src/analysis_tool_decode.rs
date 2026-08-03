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
        _ => Err(Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "toolId".into())),
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
        return Err(Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "binding_mismatch".into()));
    }
    if object.keys().any(|key| !fields.contains(&key.as_str())) {
        return Err(Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "unknown_field".into()));
    }
    let schema_version = object
        .get("schemaVersion")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "schemaVersion".into()))?;
    if schema_version != schema {
        return Err(Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "schemaVersion".into()));
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
        .filter(|v| v.len() == 64 && v.bytes().all(|b| b.is_ascii_hexdigit()))
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "inputSnapshotSha256".into()))?;
    if run_id != binding.run_id
        || snapshot_id != binding.input_snapshot_id
        || snapshot_sha != binding.input_snapshot_sha256
    {
        return Err(Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "binding_mismatch".into()));
    }
    Ok(object.clone())
}

fn internal_binding(
    object: &serde_json::Map<String, Value>,
) -> Result<gurine_agent_orchestration::runtime::SnapshotBinding, Failure> {
    Ok(gurine_agent_orchestration::runtime::SnapshotBinding {
        run_id: Uuid::parse_str(object.get("runId").and_then(Value::as_str).unwrap_or_default())
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
            .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "inputSnapshotSha256".into()))?
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
            return Err(Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", (*key).into()));
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

fn decode_claim_language_check(
    value: Value,
) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    use gurine_agent_orchestration::runtime::{ClaimLanguageCheckRequest, ClaimLocale, ClaimType};
    use gurine_publication_policy::language::{LANGUAGE_POLICY_VERSION, language_policy_sha256};
    let fields = ["schemaVersion", "runId", "inputSnapshotId", "inputSnapshotSha256", "draftText", "draftTextSha256", "claimType", "locale", "allowedCitationIds", "languagePolicyVersion", "languagePolicySha256", "maxFindings"];
    let object = value.as_object().ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "request.object".into()))?;
    let binding = internal_binding(object)?;
    let object = decode_v2_object(value, "claim.language_check.request.v2", &binding, &fields)?;
    require_keys(&object, &["draftText", "draftTextSha256", "claimType", "locale", "allowedCitationIds", "languagePolicyVersion", "languagePolicySha256", "maxFindings"])?;
    let draft = required_string(&object, "draftText")?;
    let draft_text_sha256 = required_string(&object, "draftTextSha256")?;
    if draft.len() > 10_000 || draft_text_sha256 != sha256(draft.as_bytes()) {
        return Err(Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "draftTextSha256".into()));
    }
    let claim_type = match required_string(&object, "claimType")?.as_str() {
        "FACT" => ClaimType::Fact,
        "CALCULATION" => ClaimType::Calculation,
        "INFERENCE" => ClaimType::Inference,
        "LIMITATION" => ClaimType::Limitation,
        "OFFICIAL_OUTCOME" => ClaimType::OfficialOutcome,
        _ => return Err(Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "claimType".into())),
    };
    let locale = match required_string(&object, "locale")?.as_str() {
        "ko-KR" => ClaimLocale::KoKr,
        "en-US" => ClaimLocale::EnUs,
        _ => return Err(Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "locale".into())),
    };
    let allowed_citation_ids = uuid_array(&object, "allowedCitationIds", 100)?;
    let language_policy_version = required_string(&object, "languagePolicyVersion")?;
    let language_policy_digest = required_string(&object, "languagePolicySha256")?;
    if language_policy_version != LANGUAGE_POLICY_VERSION
        || language_policy_digest != language_policy_sha256()
    {
        return Err(Failure::Terminal(
            "PROVIDER_TOOL_CALL_INVALID",
            "languagePolicyVersion".into(),
        ));
    }
    let max_findings = object
        .get("maxFindings")
        .and_then(Value::as_u64)
        .and_then(|value| u8::try_from(value).ok())
        .filter(|value| (1..=50).contains(value))
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "maxFindings".into()))?;
    Ok(gurine_agent_orchestration::runtime::ToolRequest::ClaimLanguageCheck(
        ClaimLanguageCheckRequest {
            binding,
            draft_text: draft,
            draft_text_sha256,
            claim_type,
            locale,
            allowed_citation_ids,
            language_policy_version,
            language_policy_sha256: language_policy_digest,
            max_findings,
        },
    ))
}

fn decode_contract_search(
    value: Value,
) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    use gurine_agent_orchestration::runtime::{
        ContractEntityKind, ContractSearchRequest, ToolRequest,
    };
    let fields = [
        "schemaVersion", "runId", "inputSnapshotId", "inputSnapshotSha256", "entityKind",
        "entityId", "fromDate", "toDate", "procurementMethods", "limit",
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
        _ => return Err(Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "entityKind".into())),
    };
    let entity_id = optional_uuid(&object, "entityId")?;
    if matches!(entity_kind, ContractEntityKind::Any) != entity_id.is_none() {
        return Err(Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "entityId".into()));
    }
    let from_date = optional_date(&object, "fromDate")?;
    let to_date = optional_date(&object, "toDate")?;
    if from_date.as_ref().zip(to_date.as_ref()).is_some_and(|(from, to)| from > to) {
        return Err(Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "dateRange".into()));
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
        "schemaVersion", "runId", "inputSnapshotId", "inputSnapshotSha256", "supplierId",
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
        "schemaVersion", "runId", "inputSnapshotId", "inputSnapshotSha256", "agencyId",
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

fn decode_relationship_neighbors(
    value: Value,
) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    use gurine_agent_orchestration::runtime::{
        RelationshipKind, RelationshipNeighborsRequest, ToolRequest,
    };
    let fields = [
        "schemaVersion", "runId", "inputSnapshotId", "inputSnapshotSha256", "supplierId",
        "relationshipKinds", "asOf", "limit",
    ];
    let object = value
        .as_object()
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "request.object".into()))?;
    let binding = internal_binding(object)?;
    let object = decode_v2_object(value, "relationship.neighbors.request.v2", &binding, &fields)?;
    require_keys(&object, &fields[4..])?;
    let raw_kinds = string_array(&object, "relationshipKinds", 6, 64)?;
    let relationship_kinds = raw_kinds
        .iter()
        .map(|kind| match kind.as_str() {
            "OWNERSHIP" => Ok(RelationshipKind::Ownership),
            "BENEFICIAL_OWNERSHIP" => Ok(RelationshipKind::BeneficialOwnership),
            "CONTROL" => Ok(RelationshipKind::Control),
            "MANAGEMENT_ROLE" => Ok(RelationshipKind::ManagementRole),
            "LEGAL_REPRESENTATIVE" => Ok(RelationshipKind::LegalRepresentative),
            "CONTRACTUAL_RELATIONSHIP" => Ok(RelationshipKind::ContractualRelationship),
            _ => Err(Failure::Terminal(
                "PROVIDER_TOOL_CALL_INVALID",
                "relationshipKinds".into(),
            )),
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(ToolRequest::RelationshipNeighbors(RelationshipNeighborsRequest {
        binding,
        supplier_id: required_uuid(&object, "supplierId")?,
        relationship_kinds,
        as_of: optional_date(&object, "asOf")?,
        limit: bounded_u8(&object, "limit", 1, 50)?,
    }))
}

fn decode_contract_find_comparables(value: Value) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    use gurine_agent_orchestration::runtime::ContractFindComparablesRequest;
    let fields = ["schemaVersion", "runId", "inputSnapshotId", "inputSnapshotSha256", "subjectContractId", "subjectContractVersion", "asOf", "comparisonBasis", "geographyCodes", "procurementCategoryCodes", "awardMethods", "valueBand", "currency", "maxResults"];
    let object = value.as_object().ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "request.object".into()))?;
    let binding = internal_binding(object)?;
    let object = decode_v2_object(value, "contract.find_comparables.request.v2", &binding, &fields)?;
    require_keys(&object, &["subjectContractId", "subjectContractVersion", "asOf", "comparisonBasis", "geographyCodes", "procurementCategoryCodes", "awardMethods", "valueBand", "currency", "maxResults"])?;
    Ok(gurine_agent_orchestration::runtime::ToolRequest::ContractFindComparables(ContractFindComparablesRequest { binding, subject_contract_id: required_uuid(&object, "subjectContractId")? }))
}

fn decode_entity_lookup(value: Value) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    use gurine_agent_orchestration::runtime::{EntityIdentifier, EntityIdentifierKind, EntityKind, EntityLookupRequest};
    let fields = ["schemaVersion", "runId", "inputSnapshotId", "inputSnapshotSha256", "entityKind", "identifiers", "asOf", "requestedFields", "identityStates", "maxResults"];
    let object = value.as_object().ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "request.object".into()))?;
    let binding = internal_binding(object)?;
    let object = decode_v2_object(value, "entity.lookup.request.v2", &binding, &fields)?;
    require_keys(&object, &["entityKind", "identifiers", "asOf", "requestedFields", "identityStates", "maxResults"])?;
    let entity_kind = match required_string(&object, "entityKind")?.as_str() { "AGENCY" => EntityKind::Agency, "SUPPLIER" => EntityKind::Supplier, _ => return Err(Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "entityKind".into())) };
    let raw = object.get("identifiers").and_then(Value::as_array).ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "identifiers".into()))?;
    if raw.is_empty() || raw.len() > 20 { return Err(Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "identifiers".into())); }
    let mut identifiers = Vec::with_capacity(raw.len());
    for item in raw {
        let obj = item.as_object().ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "identifiers".into()))?;
        let kind = match required_string(obj, "kind")?.as_str() { "CANONICAL_NAME" => EntityIdentifierKind::CanonicalName, "BUSINESS_REGISTRATION_NUMBER" => EntityIdentifierKind::BusinessRegistrationNumber, "AGENCY_CODE" => EntityIdentifierKind::AgencyCode, "PUBLIC_SLUG" => EntityIdentifierKind::PublicSlug, "VERIFIED_ALIAS" => EntityIdentifierKind::VerifiedAlias, _ => return Err(Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "identifier.kind".into())) };
        identifiers.push(EntityIdentifier { kind, value: required_string(obj, "value")? });
    }
    Ok(gurine_agent_orchestration::runtime::ToolRequest::EntityLookup(EntityLookupRequest { binding, entity_kind, identifiers }))
}

fn decode_evidence_read(value: Value) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    use gurine_agent_orchestration::runtime::EvidenceReadRequest;
    let fields = ["schemaVersion", "runId", "inputSnapshotId", "inputSnapshotSha256", "evidenceId", "evidenceVersion", "requestedSegmentIds", "includePublicExcerpt", "maxCharacters"];
    let object = value.as_object().ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "request.object".into()))?;
    let binding = internal_binding(object)?;
    let object = decode_v2_object(value, "evidence.read.request.v2", &binding, &fields)?;
    require_keys(&object, &["evidenceId", "evidenceVersion", "requestedSegmentIds", "includePublicExcerpt", "maxCharacters"])?;
    Ok(gurine_agent_orchestration::runtime::ToolRequest::EvidenceRead(EvidenceReadRequest { binding, evidence_id: required_uuid(&object, "evidenceId")? }))
}

fn decode_evidence_search(value: Value) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    use gurine_agent_orchestration::runtime::EvidenceSearchRequest;
    let fields = ["schemaVersion", "runId", "inputSnapshotId", "inputSnapshotSha256", "query", "queryLanguage", "evidenceTypes", "verificationStates", "classifications", "sourceAuthorities", "sort", "cursor", "limit"];
    let object = value.as_object().ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "request.object".into()))?;
    let binding = internal_binding(object)?;
    let object = decode_v2_object(value, "evidence.search.request.v2", &binding, &fields)?;
    require_keys(&object, &["query", "queryLanguage", "evidenceTypes", "verificationStates", "classifications", "sourceAuthorities", "sort", "cursor", "limit"])?;
    Ok(gurine_agent_orchestration::runtime::ToolRequest::EvidenceSearch(EvidenceSearchRequest { binding, query: required_string(&object, "query")? }))
}

fn decode_response_read(value: Value) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    use gurine_agent_orchestration::runtime::ResponseReadRequest;
    let fields = ["schemaVersion", "runId", "inputSnapshotId", "inputSnapshotSha256", "responseId", "responseVersion", "includeAttachments", "includeConsent", "maxCharacters"];
    let object = value.as_object().ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "request.object".into()))?;
    let binding = internal_binding(object)?;
    let object = decode_v2_object(value, "response.read.request.v2", &binding, &fields)?;
    require_keys(&object, &["responseId", "responseVersion", "includeAttachments", "includeConsent", "maxCharacters"])?;
    Ok(gurine_agent_orchestration::runtime::ToolRequest::ResponseRead(ResponseReadRequest { binding, response_id: required_uuid(&object, "responseId")? }))
}

fn decode_rule_reproduce(value: Value) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    use gurine_agent_orchestration::runtime::RuleReproduceRequest;
    let fields = ["schemaVersion", "runId", "inputSnapshotId", "inputSnapshotSha256", "ruleId", "ruleVersionId", "ruleCodeSha256", "ruleConfigurationSha256", "detectionSnapshotId", "detectionSnapshotSha256", "subjectMembers", "expectedSignalId", "traceLevel"];
    let object = value.as_object().ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "request.object".into()))?;
    let binding = internal_binding(object)?;
    let object = decode_v2_object(value, "rule.reproduce.request.v2", &binding, &fields)?;
    require_keys(&object, &["ruleId", "ruleVersionId", "ruleCodeSha256", "ruleConfigurationSha256", "detectionSnapshotId", "detectionSnapshotSha256", "subjectMembers", "expectedSignalId", "traceLevel"])?;
    Ok(gurine_agent_orchestration::runtime::ToolRequest::RuleReproduce(RuleReproduceRequest { binding, rule_version_id: required_uuid(&object, "ruleVersionId")? }))
}

fn decode_source_locator_verify(value: Value) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    use gurine_agent_orchestration::runtime::SourceLocatorVerifyRequest;
    let fields = ["schemaVersion", "runId", "inputSnapshotId", "inputSnapshotSha256", "sourceKind", "sourceIdentity", "locator", "expectedSelectedContentSha256", "expectedSupportsSha256", "normalizationVersion"];
    let object = value.as_object().ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "request.object".into()))?;
    let binding = internal_binding(object)?;
    let object = decode_v2_object(value, "source.locator_verify.request.v2", &binding, &fields)?;
    require_keys(&object, &["sourceKind", "sourceIdentity", "locator", "expectedSelectedContentSha256", "expectedSupportsSha256", "normalizationVersion"])?;
    let expected = required_string(&object, "expectedSelectedContentSha256")?;
    if expected.len() != 64 || !expected.bytes().all(|b| b.is_ascii_hexdigit()) { return Err(Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "expectedSelectedContentSha256".into())); }
    Ok(gurine_agent_orchestration::runtime::ToolRequest::SourceLocatorVerify(SourceLocatorVerifyRequest { binding, expected_selected_content_sha256: expected }))
}

fn decode_source_fetch_request(
    mut arguments: Value,
) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    use gurine_agent_orchestration::runtime::{SnapshotBinding, SourceFetchRequest, SourceFetchRequestV2};
    let object = arguments
        .as_object_mut()
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "source.fetch.object".into()))?;
    let binding_value = object
        .remove("binding")
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "source.fetch.binding".into()))?;
    let binding: SnapshotBinding = serde_json::from_value(binding_value).map_err(tool_decode)?;
    let request_kind = object
        .get("requestKind")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "source.fetch.requestKind".into()))?;
    let allowed = match request_kind {
        "SEARCH_PUBLIC_WEB" => [
            "schemaVersion", "runId", "inputSnapshotId", "inputSnapshotSha256", "requestKind",
            "query", "locale", "country", "recencyDays", "resultLimit", "sourcePolicyVersion",
            "sourcePolicySha256", "rightsPurpose", "maxBytesPerArtifact",
        ].as_slice(),
        "FETCH_URL" => [
            "schemaVersion", "runId", "inputSnapshotId", "inputSnapshotSha256", "requestKind",
            "url", "expectedMediaTypes", "sourcePolicyVersion", "sourcePolicySha256", "rightsPurpose",
            "maxBytes", "allowRedirects",
        ].as_slice(),
        _ => return Err(Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "source.fetch.requestKind".into())),
    };
    if object.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err(Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "source.fetch.unknown_field".into()));
    }
    let wire: SourceFetchRequestV2 = serde_json::from_value(Value::Object(object.clone())).map_err(tool_decode)?;
    let binding_matches = match &wire {
        SourceFetchRequestV2::SearchPublicWeb { run_id, input_snapshot_id, input_snapshot_sha256, .. }
        | SourceFetchRequestV2::FetchUrl { run_id, input_snapshot_id, input_snapshot_sha256, .. } => {
            *run_id == binding.run_id
                && *input_snapshot_id == binding.input_snapshot_id
                && input_snapshot_sha256 == &binding.input_snapshot_sha256
        }
    };
    if !binding_matches {
        return Err(Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "source.fetch.binding_mismatch".into()));
    }
    SourceFetchRequest::from_v2(wire, binding)
        .map(gurine_agent_orchestration::runtime::ToolRequest::SourceFetch)
        .map_err(|error| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", error.to_string()))
}

fn tool_decode(error: serde_json::Error) -> Failure {
    Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", error.to_string())
}
