use gurine_publication_policy::natural_person::{
    NaturalPersonAssessment, NaturalPersonFinding, NaturalPersonFindingBasis, PublicTextNode,
    RegisteredPersonName, canonical_registered_person_name, scan_public_text,
};

use super::*;

#[path = "publication_guard_person.rs"]
mod publication_guard_person;

use publication_guard_person::{public_text_leaf, utf16_slice};

const SERVER_OWNED_PUBLICATION_GUARD_KEYS: [&str; 5] = [
    "scan",
    "publicPayload",
    "publicPayloadSha256",
    "registeredNameSetSha256",
    "legalOverride",
];

pub(super) fn reject_caller_publication_guard_authority(
    request: &Map<String, Value>,
) -> Result<(), ServiceError> {
    if SERVER_OWNED_PUBLICATION_GUARD_KEYS
        .iter()
        .any(|key| request.contains_key(*key))
    {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(())
}

pub(super) fn bind_preview_publication_contract(
    public_payload: &mut Value,
    request: &Map<String, Value>,
) -> Result<(), ServiceError> {
    let object = public_payload
        .as_object_mut()
        .ok_or(ServiceError::Persistence)?;
    let state = object
        .get("publicationState")
        .and_then(Value::as_str)
        .ok_or(ServiceError::Persistence)?
        .to_owned();
    let official_confirmation = request.get("officialConfirmation");
    match (state.as_str(), official_confirmation) {
        ("OFFICIALLY_CONFIRMED", Some(Value::Object(_))) => {
            let confirmation = official_confirmation
                .and_then(Value::as_object)
                .ok_or(ServiceError::InvalidRequest)?;
            let non_conclusion = official_confirmation_non_conclusion(confirmation)?;
            object.insert(
                "officialConfirmation".to_owned(),
                official_confirmation
                    .cloned()
                    .ok_or(ServiceError::Persistence)?,
            );
            object.insert("nonConclusion".to_owned(), json!(non_conclusion));
        }
        ("OFFICIALLY_CONFIRMED", _) => return Err(ServiceError::PreconditionFailed),
        ("CORRECTED", _) => return Err(ServiceError::PreconditionFailed),
        (_, None) => {}
        (_, Some(_)) => return Err(ServiceError::InvalidRequest),
    }
    if state != "OFFICIALLY_CONFIRMED" {
        object.insert(
            "nonConclusion".to_owned(),
            json!(static_publication_non_conclusion(&state)?),
        );
    }
    Ok(())
}

fn official_confirmation_non_conclusion(
    confirmation: &Map<String, Value>,
) -> Result<String, ServiceError> {
    const REQUIRED: [&str; 6] = [
        "institution",
        "documentType",
        "documentDate",
        "confirmedScope",
        "sourceLocator",
        "sourceDigest",
    ];
    if confirmation.len() != REQUIRED.len()
        || REQUIRED.iter().any(|key| !confirmation.contains_key(*key))
    {
        return Err(ServiceError::InvalidRequest);
    }
    let institution = clean_confirmation_text(confirmation, "institution")?;
    let document_type = clean_confirmation_text(confirmation, "documentType")?;
    let document_date = clean_confirmation_text(confirmation, "documentDate")?;
    let date_format = time::format_description::parse("[year]-[month]-[day]")
        .map_err(|_| ServiceError::Persistence)?;
    Date::parse(document_date, &date_format).map_err(|_| ServiceError::InvalidRequest)?;
    let confirmed_scope = clean_confirmation_text(confirmation, "confirmedScope")?;
    clean_confirmation_text(confirmation, "sourceLocator")?;
    clean_confirmation_text(confirmation, "sourceDigest")?
        .bytes()
        .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
        .then_some(())
        .filter(|_| {
            confirmation
                .get("sourceDigest")
                .and_then(Value::as_str)
                .is_some_and(is_sha256)
        })
        .ok_or(ServiceError::InvalidRequest)?;
    Ok(format!(
        "{institution}의 {document_type}·{document_date}에서 {confirmed_scope}가 확인됐습니다. 구린네의 자체 판단이 아니라 해당 공식 결과를 요약합니다."
    ))
}

fn clean_confirmation_text<'a>(
    confirmation: &'a Map<String, Value>,
    key: &str,
) -> Result<&'a str, ServiceError> {
    confirmation
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| value.trim() == *value && !value.is_empty())
        .ok_or(ServiceError::InvalidRequest)
}

