fn decode_contract_find_comparables(
    value: Value,
) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    use gurine_agent_orchestration::runtime::ContractFindComparablesRequest;
    let fields = [
        "schemaVersion",
        "runId",
        "inputSnapshotId",
        "inputSnapshotSha256",
        "subjectContractId",
        "subjectContractVersion",
        "asOf",
        "comparisonBasis",
        "geographyCodes",
        "procurementCategoryCodes",
        "awardMethods",
        "valueBand",
        "currency",
        "maxResults",
    ];
    let object = value
        .as_object()
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "request.object".into()))?;
    let binding = internal_binding(object)?;
    let object = decode_v2_object(
        value,
        "contract.find_comparables.request.v2",
        &binding,
        &fields,
    )?;
    require_keys(
        &object,
        &[
            "subjectContractId",
            "subjectContractVersion",
            "asOf",
            "comparisonBasis",
            "geographyCodes",
            "procurementCategoryCodes",
            "awardMethods",
            "valueBand",
            "currency",
            "maxResults",
        ],
    )?;
    Ok(
        gurine_agent_orchestration::runtime::ToolRequest::ContractFindComparables(
            ContractFindComparablesRequest {
                binding,
                subject_contract_id: required_uuid(&object, "subjectContractId")?,
            },
        ),
    )
}

fn decode_entity_lookup(
    value: Value,
) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    use gurine_agent_orchestration::runtime::EntityLookupRequest;
    let fields = [
        "schemaVersion",
        "runId",
        "inputSnapshotId",
        "inputSnapshotSha256",
        "entityKind",
        "identifiers",
        "asOf",
        "requestedFields",
        "identityStates",
        "maxResults",
    ];
    let object = value
        .as_object()
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "request.object".into()))?;
    let binding = internal_binding(object)?;
    let object = decode_v2_object(value, "entity.lookup.request.v2", &binding, &fields)?;
    require_keys(
        &object,
        &[
            "entityKind",
            "identifiers",
            "asOf",
            "requestedFields",
            "identityStates",
            "maxResults",
        ],
    )?;
    let entity_kind = decode_entity_kind(&object)?;
    let identifiers = decode_entity_identifiers(&object)?;
    Ok(
        gurine_agent_orchestration::runtime::ToolRequest::EntityLookup(EntityLookupRequest {
            binding,
            entity_kind,
            identifiers,
        }),
    )
}

fn decode_entity_kind(
    object: &serde_json::Map<String, Value>,
) -> Result<gurine_agent_orchestration::runtime::EntityKind, Failure> {
    use gurine_agent_orchestration::runtime::EntityKind;

    match required_string(object, "entityKind")?.as_str() {
        "AGENCY" => Ok(EntityKind::Agency),
        "SUPPLIER" => Ok(EntityKind::Supplier),
        _ => Err(Failure::Terminal(
            "PROVIDER_TOOL_CALL_INVALID",
            "entityKind".into(),
        )),
    }
}

fn decode_entity_identifiers(
    object: &serde_json::Map<String, Value>,
) -> Result<Vec<gurine_agent_orchestration::runtime::EntityIdentifier>, Failure> {
    let raw = object
        .get("identifiers")
        .and_then(Value::as_array)
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "identifiers".into()))?;
    if raw.is_empty() || raw.len() > 20 {
        return Err(Failure::Terminal(
            "PROVIDER_TOOL_CALL_INVALID",
            "identifiers".into(),
        ));
    }
    let mut identifiers = Vec::with_capacity(raw.len());
    for item in raw {
        identifiers.push(decode_entity_identifier(item)?);
    }
    Ok(identifiers)
}

fn decode_entity_identifier(
    value: &Value,
) -> Result<gurine_agent_orchestration::runtime::EntityIdentifier, Failure> {
    use gurine_agent_orchestration::runtime::{EntityIdentifier, EntityIdentifierKind};

    let object = value
        .as_object()
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "identifiers".into()))?;
    let kind = match required_string(object, "kind")?.as_str() {
        "CANONICAL_NAME" => EntityIdentifierKind::CanonicalName,
        "BUSINESS_REGISTRATION_NUMBER" => EntityIdentifierKind::BusinessRegistrationNumber,
        "AGENCY_CODE" => EntityIdentifierKind::AgencyCode,
        "PUBLIC_SLUG" => EntityIdentifierKind::PublicSlug,
        "VERIFIED_ALIAS" => EntityIdentifierKind::VerifiedAlias,
        _ => {
            return Err(Failure::Terminal(
                "PROVIDER_TOOL_CALL_INVALID",
                "identifier.kind".into(),
            ));
        }
    };
    Ok(EntityIdentifier {
        kind,
        value: required_string(object, "value")?,
    })
}

