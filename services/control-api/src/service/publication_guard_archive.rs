use gurine_publication_policy::natural_person::PublicTextNode;

use super::*;

pub(super) fn archive_publication_text_tree(
    object: &Map<String, Value>,
) -> Result<PublicTextNode<'_>, ServiceError> {
    let mut fields = Vec::new();
    push_required_text(&mut fields, object, "slug")?;
    push_required_text(&mut fields, object, "title")?;
    push_required_text(&mut fields, object, "summary")?;
    push_required_text(&mut fields, object, "non_conclusion")?;
    push_archive_sections(&mut fields, object)?;
    push_archive_claims(&mut fields, object)?;
    push_archive_evidence(&mut fields, object)?;
    push_archive_subjects(&mut fields, object)?;
    push_archive_methodology(&mut fields, object)?;
    push_archive_responses(&mut fields, object)?;
    push_archive_corrections(&mut fields, object)?;
    push_archive_official_confirmation(&mut fields, object)?;
    push_archive_correction_facts(&mut fields, object)?;
    Ok(PublicTextNode::object(fields))
}

fn push_archive_sections<'a>(
    fields: &mut Vec<(&'static str, PublicTextNode<'a>)>,
    object: &'a Map<String, Value>,
) -> Result<(), ServiceError> {
    let sections = required_array(object, "sections")?;
    let mut section_nodes = Vec::with_capacity(sections.len());
    for section in sections {
        let section = section.as_object().ok_or(ServiceError::Persistence)?;
        let mut section_fields = Vec::new();
        push_required_text(&mut section_fields, section, "heading")?;
        let blocks = required_array(section, "blocks")?;
        let mut block_nodes = Vec::with_capacity(blocks.len());
        for block in blocks {
            let block = block.as_object().ok_or(ServiceError::Persistence)?;
            let mut block_fields = Vec::new();
            push_optional_text(&mut block_fields, block, "text")?;
            if let Some(data) = block.get("data").filter(|value| !value.is_null()) {
                block_fields.push(("data", public_data_node(data)?));
            }
            block_nodes.push(PublicTextNode::object(block_fields));
        }
        section_fields.push(("blocks", PublicTextNode::array(block_nodes)));
        section_nodes.push(PublicTextNode::object(section_fields));
    }
    fields.push(("sections", PublicTextNode::array(section_nodes)));
    Ok(())
}

fn push_archive_claims<'a>(
    fields: &mut Vec<(&'static str, PublicTextNode<'a>)>,
    object: &'a Map<String, Value>,
) -> Result<(), ServiceError> {
    let claims = required_array(object, "claims")?;
    let mut nodes = Vec::with_capacity(claims.len());
    for claim in claims {
        let claim = claim.as_object().ok_or(ServiceError::Persistence)?;
        let mut claim_fields = Vec::new();
        push_required_text(&mut claim_fields, claim, "text_ko")?;
        nodes.push(PublicTextNode::object(claim_fields));
    }
    fields.push(("claims", PublicTextNode::array(nodes)));
    Ok(())
}

fn push_archive_evidence<'a>(
    fields: &mut Vec<(&'static str, PublicTextNode<'a>)>,
    object: &'a Map<String, Value>,
) -> Result<(), ServiceError> {
    let evidence = required_array(object, "evidence")?;
    let mut nodes = Vec::with_capacity(evidence.len());
    for item in evidence {
        let item = item.as_object().ok_or(ServiceError::Persistence)?;
        let mut item_fields = Vec::new();
        push_required_text(&mut item_fields, item, "summary")?;
        push_optional_text(&mut item_fields, item, "public_excerpt")?;
        let source = item
            .get("source")
            .and_then(Value::as_object)
            .ok_or(ServiceError::Persistence)?;
        let locator = source
            .get("locator")
            .and_then(Value::as_object)
            .ok_or(ServiceError::Persistence)?;
        let mut locator_fields = Vec::new();
        push_required_text(&mut locator_fields, locator, "value")?;
        item_fields.push(("source_locator", PublicTextNode::object(locator_fields)));
        nodes.push(PublicTextNode::object(item_fields));
    }
    fields.push(("evidence", PublicTextNode::array(nodes)));
    Ok(())
}