pub(super) struct PublicationScan {
    pub assessment: NaturalPersonAssessment,
    pub registered_name_set_sha256: String,
    pub finding_bindings: Vec<PublicationFindingBinding>,
}

pub(super) struct PublicationFindingBinding {
    pub finding: NaturalPersonFinding,
    pub matched_text_sha256: String,
    pub person_node_id: Option<Uuid>,
    pub topology_digest: Option<String>,
    pub context_id: Option<Uuid>,
    pub person_name_digest: Option<String>,
}

pub(super) fn publication_scan_payload(scan: &PublicationScan) -> Result<Value, ServiceError> {
    if scan.finding_bindings.len() > 10_000
        || scan.finding_bindings.len() != scan.assessment.findings.len()
        || !is_sha256(&scan.assessment.ruleset_sha256)
        || !is_sha256(&scan.assessment.public_text_sha256)
        || !is_sha256(&scan.registered_name_set_sha256)
    {
        return Err(ServiceError::Persistence);
    }
    let findings = scan
        .finding_bindings
        .iter()
        .enumerate()
        .map(|(ordinal, binding)| {
            let detector_kind = match binding.finding.basis {
                NaturalPersonFindingBasis::RegisteredPersonExact => {
                    if binding.person_node_id.is_none_or(|value| value.is_nil())
                        || binding
                            .topology_digest
                            .as_deref()
                            .is_none_or(|value| !is_sha256(value))
                        || binding.context_id.is_none_or(|value| value.is_nil())
                        || binding
                            .person_name_digest
                            .as_deref()
                            .is_none_or(|value| !is_sha256(value))
                    {
                        return Err(ServiceError::Persistence);
                    }
                    "REGISTERED_PERSON_EXACT"
                }
                NaturalPersonFindingBasis::TitleAdjacentKoreanName => {
                    if binding.person_node_id.is_some()
                        || binding.topology_digest.is_some()
                        || binding.context_id.is_some()
                        || binding.person_name_digest.is_some()
                    {
                        return Err(ServiceError::Persistence);
                    }
                    "TITLE_ADJACENT_KOREAN_NAME"
                }
            };
            if binding.finding.ruleset_version != scan.assessment.ruleset_version
                || binding.finding.path.len() > 2_048
                || !binding.finding.path.starts_with('/')
                || binding.finding.start_utf16 >= binding.finding.end_utf16
                || !is_sha256(&binding.matched_text_sha256)
            {
                return Err(ServiceError::Persistence);
            }
            Ok(json!({
                "ordinal":ordinal,
                "detectorKind":detector_kind,
                "jsonPointer":binding.finding.path,
                "startUtf16":binding.finding.start_utf16,
                "endUtf16":binding.finding.end_utf16,
                "matchedTextSha256":binding.matched_text_sha256,
                "personNodeId":binding.person_node_id,
                "topologyDigest":binding.topology_digest,
                "contextId":binding.context_id,
                "personNameDigest":binding.person_name_digest,
            }))
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(json!({
        "rulesetVersion":scan.assessment.ruleset_version,
        "rulesetSha256":scan.assessment.ruleset_sha256,
        "publicTextSha256":scan.assessment.public_text_sha256,
        "registeredNameSetSha256":scan.registered_name_set_sha256,
        "findings":findings,
    }))
}

struct RegisteredPersonContext {
    person_node_id: Uuid,
    topology_digest: String,
    context_id: Uuid,
    person_name_digest: String,
    normalized_name: String,
    display_name: String,
}

pub(super) async fn scan_publication_payload(
    public_payload: &Value,
    field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<PublicationScan, ServiceError> {
    let rows = sqlx::query!(
        "SELECT person_node_id AS \"person_node_id!\", \
           btrim(topology_digest::text) AS \"topology_digest!\", \
           context_id AS \"context_id!\", \
           contextual_name_ciphertext AS \"contextual_name_ciphertext!\", \
           btrim(contextual_name_sha256::text) AS \"contextual_name_sha256!\", \
           btrim(contextual_name_aad_digest::text) AS \"contextual_name_aad_digest!\", \
           encryption_key_id AS \"encryption_key_id!\", \
           btrim(person_name_digest::text) AS \"person_name_digest!\" \
         FROM core.list_publication_person_names_v1()"
    )
    .fetch_all(&mut **tx)
    .await
    .map_err(db)?;
    let contexts = rows
        .into_iter()
        .map(|row| {
            registered_person_context(
                row.person_node_id,
                row.topology_digest,
                row.context_id,
                row.contextual_name_ciphertext,
                row.contextual_name_sha256,
                row.contextual_name_aad_digest,
                row.encryption_key_id,
                row.person_name_digest,
                field_keys,
            )
        })
        .collect::<Result<Vec<_>, _>>()?;
    reject_ambiguous_registered_names(&contexts)?;
    let names = contexts
        .iter()
        .map(|context| {
            RegisteredPersonName::new(&context.display_name).map_err(|_| ServiceError::Persistence)
        })
        .collect::<Result<Vec<_>, _>>()?;
    let tree = publication_text_tree(public_payload)?;
    let assessment = scan_public_text(&tree, &names).map_err(|_| ServiceError::Persistence)?;
    let finding_bindings = bind_publication_findings(&tree, &assessment, &contexts)?;
    let registered_name_set_sha256 = registered_name_set_sha256(&contexts)?;
    Ok(PublicationScan {
        assessment,
        registered_name_set_sha256,
        finding_bindings,
    })
}

#[expect(
    clippy::too_many_arguments,
    reason = "the encrypted PERSON row is validated as one closed persistence boundary"
)]
fn registered_person_context(
    person_node_id: Uuid,
    topology_digest: String,
    context_id: Uuid,
    ciphertext: Vec<u8>,
    plaintext_sha256: String,
    aad_sha256: String,
    encryption_key_id: String,
    person_name_digest: String,
    field_keys: &EnvelopeKeyRing,
) -> Result<RegisteredPersonContext, ServiceError> {
    if person_node_id.is_nil()
        || context_id.is_nil()
        || !is_sha256(&topology_digest)
        || !is_sha256(&plaintext_sha256)
        || !is_sha256(&aad_sha256)
        || !is_sha256(&person_name_digest)
        || encryption_key_id.is_empty()
    {
        return Err(ServiceError::Persistence);
    }
    let aad = format!("core.relationship_graph_person_context_v3/{context_id}/contextual_name/v1");
    if sha256(aad.as_bytes()) != aad_sha256 {
        return Err(ServiceError::Persistence);
    }
    let token = std::str::from_utf8(&ciphertext).map_err(|_| ServiceError::Persistence)?;
    let token_key_id = token
        .split('.')
        .nth(1)
        .filter(|value| !value.is_empty())
        .ok_or(ServiceError::Persistence)?;
    if token_key_id != encryption_key_id {
        return Err(ServiceError::Persistence);
    }
    let plaintext = gurine_auth::envelope::decrypt("gurine-fe-v1", field_keys, &[&aad], token)
        .map_err(|_| ServiceError::Persistence)?;
    if sha256(&plaintext) != plaintext_sha256 {
        return Err(ServiceError::Persistence);
    }
    let display_name = String::from_utf8(plaintext).map_err(|_| ServiceError::Persistence)?;
    RegisteredPersonName::new(&display_name).map_err(|_| ServiceError::Persistence)?;
    let normalized_name = canonical_registered_person_name(&display_name);
    Ok(RegisteredPersonContext {
        person_node_id,
        topology_digest,
        context_id,
        person_name_digest,
        normalized_name,
        display_name,
    })
}

fn reject_ambiguous_registered_names(
    contexts: &[RegisteredPersonContext],
) -> Result<(), ServiceError> {
    let mut names = BTreeSet::new();
    for context in contexts {
        if !names.insert(context.normalized_name.as_str()) {
            return Err(ServiceError::PreconditionFailed);
        }
    }
    Ok(())
}

fn registered_name_set_sha256(
    contexts: &[RegisteredPersonContext],
) -> Result<String, ServiceError> {
    let mut tuples = contexts
        .iter()
        .map(|context| {
            let value = json!({
                "contextId":context.context_id,
                "personNameDigest":context.person_name_digest,
                "personNodeId":context.person_node_id,
                "topologyDigest":context.topology_digest,
            });
            Ok((canonical_json_bytes(&value)?, value))
        })
        .collect::<Result<Vec<_>, ServiceError>>()?;
    tuples.sort_by(|left, right| left.0.cmp(&right.0));
    canonical_json_digest(&json!(
        tuples
            .into_iter()
            .map(|(_, value)| value)
            .collect::<Vec<_>>()
    ))
}

fn bind_publication_findings(
    tree: &PublicTextNode<'_>,
    assessment: &NaturalPersonAssessment,
    contexts: &[RegisteredPersonContext],
) -> Result<Vec<PublicationFindingBinding>, ServiceError> {
    assessment
        .findings
        .iter()
        .map(|finding| {
            let text = public_text_leaf(tree, &finding.path)?;
            let matched = utf16_slice(text, finding.start_utf16, finding.end_utf16)?;
            let context = if finding.basis == NaturalPersonFindingBasis::RegisteredPersonExact {
                let normalized = canonical_registered_person_name(matched);
                let mut matches = contexts
                    .iter()
                    .filter(|context| context.normalized_name == normalized);
                let context = matches.next().ok_or(ServiceError::Persistence)?;
                if matches.next().is_some() {
                    return Err(ServiceError::PreconditionFailed);
                }
                Some(context)
            } else {
                None
            };
            Ok(PublicationFindingBinding {
                finding: finding.clone(),
                matched_text_sha256: sha256(matched.as_bytes()),
                person_node_id: context.map(|value| value.person_node_id),
                topology_digest: context.map(|value| value.topology_digest.clone()),
                context_id: context.map(|value| value.context_id),
                person_name_digest: context.map(|value| value.person_name_digest.clone()),
            })
        })
        .collect()
}

fn publication_text_tree(payload: &Value) -> Result<PublicTextNode<'_>, ServiceError> {
    let object = payload.as_object().ok_or(ServiceError::Persistence)?;
    if object.get("schema_version").and_then(Value::as_str) == Some("1.0.0") {
        return archive_publication_text_tree(object);
    }
    let mut fields = Vec::new();
    push_required_text(&mut fields, object, "slug")?;
    push_required_text(&mut fields, object, "title")?;
    push_required_text(&mut fields, object, "summary")?;
    push_required_text(&mut fields, object, "nonConclusion")?;
    push_optional_text(&mut fields, object, "agencyName")?;
    push_optional_text(&mut fields, object, "contractName")?;
    push_object_texts(
        &mut fields,
        object,
        "officialConfirmation",
        &[
            "institution",
            "documentType",
            "confirmedScope",
            "sourceLocator",
        ],
    )?;
    push_object_texts(
        &mut fields,
        object,
        "correctionNotice",
        &["reason", "impactSummary"],
    )?;
    push_correction_details(&mut fields, object)?;
    push_claims(&mut fields, object)?;
    push_evidence(&mut fields, object)?;
    push_responses(&mut fields, object)?;
    Ok(PublicTextNode::object(fields))
}

