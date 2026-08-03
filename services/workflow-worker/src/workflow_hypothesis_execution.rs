use std::collections::BTreeSet;

#[derive(Debug)]
struct HypothesisAction {
    case_id: Uuid,
    expected_case_version: i64,
    statement: String,
    supporting_citation_ids: Vec<Uuid>,
    contradicting_citation_ids: Vec<Uuid>,
    unknowns: Vec<String>,
}

#[derive(Clone, Copy, Debug)]
struct ProducerJobFence {
    id: Uuid,
    lease_token: Uuid,
    fencing_token: i64,
}

#[derive(Debug)]
struct SealedHypothesisAction {
    proposal_id: Uuid,
    proposal_version: i64,
    target_request_encrypted: Vec<u8>,
    target_request_sha256: String,
}

#[derive(Debug)]
struct LoadedHypothesisAction {
    proposal_id: Uuid,
    proposal_version: i64,
    payload: Value,
}

async fn execute_approved_hypothesis(
    pool: &PgPool,
    field_keys: &EnvelopeKeyRing,
    producer_job: ProducerJobFence,
    execution: &ApprovedExecution,
) -> Result<Value, Failure> {
    let loaded = load_approved_hypothesis(pool, field_keys, producer_job, execution).await?;
    let action = hypothesis_action(&loaded.payload)?;
    let receipt = complete_approved_hypothesis(pool, producer_job, execution, &loaded.payload).await?;
    tracing::info!(
        execution_id = %execution.execution_id,
        proposal_id = %loaded.proposal_id,
        proposal_version = loaded.proposal_version,
        case_id = %action.case_id,
        expected_case_version = action.expected_case_version,
        statement_bytes = action.statement.len(),
        supporting_citations = action.supporting_citation_ids.len(),
        contradicting_citations = action.contradicting_citation_ids.len(),
        unknowns = action.unknowns.len(),
        "approved hypothesis executed"
    );
    Ok(receipt)
}

async fn load_approved_hypothesis(
    pool: &PgPool,
    field_keys: &EnvelopeKeyRing,
    producer_job: ProducerJobFence,
    execution: &ApprovedExecution,
) -> Result<LoadedHypothesisAction, Failure> {
    let sealed = sqlx::query_as!(
        SealedHypothesisAction,
        r#"SELECT proposal_id AS "proposal_id!",
                  proposal_version AS "proposal_version!",
                  target_request_encrypted AS "target_request_encrypted!",
                  target_request_sha256::text AS "target_request_sha256!"
             FROM ops.load_approved_hypothesis_execution_v1(
                 $1::uuid,$2::uuid,$3::bigint,$4::uuid,$5::bigint,$6::jsonb
             )"#,
        producer_job.id,
        producer_job.lease_token,
        producer_job.fencing_token,
        execution.execution_id,
        execution.generation,
        &execution.event_payload,
    )
    .fetch_one(pool)
    .await
    .map_err(database)?;
    let payload = decrypt_hypothesis_action(field_keys, execution.execution_id, &sealed)?;
    Ok(LoadedHypothesisAction {
        proposal_id: sealed.proposal_id,
        proposal_version: sealed.proposal_version,
        payload,
    })
}

fn decrypt_hypothesis_action(
    field_keys: &EnvelopeKeyRing,
    execution_id: Uuid,
    sealed: &SealedHypothesisAction,
) -> Result<Value, Failure> {
    let proposal_id = sealed.proposal_id.to_string();
    let encrypted = std::str::from_utf8(&sealed.target_request_encrypted).map_err(|_| {
        Failure::Terminal(
            "ACTION_PAYLOAD_DECRYPTION_FAILED",
            execution_id.to_string(),
        )
    })?;
    let plaintext = decrypt(
        "gurine-fe-v1",
        field_keys,
        &[
            "ops.action_proposal_versions",
            "payload_encrypted",
            &proposal_id,
            "json",
            "1",
        ],
        encrypted,
    )
    .map_err(|_| {
        Failure::Terminal(
            "ACTION_PAYLOAD_DECRYPTION_FAILED",
            execution_id.to_string(),
        )
    })?;
    let action_payload: Value = serde_json::from_slice(&plaintext)
        .map_err(|_| Failure::Terminal("ACTION_PAYLOAD_INVALID", proposal_id.clone()))?;
    let canonical = serde_json::to_vec(&action_payload)
        .map_err(|_| Failure::Terminal("ACTION_PAYLOAD_INVALID", proposal_id.clone()))?;
    if sha256(&canonical) != sealed.target_request_sha256.trim() {
        return Err(Failure::Terminal(
            "ACTION_PAYLOAD_DIGEST_MISMATCH",
            proposal_id,
        ));
    }
    Ok(action_payload)
}