fn push_archive_subjects<'a>(
    fields: &mut Vec<(&'static str, PublicTextNode<'a>)>,
    object: &'a Map<String, Value>,
) -> Result<(), ServiceError> {
    let subjects = required_array(object, "subjects")?;
    let mut nodes = Vec::with_capacity(subjects.len());
    for subject in subjects {
        let subject = subject.as_object().ok_or(ServiceError::Persistence)?;
        let mut subject_fields = Vec::new();
        push_required_text(&mut subject_fields, subject, "display_name")?;
        nodes.push(PublicTextNode::object(subject_fields));
    }
    fields.push(("subjects", PublicTextNode::array(nodes)));
    Ok(())
}

fn push_archive_methodology<'a>(
    fields: &mut Vec<(&'static str, PublicTextNode<'a>)>,
    object: &'a Map<String, Value>,
) -> Result<(), ServiceError> {
    let methodology = object
        .get("methodology")
        .and_then(Value::as_object)
        .ok_or(ServiceError::Persistence)?;
    let mut methodology_fields = Vec::new();
    methodology_fields.push((
        "limitations",
        text_array(required_array(methodology, "limitations")?)?,
    ));
    let calculation = methodology
        .get("calculation")
        .ok_or(ServiceError::Persistence)?;
    methodology_fields.push(("calculation", public_data_node(calculation)?));
    fields.push(("methodology", PublicTextNode::object(methodology_fields)));
    Ok(())
}

fn push_archive_responses<'a>(
    fields: &mut Vec<(&'static str, PublicTextNode<'a>)>,
    object: &'a Map<String, Value>,
) -> Result<(), ServiceError> {
    let responses = required_array(object, "responses")?;
    let mut nodes = Vec::with_capacity(responses.len());
    for response in responses {
        let response = response.as_object().ok_or(ServiceError::Persistence)?;
        let mut response_fields = Vec::new();
        push_required_text(&mut response_fields, response, "party")?;
        push_required_text(&mut response_fields, response, "display_text")?;
        nodes.push(PublicTextNode::object(response_fields));
    }
    fields.push(("responses", PublicTextNode::array(nodes)));
    Ok(())
}

fn push_archive_corrections<'a>(
    fields: &mut Vec<(&'static str, PublicTextNode<'a>)>,
    object: &'a Map<String, Value>,
) -> Result<(), ServiceError> {
    let corrections = required_array(object, "corrections")?;
    let mut nodes = Vec::with_capacity(corrections.len());
    for correction in corrections {
        let correction = correction.as_object().ok_or(ServiceError::Persistence)?;
        let mut correction_fields = Vec::new();
        push_required_text(&mut correction_fields, correction, "summary")?;
        nodes.push(PublicTextNode::object(correction_fields));
    }
    fields.push(("corrections", PublicTextNode::array(nodes)));
    Ok(())
}

fn push_archive_official_confirmation<'a>(
    fields: &mut Vec<(&'static str, PublicTextNode<'a>)>,
    object: &'a Map<String, Value>,
) -> Result<(), ServiceError> {
    let Some(value) = object.get("official_confirmation") else {
        return Ok(());
    };
    let confirmation = value.as_object().ok_or(ServiceError::Persistence)?;
    let mut confirmation_fields = Vec::new();
    for key in [
        "institution",
        "document_type",
        "confirmed_scope",
        "source_locator",
    ] {
        push_required_text(&mut confirmation_fields, confirmation, key)?;
    }
    fields.push((
        "official_confirmation",
        PublicTextNode::object(confirmation_fields),
    ));
    Ok(())
}

fn push_archive_correction_facts<'a>(
    fields: &mut Vec<(&'static str, PublicTextNode<'a>)>,
    object: &'a Map<String, Value>,
) -> Result<(), ServiceError> {
    if let Some(value) = object.get("correction_notice") {
        let notice = value.as_object().ok_or(ServiceError::Persistence)?;
        let mut notice_fields = Vec::new();
        push_required_text(&mut notice_fields, notice, "reason")?;
        push_required_text(&mut notice_fields, notice, "impact_summary")?;
        fields.push(("correction_notice", PublicTextNode::object(notice_fields)));
    }
    if let Some(value) = object.get("correction_details") {
        let details = value.as_object().ok_or(ServiceError::Persistence)?;
        let mut detail_fields = Vec::new();
        push_required_text(&mut detail_fields, details, "effective_reason")?;
        detail_fields.push((
            "limitations",
            text_array(required_array(details, "limitations")?)?,
        ));
        fields.push(("correction_details", PublicTextNode::object(detail_fields)));
    }
    Ok(())
}