pub(super) fn push_required_text<'a>(
    fields: &mut Vec<(&'static str, PublicTextNode<'a>)>,
    object: &'a Map<String, Value>,
    key: &'static str,
) -> Result<(), ServiceError> {
    let text = object
        .get(key)
        .and_then(Value::as_str)
        .ok_or(ServiceError::Persistence)?;
    fields.push((key, PublicTextNode::text(text)));
    Ok(())
}

pub(super) fn push_optional_text<'a>(
    fields: &mut Vec<(&'static str, PublicTextNode<'a>)>,
    object: &'a Map<String, Value>,
    key: &'static str,
) -> Result<(), ServiceError> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(()),
        Some(Value::String(text)) => {
            fields.push((key, PublicTextNode::text(text)));
            Ok(())
        }
        Some(_) => Err(ServiceError::Persistence),
    }
}

fn push_object_texts<'a>(
    fields: &mut Vec<(&'static str, PublicTextNode<'a>)>,
    parent: &'a Map<String, Value>,
    key: &'static str,
    text_keys: &[&'static str],
) -> Result<(), ServiceError> {
    let Some(value) = parent.get(key) else {
        return Ok(());
    };
    if value.is_null() {
        return Ok(());
    }
    let object = value.as_object().ok_or(ServiceError::Persistence)?;
    let mut children = Vec::with_capacity(text_keys.len());
    for text_key in text_keys {
        push_required_text(&mut children, object, text_key)?;
    }
    fields.push((key, PublicTextNode::object(children)));
    Ok(())
}