fn decode_evidence_read(
    value: Value,
) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    use gurine_agent_orchestration::runtime::EvidenceReadRequest;
    let fields = [
        "schemaVersion",
        "runId",
        "inputSnapshotId",
        "inputSnapshotSha256",
        "evidenceId",
        "evidenceVersion",
        "requestedSegmentIds",
        "includePublicExcerpt",
        "maxCharacters",
    ];
    let object = value
        .as_object()
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "request.object".into()))?;
    let binding = internal_binding(object)?;
    let object = decode_v2_object(value, "evidence.read.request.v2", &binding, &fields)?;
    require_keys(
        &object,
        &[
            "evidenceId",
            "evidenceVersion",
            "requestedSegmentIds",
            "includePublicExcerpt",
            "maxCharacters",
        ],
    )?;
    Ok(
        gurine_agent_orchestration::runtime::ToolRequest::EvidenceRead(EvidenceReadRequest {
            binding,
            evidence_id: required_uuid(&object, "evidenceId")?,
        }),
    )
}

fn decode_evidence_search(
    value: Value,
) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    use gurine_agent_orchestration::runtime::EvidenceSearchRequest;
    let fields = [
        "schemaVersion",
        "runId",
        "inputSnapshotId",
        "inputSnapshotSha256",
        "query",
        "queryLanguage",
        "evidenceTypes",
        "verificationStates",
        "classifications",
        "sourceAuthorities",
        "sort",
        "cursor",
        "limit",
    ];
    let object = value
        .as_object()
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "request.object".into()))?;
    let binding = internal_binding(object)?;
    let object = decode_v2_object(value, "evidence.search.request.v2", &binding, &fields)?;
    require_keys(
        &object,
        &[
            "query",
            "queryLanguage",
            "evidenceTypes",
            "verificationStates",
            "classifications",
            "sourceAuthorities",
            "sort",
            "cursor",
            "limit",
        ],
    )?;
    Ok(
        gurine_agent_orchestration::runtime::ToolRequest::EvidenceSearch(EvidenceSearchRequest {
            binding,
            query: required_string(&object, "query")?,
        }),
    )
}

fn decode_response_read(
    value: Value,
) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    use gurine_agent_orchestration::runtime::ResponseReadRequest;
    let fields = [
        "schemaVersion",
        "runId",
        "inputSnapshotId",
        "inputSnapshotSha256",
        "responseId",
        "responseVersion",
        "includeAttachments",
        "includeConsent",
        "maxCharacters",
    ];
    let object = value
        .as_object()
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "request.object".into()))?;
    let binding = internal_binding(object)?;
    let object = decode_v2_object(value, "response.read.request.v2", &binding, &fields)?;
    require_keys(
        &object,
        &[
            "responseId",
            "responseVersion",
            "includeAttachments",
            "includeConsent",
            "maxCharacters",
        ],
    )?;
    Ok(
        gurine_agent_orchestration::runtime::ToolRequest::ResponseRead(ResponseReadRequest {
            binding,
            response_id: required_uuid(&object, "responseId")?,
        }),
    )
}

fn decode_rule_reproduce(
    value: Value,
) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    use gurine_agent_orchestration::runtime::RuleReproduceRequest;
    let fields = [
        "schemaVersion",
        "runId",
        "inputSnapshotId",
        "inputSnapshotSha256",
        "ruleId",
        "ruleVersionId",
        "ruleCodeSha256",
        "ruleConfigurationSha256",
        "detectionSnapshotId",
        "detectionSnapshotSha256",
        "subjectMembers",
        "expectedSignalId",
        "traceLevel",
    ];
    let object = value
        .as_object()
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "request.object".into()))?;
    let binding = internal_binding(object)?;
    let object = decode_v2_object(value, "rule.reproduce.request.v2", &binding, &fields)?;
    require_keys(
        &object,
        &[
            "ruleId",
            "ruleVersionId",
            "ruleCodeSha256",
            "ruleConfigurationSha256",
            "detectionSnapshotId",
            "detectionSnapshotSha256",
            "subjectMembers",
            "expectedSignalId",
            "traceLevel",
        ],
    )?;
    Ok(
        gurine_agent_orchestration::runtime::ToolRequest::RuleReproduce(RuleReproduceRequest {
            binding,
            rule_version_id: required_uuid(&object, "ruleVersionId")?,
        }),
    )
}

