fn validate_agent_item(schema: &str, value: &Value) -> Result<(), Failure> {
    match schema {
        "market-research-output.v2" => validate_fields(value, &["proposalKind", "proposalState", "subjectDescription", "candidateDescription", "sourceUrl", "observedAt", "unit", "unitPriceDecimal", "currencyCode", "compatibility", "comparisonBasis", "materialDifferences", "limitations", "citationIndexes"], Some("COMPARABLE")),
        "investigator-output.v2" => validate_fields(value, &["proposalKind", "proposalState", "statement", "assessment", "supportingCitationIndexes", "contradictingCitationIndexes", "unknowns"], Some("HYPOTHESIS")),
        "skeptic-output.v2" => validate_fields(value, &["kind", "claimOrHypothesis", "challenge", "challengeType", "citationIndexes", "severity"], Some("CHALLENGE")),
        "claim-draft-output.v2" => validate_fields(value, &["proposalKind", "proposalState", "claimType", "text", "citationIndexes", "limitations", "responseContext", "languageCheckResponseSha256"], Some("CLAIM")),
        "citation-verification-output.v2" => validate_fields(value, &["claimIndex", "status", "verifiedCitationIndexes", "unsupportedFragments"], None),
        _ => Err(invalid("agent schema")),
    }
}

fn validate_fields(value: &Value, required: &[&str], constant: Option<&str>) -> Result<(), Failure> {
    let object = object_fields(value, required)?;
    if let Some(expected) = constant
        && string_field(object, "proposalKind").ok() != Some(expected)
        && string_field(object, "kind").ok() != Some(expected)
    {
        return Err(invalid("proposalKind"));
    }
    for key in required {
        let field = object.get(*key).ok_or_else(|| invalid(key))?;
        if key.ends_with("Sha256") { hash_field(object, key)?; }
        if (key.contains("CitationIndexes") || *key == "citationIndexes" || *key == "verifiedCitationIndexes")
            && !field.is_array()
        {
            return Err(invalid(key));
        }
        if key.contains("CitationIndexes") || *key == "citationIndexes" || *key == "verifiedCitationIndexes" {
            validate_index_array(field, key, !matches!(*key, "supportingCitationIndexes" | "contradictingCitationIndexes" | "verifiedCitationIndexes"))?;
        }
        if matches!(*key, "proposalState" | "text" | "statement" | "challenge" | "claimOrHypothesis" | "subjectDescription" | "candidateDescription" | "sourceUrl" | "observedAt" | "unit" | "unitPriceDecimal" | "currencyCode" | "compatibility" | "comparisonBasis" | "materialDifferences" | "limitations" | "assessment" | "challengeType" | "severity" | "claimType" | "responseContext" | "status") && field.as_str().is_none() {
            return Err(invalid(key));
        }
        if *key == "payload" && !field.is_object() { return Err(invalid(key)); }
        if *key == "claimIndex" && field.as_u64().is_none_or(|index| index > 999) { return Err(invalid(key)); }
    }
    validate_agent_field_constraints(object, required)?;
    if let Some(status) = object.get("status").and_then(Value::as_str) {
        let verified = object.get("verifiedCitationIndexes").and_then(Value::as_array).ok_or_else(|| invalid("verifiedCitationIndexes"))?;
        let unsupported = object.get("unsupportedFragments").and_then(Value::as_array).ok_or_else(|| invalid("unsupportedFragments"))?;
        match status {
            "VERIFIED" if verified.is_empty() || !unsupported.is_empty() => return Err(invalid("status")),
            "UNSUPPORTED" if !verified.is_empty() || unsupported.is_empty() => return Err(invalid("status")),
            _ => {}
        }
    }
    Ok(())
}