fn push_claims<'a>(
    fields: &mut Vec<(&'static str, PublicTextNode<'a>)>,
    object: &'a Map<String, Value>,
) -> Result<(), ServiceError> {
    let claims = required_array(object, "claims")?;
    let mut items = Vec::with_capacity(claims.len());
    for claim in claims {
        let claim = claim.as_object().ok_or(ServiceError::Persistence)?;
        let mut claim_fields = Vec::new();
        push_required_text(&mut claim_fields, claim, "text")?;
        claim_fields.push((
            "limitations",
            text_array(required_array(claim, "limitations")?)?,
        ));
        items.push(PublicTextNode::object(claim_fields));
    }
    fields.push(("claims", PublicTextNode::array(items)));
    Ok(())
}

fn push_correction_details<'a>(
    fields: &mut Vec<(&'static str, PublicTextNode<'a>)>,
    parent: &'a Map<String, Value>,
) -> Result<(), ServiceError> {
    let Some(value) = parent.get("correctionDetails") else {
        return Ok(());
    };
    let object = value.as_object().ok_or(ServiceError::Persistence)?;
    let mut children = Vec::new();
    push_required_text(&mut children, object, "effectiveReason")?;
    children.push((
        "limitations",
        text_array(required_array(object, "limitations")?)?,
    ));
    fields.push(("correctionDetails", PublicTextNode::object(children)));
    Ok(())
}