async fn complete_approved_hypothesis(
    pool: &PgPool,
    producer_job: ProducerJobFence,
    execution: &ApprovedExecution,
    action_payload: &Value,
) -> Result<Value, Failure> {
    sqlx::query_scalar!(
        r#"SELECT ops.execute_approved_hypothesis_v1(
                 $1::uuid,$2::uuid,$3::bigint,$4::uuid,$5::bigint,$6::jsonb,$7::jsonb
             )
             AS "receipt!: Value""#,
        producer_job.id,
        producer_job.lease_token,
        producer_job.fencing_token,
        execution.execution_id,
        execution.generation,
        &execution.event_payload,
        action_payload,
    )
    .fetch_one(pool)
    .await
    .map_err(database)
}

fn hypothesis_action(payload: &Value) -> Result<HypothesisAction, Failure> {
    let action = hypothesis_action_binding(payload)?;
    let (case_id, expected_case_version) = hypothesis_target(action)?;
    hypothesis_proposal(action, case_id, expected_case_version)
}

fn hypothesis_action_binding(
    payload: &Value,
) -> Result<&serde_json::Map<String, Value>, Failure> {
    let action = exact_object(
        payload,
        &[
            "kind",
            "target",
            "objectScopeDigest",
            "contentDigest",
            "proposal",
        ],
        "hypothesis action",
    )?;
    if action.get("kind").and_then(Value::as_str) != Some("HYPOTHESIS")
        || !action
            .get("objectScopeDigest")
            .and_then(Value::as_str)
            .is_some_and(is_sha256)
        || !action
            .get("contentDigest")
            .and_then(Value::as_str)
            .is_some_and(is_sha256)
    {
        return Err(invalid_hypothesis("hypothesis action binding"));
    }
    Ok(action)
}

fn hypothesis_target(
    action: &serde_json::Map<String, Value>,
) -> Result<(Uuid, i64), Failure> {
    let target = exact_object(
        action.get("target").ok_or_else(|| invalid_hypothesis("target"))?,
        &["type", "id", "version", "digest"],
        "hypothesis target",
    )?;
    if target.get("type").and_then(Value::as_str) != Some("CASE")
        || !target
            .get("digest")
            .and_then(Value::as_str)
            .is_some_and(is_sha256)
    {
        return Err(invalid_hypothesis("hypothesis target binding"));
    }
    let case_id = required_uuid(&Value::Object(target.clone()), "id")?;
    let expected_case_version =
        required_positive_i64(&Value::Object(target.clone()), "version")?;
    Ok((case_id, expected_case_version))
}

fn hypothesis_proposal(
    action: &serde_json::Map<String, Value>,
    case_id: Uuid,
    expected_case_version: i64,
) -> Result<HypothesisAction, Failure> {
    let proposal = exact_object(
        action
            .get("proposal")
            .ok_or_else(|| invalid_hypothesis("proposal"))?,
        &[
            "kind",
            "statement",
            "supportingCitationIds",
            "contradictingCitationIds",
            "unknowns",
            "limitations",
        ],
        "hypothesis proposal",
    )?;
    if proposal.get("kind").and_then(Value::as_str) != Some("HYPOTHESIS") {
        return Err(invalid_hypothesis("hypothesis proposal kind"));
    }
    let statement = bounded_text(proposal, "statement", 4_000)?;
    let supporting_citation_ids = bounded_uuid_array(proposal, "supportingCitationIds", 100)?;
    let contradicting_citation_ids =
        bounded_uuid_array(proposal, "contradictingCitationIds", 100)?;
    disjoint_citations(&supporting_citation_ids, &contradicting_citation_ids)?;
    let unknowns = bounded_text_array(proposal, "unknowns", 50, 1_000)?;
    let _limitations = bounded_text_array(proposal, "limitations", 50, 1_000)?;
    Ok(HypothesisAction {
        case_id,
        expected_case_version,
        statement,
        supporting_citation_ids,
        contradicting_citation_ids,
        unknowns,
    })
}

fn disjoint_citations(supporting: &[Uuid], contradicting: &[Uuid]) -> Result<(), Failure> {
    let all = supporting
        .iter()
        .chain(contradicting)
        .copied()
        .collect::<BTreeSet<_>>();
    if all.is_empty() || all.len() != supporting.len() + contradicting.len() {
        return Err(invalid_hypothesis("hypothesis citation set"));
    }
    Ok(())
}

fn exact_object<'a>(
    value: &'a Value,
    fields: &[&str],
    context: &'static str,
) -> Result<&'a serde_json::Map<String, Value>, Failure> {
    let object = value
        .as_object()
        .ok_or_else(|| invalid_hypothesis(context))?;
    if object.len() != fields.len()
        || fields.iter().any(|field| !object.contains_key(*field))
        || object.keys().any(|field| !fields.contains(&field.as_str()))
    {
        return Err(invalid_hypothesis(context));
    }
    Ok(object)
}