fn decode_source_locator_verify(
    value: Value,
) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    use gurine_agent_orchestration::runtime::SourceLocatorVerifyRequest;
    let fields = [
        "schemaVersion",
        "runId",
        "inputSnapshotId",
        "inputSnapshotSha256",
        "sourceKind",
        "sourceIdentity",
        "locator",
        "expectedSelectedContentSha256",
        "expectedSupportsSha256",
        "normalizationVersion",
    ];
    let object = value
        .as_object()
        .ok_or_else(|| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "request.object".into()))?;
    let binding = internal_binding(object)?;
    let object = decode_v2_object(value, "source.locator_verify.request.v2", &binding, &fields)?;
    require_keys(
        &object,
        &[
            "sourceKind",
            "sourceIdentity",
            "locator",
            "expectedSelectedContentSha256",
            "expectedSupportsSha256",
            "normalizationVersion",
        ],
    )?;
    let expected = required_string(&object, "expectedSelectedContentSha256")?;
    if expected.len() != 64 || !expected.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(Failure::Terminal(
            "PROVIDER_TOOL_CALL_INVALID",
            "expectedSelectedContentSha256".into(),
        ));
    }
    Ok(
        gurine_agent_orchestration::runtime::ToolRequest::SourceLocatorVerify(
            SourceLocatorVerifyRequest {
                binding,
                expected_selected_content_sha256: expected,
            },
        ),
    )
}

fn decode_source_fetch_request(
    mut arguments: Value,
) -> Result<gurine_agent_orchestration::runtime::ToolRequest, Failure> {
    use gurine_agent_orchestration::runtime::{SourceFetchRequest, SourceFetchRequestV2};
    let object = arguments.as_object_mut().ok_or_else(|| {
        Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "source.fetch.object".into())
    })?;
    let binding = take_source_fetch_binding(object)?;
    let request_kind = object
        .get("requestKind")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            Failure::Terminal(
                "PROVIDER_TOOL_CALL_INVALID",
                "source.fetch.requestKind".into(),
            )
        })?;
    let allowed = source_fetch_allowed_fields(request_kind)?;
    if object.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err(Failure::Terminal(
            "PROVIDER_TOOL_CALL_INVALID",
            "source.fetch.unknown_field".into(),
        ));
    }
    let wire: SourceFetchRequestV2 =
        serde_json::from_value(Value::Object(object.clone())).map_err(tool_decode)?;
    let binding_matches = match &wire {
        SourceFetchRequestV2::SearchPublicWeb {
            run_id,
            input_snapshot_id,
            input_snapshot_sha256,
            ..
        }
        | SourceFetchRequestV2::FetchUrl {
            run_id,
            input_snapshot_id,
            input_snapshot_sha256,
            ..
        } => {
            *run_id == binding.run_id
                && *input_snapshot_id == binding.input_snapshot_id
                && input_snapshot_sha256 == &binding.input_snapshot_sha256
        }
    };
    if !binding_matches {
        return Err(Failure::Terminal(
            "PROVIDER_TOOL_CALL_INVALID",
            "source.fetch.binding_mismatch".into(),
        ));
    }
    SourceFetchRequest::from_v2(wire, binding)
        .map(gurine_agent_orchestration::runtime::ToolRequest::SourceFetch)
        .map_err(|error| Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", error.to_string()))
}

fn take_source_fetch_binding(
    object: &mut serde_json::Map<String, Value>,
) -> Result<gurine_agent_orchestration::runtime::SnapshotBinding, Failure> {
    let binding = object.remove("binding").ok_or_else(|| {
        Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", "source.fetch.binding".into())
    })?;
    serde_json::from_value(binding).map_err(tool_decode)
}

fn source_fetch_allowed_fields(request_kind: &str) -> Result<&'static [&'static str], Failure> {
    match request_kind {
        "SEARCH_PUBLIC_WEB" => Ok(&[
            "schemaVersion",
            "runId",
            "inputSnapshotId",
            "inputSnapshotSha256",
            "requestKind",
            "query",
            "locale",
            "country",
            "recencyDays",
            "resultLimit",
            "sourcePolicyVersion",
            "sourcePolicySha256",
            "rightsPurpose",
            "maxBytesPerArtifact",
        ]),
        "FETCH_URL" => Ok(&[
            "schemaVersion",
            "runId",
            "inputSnapshotId",
            "inputSnapshotSha256",
            "requestKind",
            "url",
            "expectedMediaTypes",
            "sourcePolicyVersion",
            "sourcePolicySha256",
            "rightsPurpose",
            "maxBytes",
            "allowRedirects",
        ]),
        _ => Err(Failure::Terminal(
            "PROVIDER_TOOL_CALL_INVALID",
            "source.fetch.requestKind".into(),
        )),
    }
}

fn tool_decode(error: serde_json::Error) -> Failure {
    Failure::Terminal("PROVIDER_TOOL_CALL_INVALID", error.to_string())
}