fn push_evidence<'a>(
    fields: &mut Vec<(&'static str, PublicTextNode<'a>)>,
    object: &'a Map<String, Value>,
) -> Result<(), ServiceError> {
    let evidence = required_array(object, "evidence")?;
    let mut items = Vec::with_capacity(evidence.len());
    for item in evidence {
        let item = item.as_object().ok_or(ServiceError::Persistence)?;
        let mut item_fields = Vec::new();
        push_required_text(&mut item_fields, item, "title")?;
        for key in [
            "documentTitle",
            "publisher",
            "sourceUrl",
            "pageAnchor",
            "sourceLocator",
            "publicExcerpt",
        ] {
            push_optional_text(&mut item_fields, item, key)?;
        }
        items.push(PublicTextNode::object(item_fields));
    }
    fields.push(("evidence", PublicTextNode::array(items)));
    Ok(())
}

fn push_responses<'a>(
    fields: &mut Vec<(&'static str, PublicTextNode<'a>)>,
    object: &'a Map<String, Value>,
) -> Result<(), ServiceError> {
    let responses = required_array(object, "responses")?;
    let mut items = Vec::with_capacity(responses.len());
    for response in responses {
        let response = response.as_object().ok_or(ServiceError::Persistence)?;
        let mut response_fields = Vec::new();
        push_required_text(&mut response_fields, response, "partyName")?;
        push_optional_text(&mut response_fields, response, "excerpt")?;
        items.push(PublicTextNode::object(response_fields));
    }
    fields.push(("responses", PublicTextNode::array(items)));
    Ok(())
}

pub(super) fn required_array<'a>(
    object: &'a Map<String, Value>,
    key: &str,
) -> Result<&'a [Value], ServiceError> {
    object
        .get(key)
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .ok_or(ServiceError::Persistence)
}

pub(super) fn text_array(values: &[Value]) -> Result<PublicTextNode<'_>, ServiceError> {
    values
        .iter()
        .map(|value| {
            value
                .as_str()
                .map(PublicTextNode::text)
                .ok_or(ServiceError::Persistence)
        })
        .collect::<Result<Vec<_>, _>>()
        .map(PublicTextNode::array)
}

#[cfg(test)]
#[path = "publication_guard_tests.rs"]
mod tests;