fn bounded_text(
    object: &serde_json::Map<String, Value>,
    field: &'static str,
    maximum: usize,
) -> Result<String, Failure> {
    object
        .get(field)
        .and_then(Value::as_str)
        .filter(|value| (1..=maximum).contains(&value.trim().chars().count()))
        .map(ToOwned::to_owned)
        .ok_or_else(|| invalid_hypothesis(field))
}

fn bounded_uuid_array(
    object: &serde_json::Map<String, Value>,
    field: &'static str,
    maximum: usize,
) -> Result<Vec<Uuid>, Failure> {
    let values = object
        .get(field)
        .and_then(Value::as_array)
        .filter(|values| values.len() <= maximum)
        .ok_or_else(|| invalid_hypothesis(field))?;
    let parsed = values
        .iter()
        .map(|value| {
            value
                .as_str()
                .and_then(|value| Uuid::parse_str(value).ok())
                .ok_or_else(|| invalid_hypothesis(field))
        })
        .collect::<Result<Vec<_>, _>>()?;
    if parsed.iter().copied().collect::<BTreeSet<_>>().len() != parsed.len() {
        return Err(invalid_hypothesis(field));
    }
    Ok(parsed)
}

fn bounded_text_array(
    object: &serde_json::Map<String, Value>,
    field: &'static str,
    maximum_items: usize,
    maximum_length: usize,
) -> Result<Vec<String>, Failure> {
    let values = object
        .get(field)
        .and_then(Value::as_array)
        .filter(|values| values.len() <= maximum_items)
        .ok_or_else(|| invalid_hypothesis(field))?;
    let parsed = values
        .iter()
        .map(|value| {
            value
                .as_str()
                .filter(|value| (1..=maximum_length).contains(&value.trim().chars().count()))
                .map(ToOwned::to_owned)
                .ok_or_else(|| invalid_hypothesis(field))
        })
        .collect::<Result<Vec<_>, _>>()?;
    if parsed.iter().collect::<BTreeSet<_>>().len() != parsed.len() {
        return Err(invalid_hypothesis(field));
    }
    Ok(parsed)
}

fn invalid_hypothesis(field: &'static str) -> Failure {
    Failure::Terminal("HYPOTHESIS_ACTION_PAYLOAD_INVALID", field.to_owned())
}

#[cfg(test)]
mod approved_hypothesis_execution_tests {
    use super::*;

    fn action_payload() -> Value {
        json!({
            "kind":"HYPOTHESIS",
            "target":{
                "type":"CASE",
                "id":"11111111-1111-4111-8111-111111111111",
                "version":3,
                "digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            },
            "objectScopeDigest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "contentDigest":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            "proposal":{
                "kind":"HYPOTHESIS",
                "statement":"검증할 가설",
                "supportingCitationIds":["22222222-2222-4222-8222-222222222222"],
                "contradictingCitationIds":["33333333-3333-4333-8333-333333333333"],
                "unknowns":["추가 확인 필요"],
                "limitations":[]
            }
        })
    }

    #[test]
    fn exact_hypothesis_payload_is_closed_and_typed() {
        let parsed = hypothesis_action(&action_payload()).expect("valid hypothesis action");
        assert_eq!(parsed.expected_case_version, 3);
        assert_eq!(parsed.supporting_citation_ids.len(), 1);
        assert_eq!(parsed.contradicting_citation_ids.len(), 1);
    }

    #[test]
    fn duplicate_cross_relation_citation_fails_closed() {
        let mut payload = action_payload();
        payload["proposal"]["contradictingCitationIds"] =
            payload["proposal"]["supportingCitationIds"].clone();
        assert!(hypothesis_action(&payload).is_err());
    }

    #[test]
    fn unexpected_payload_field_fails_closed() {
        let mut payload = action_payload();
        payload["proposal"]["automaticMerge"] = json!(true);
        assert!(hypothesis_action(&payload).is_err());
    }

    #[test]
    fn hypothesis_execution_is_closed_to_generation_one() {
        let execution_id = Uuid::from_u128(4);
        let payload = json!({
            "executionId":execution_id,
            "generation":2,
            "actionKind":"HYPOTHESIS",
            "targetCommand":"createHypothesis"
        });
        let error = approved_execution(
            payload.as_object().expect("event payload object"),
            execution_id,
        )
        .expect_err("generation two must fail closed");
        assert!(matches!(
            error,
            Failure::Terminal("INVALID_ACTION_EXECUTION", detail)
                if detail == "hypothesis generation"
        ));
    }
}