fn public_data_node(value: &Value) -> Result<PublicTextNode<'_>, ServiceError> {
    match value {
        Value::String(text) => Ok(PublicTextNode::text(text)),
        Value::Array(values) => values
            .iter()
            .map(public_data_node)
            .collect::<Result<Vec<_>, _>>()
            .map(PublicTextNode::array),
        Value::Object(values) => values
            .iter()
            .map(|(key, value)| Ok((key.as_str(), public_data_node(value)?)))
            .collect::<Result<Vec<_>, ServiceError>>()
            .map(PublicTextNode::object),
        Value::Null | Value::Bool(_) | Value::Number(_) => Ok(PublicTextNode::object(Vec::new())),
    }
}

#[cfg(test)]
mod tests {
    use gurine_publication_policy::natural_person::{
        NaturalPersonFindingBasis, RegisteredPersonName, scan_public_text,
    };

    use super::*;

    #[test]
    fn archive_tree_covers_sections_data_and_all_public_prose_groups() {
        // TEST_ONLY: `테스트인` is a deliberately synthetic natural-person name.
        let payload = json!({
            "schema_version":"1.0.0",
            "slug":"test-only-archive",
            "title":"계약 검토",
            "summary":"가상 자료",
            "non_conclusion":"확정 판단 아님",
            "sections":[{"heading":"확인 내용","blocks":[
                {"type":"TABLE","text":null,"data":{"담당":"테스트인 전 장관"}}
            ]}],
            "claims":[{"text_ko":"계약 사실"}],
            "evidence":[{"summary":"공식 문서","public_excerpt":"테스트인 서명", "source":{"locator":{"value":"3쪽"}}}],
            "subjects":[{"display_name":"가상 기관"}],
            "methodology":{"limitations":["기간 한계"],"calculation":{"설명":"자료 비교"}},
            "responses":[{"party":"가상 기관","display_text":"추가 확인 중"}],
            "corrections":[{"summary":"금액 정정"}],
            "review_summary":{"legal_reviewed":false}
        });
        let object = payload.as_object().expect("archive object");
        let tree = archive_publication_text_tree(object).expect("archive text tree");
        let registered = RegisteredPersonName::new("테스트인").expect("registered person");
        let assessment = scan_public_text(&tree, &[registered]).expect("archive scan");

        assert_eq!(
            assessment.public_text_sha256,
            "cc27a6ec726d867c3fff7b026cd821bcda6fe9aacd8a64e93af6f8d7e15e7ef9"
        );

        assert!(assessment.findings.iter().any(|finding| {
            finding.path == "/sections/0/blocks/0/data/담당"
                && finding.basis == NaturalPersonFindingBasis::RegisteredPersonExact
        }));
        assert!(
            assessment
                .findings
                .iter()
                .any(|finding| finding.path == "/evidence/0/public_excerpt")
        );

        let mut changed_slug_payload = payload;
        changed_slug_payload["slug"] = json!("test-only-테스트인");
        let changed_slug_object = changed_slug_payload
            .as_object()
            .expect("changed archive object");
        let changed_slug_tree =
            archive_publication_text_tree(changed_slug_object).expect("changed archive text tree");
        let changed_registered =
            RegisteredPersonName::new("테스트인").expect("changed registered person");
        let changed_slug_assessment = scan_public_text(&changed_slug_tree, &[changed_registered])
            .expect("changed archive scan");
        assert!(changed_slug_assessment.findings.iter().any(|finding| {
            finding.path == "/slug"
                && finding.basis == NaturalPersonFindingBasis::RegisteredPersonExact
        }));
        assert_ne!(
            assessment.public_text_sha256,
            changed_slug_assessment.public_text_sha256
        );
    }
}