fn validate_agent_field_constraints(object: &serde_json::Map<String, Value>, required: &[&str]) -> Result<(), Failure> {
    for key in required {
        let field = object.get(*key).ok_or_else(|| invalid(key))?;
        let max = match *key {
            "subjectDescription" | "candidateDescription" => Some(1000),
            "sourceUrl" => Some(4096), "observedAt" => Some(10), "unit" => Some(255),
            "unitPriceDecimal" => Some(25), "currencyCode" => Some(3),
            "comparisonBasis" => Some(2000), "statement" | "claimOrHypothesis" | "challenge" => Some(4000),
            "text" => Some(8000), "title" => Some(500), "description" => Some(4000),
            "summary" => Some(2000),
            "proposalState" | "claimType" | "assessment" | "priority" | "duePolicy" | "compatibility" | "challengeType" | "severity" | "responseContext" | "status" => Some(64),
            _ => None,
        };
        if let Some(max) = max {
            let text = field.as_str().ok_or_else(|| invalid(key))?;
            if text.trim().is_empty() || text.chars().count() > max { return Err(invalid(key)); }
        }
        if let Some(text) = field.as_str() {
            let valid_enum = match *key {
                "proposalState" => text == "PROPOSAL_ONLY",
                "compatibility" => matches!(text, "POTENTIAL" | "INCOMPATIBLE" | "UNKNOWN"),
                "assessment" => matches!(text, "SUPPORTED" | "CONTRADICTED" | "UNRESOLVED"),
                "priority" => matches!(text, "LOW" | "NORMAL" | "HIGH" | "URGENT"),
                "duePolicy" => matches!(text, "WITHIN_24_HOURS" | "WITHIN_3_DAYS" | "WITHIN_7_DAYS" | "BEFORE_PUBLICATION"),
                "claimType" => matches!(text, "FACT" | "ASSESSMENT" | "CONTEXT" | "LIMITATION"),
                "responseContext" => matches!(text, "NO_REQUEST" | "REQUESTED_NO_RESPONSE" | "RESPONSE_RECEIVED" | "RESPONSE_DISPUTES_CLAIM"),
                "challengeType" => matches!(text, "FALSE_POSITIVE_RISK" | "DATA_ERROR" | "ALTERNATIVE_EXPLANATION" | "PUBLICATION_BLOCKER"),
                "severity" => matches!(text, "INFO" | "MATERIAL" | "BLOCKING"),
                "status" => matches!(text, "VERIFIED" | "UNSUPPORTED" | "PARTIAL"),
                _ => true,
            };
            if !valid_enum { return Err(invalid(key)); }
        }
        if matches!(*key, "materialDifferences" | "limitations" | "unknowns" | "unsupportedFragments") {
            validate_text_array(field, key, 50, 2000)?;
        }
    }
    Ok(())
}

fn validate_index_array(value: &Value, field: &str, non_empty: bool) -> Result<(), Failure> {
    let items = value.as_array().ok_or_else(|| invalid(field))?;
    if (non_empty && items.is_empty()) || items.len() > 100 { return Err(invalid(field)); }
    let mut seen = std::collections::BTreeSet::new();
    for item in items {
        let index = item.as_u64().ok_or_else(|| invalid(field))?;
        if index > 999 || !seen.insert(index) { return Err(invalid(field)); }
    }
    Ok(())
}

fn validate_text_array(value: &Value, field: &str, max_items: usize, max_length: usize) -> Result<(), Failure> {
    let items = value.as_array().ok_or_else(|| invalid(field))?;
    if items.len() > max_items { return Err(invalid(field)); }
    let mut seen = std::collections::BTreeSet::new();
    for item in items {
        let text = item.as_str().ok_or_else(|| invalid(field))?;
        if text.trim().is_empty() || text.chars().count() > max_length || !seen.insert(text) { return Err(invalid(field)); }
    }
    Ok(())
}

fn object_fields<'a>(value: &'a Value, required: &[&str]) -> Result<&'a serde_json::Map<String, Value>, Failure> {
    let object = value.as_object().ok_or_else(|| invalid("object"))?;
    if required.iter().any(|key| !object.contains_key(*key)) { return Err(invalid("required")); }
    if object.keys().any(|key| !required.contains(&key.as_str())) { return Err(invalid("additionalProperties")); }
    Ok(object)
}

fn string_field<'a>(object: &'a serde_json::Map<String, Value>, key: &str) -> Result<&'a str, Failure> {
    object.get(key).and_then(Value::as_str).ok_or_else(|| invalid(key))
}

fn non_empty_field(object: &serde_json::Map<String, Value>, key: &str) -> Result<(), Failure> {
    if string_field(object, key)?.trim().is_empty() { return Err(invalid(key)); }
    Ok(())
}

fn hash_field(object: &serde_json::Map<String, Value>, key: &str) -> Result<(), Failure> {
    if !string_field(object, key).is_ok_and(is_lower_hash) { return Err(invalid(key)); }
    Ok(())
}

fn invalid(field: &str) -> Failure {
    Failure::Terminal("AGENT_OUTPUT_SCHEMA_INVALID", field.to_owned())
}

fn is_lower_hash(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}

/// RFC 8785-compatible canonical JSON for the provider/addendum payloads.
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
                return Err(Failure::Terminal("JSON_SERIALIZATION_FAILED", "provider canonical JSON does not accept non-integer numbers".into()));
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
                if index > 0 { out.push(','); }
                write_jcs(value, out)?;
            }
            out.push(']');
        }
        Value::Object(values) => {
            let mut keys = values.keys().collect::<Vec<_>>();
            keys.sort_by(|left, right| left.encode_utf16().cmp(right.encode_utf16()));
            out.push('{');
            for (index, key) in keys.iter().enumerate() {
                if index > 0 { out.push(','); }
                let encoded = serde_json::to_string(key)
                    .map_err(|error| Failure::Terminal("JSON_SERIALIZATION_FAILED", error.to_string()))?;
                out.push_str(&encoded);
                out.push(':');
                let Some(value) = values.get(*key) else {
                    return Err(Failure::Terminal("JSON_SERIALIZATION_FAILED", "object key disappeared during canonicalization".into()));
                };
                write_jcs(value, out)?;
            }
            out.push('}');
        }
    }
    Ok(())
}

fn sha256(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|byte| format!("{byte:02x}")).collect()
}
