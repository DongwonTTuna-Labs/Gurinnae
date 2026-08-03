use super::*;

const HYPOTHESIS_DRAFT_FIELDS: [&str; 7] = [
    "proposalKind",
    "proposalState",
    "statement",
    "assessment",
    "supportingCitationIndexes",
    "contradictingCitationIndexes",
    "unknowns",
];

pub(super) struct HypothesisMaterialization {
    pub(super) payload: Value,
    pub(super) citation_ids: Vec<Uuid>,
}

struct ExistingHypothesisRow {
    payload: Value,
    payload_sha256: Option<String>,
    payload_canonical: Option<Vec<u8>>,
    citation_ids: Vec<Uuid>,
    citation_ordinals: Vec<i32>,
    source_use_sha256s: Vec<String>,
}

pub(super) fn materialize_new_hypothesis(
    draft: &Value,
    output: &Value,
) -> Result<HypothesisMaterialization, Failure> {
    let resolved = resolve_citations(draft, output)?;
    let citation_ids = resolved.iter().map(|_| Uuid::new_v4()).collect::<Vec<_>>();
    let payload = canonical_hypothesis_payload(draft, &citation_ids)?;
    Ok(HypothesisMaterialization {
        payload,
        citation_ids,
    })
}

pub(super) async fn load_existing_hypothesis(
    executor: &mut sqlx::PgConnection,
    turn: &ProviderTurnIdentity,
    validation_id: Uuid,
    draft: &Value,
    output: &Value,
) -> Result<HypothesisMaterialization, Failure> {
    validate_hypothesis_draft(draft)?;
    let resolved_sources = resolve_citations(draft, output)?
        .into_iter()
        .map(|(_, _, source)| source)
        .collect::<Vec<_>>();
    let rows = sqlx::query_as!(
        ExistingHypothesisRow,
        r#"SELECT suggestion.payload,
                  suggestion.payload_sha256::text AS "payload_sha256?",
                  suggestion.payload_canonical AS "payload_canonical?",
                  COALESCE(array_agg(citation.citation_id ORDER BY citation.citation_ordinal)
                    FILTER (WHERE citation.citation_id IS NOT NULL),ARRAY[]::uuid[])
                    AS "citation_ids!: Vec<Uuid>",
                  COALESCE(array_agg(citation.citation_ordinal ORDER BY citation.citation_ordinal)
                    FILTER (WHERE citation.citation_id IS NOT NULL),ARRAY[]::integer[])
                    AS "citation_ordinals!: Vec<i32>",
                  COALESCE(array_agg(btrim(citation.source_use_sha256)::text ORDER BY citation.citation_ordinal)
                    FILTER (WHERE citation.citation_id IS NOT NULL),ARRAY[]::text[])
                    AS "source_use_sha256s!: Vec<String>"
             FROM ops.agent_suggestions suggestion
             LEFT JOIN ops.agent_proposal_citations citation
               ON citation.proposal_id=suggestion.id
              AND citation.agent_run_id=suggestion.agent_run_id
              AND citation.validation_id=suggestion.citation_validation_id
            WHERE suggestion.agent_run_id=$1
              AND suggestion.citation_validation_id=$2
              AND suggestion.suggestion_type='HYPOTHESIS'
              AND suggestion.proposal_contract_version=2
              AND suggestion.input_snapshot_sha256=CAST($3 AS char(64))
            GROUP BY suggestion.id,suggestion.payload,suggestion.payload_sha256,
                     suggestion.payload_canonical"#,
        turn.run_id,
        validation_id,
        &turn.input_snapshot_sha256,
    )
    .fetch_all(&mut *executor)
    .await
    .map_err(database)?;

    let mut matches = rows
        .into_iter()
        .filter_map(|row| replay_materialization(draft, &resolved_sources, row).transpose())
        .collect::<Result<Vec<_>, _>>()?;
    if matches.len() != 1 {
        return Err(Failure::Terminal(
            "AGENT_PROPOSAL_REPLAY_MISMATCH",
            format!("HYPOTHESIS:{}", matches.len()),
        ));
    }
    matches.pop().ok_or_else(|| {
        Failure::Terminal("AGENT_PROPOSAL_REPLAY_MISMATCH", "HYPOTHESIS:0".to_owned())
    })
}

fn replay_materialization(
    draft: &Value,
    resolved_sources: &[String],
    row: ExistingHypothesisRow,
) -> Result<Option<HypothesisMaterialization>, Failure> {
    let citation_ids = payload_citation_ids(&row.payload)?;
    let expected_ordinals = (0..row.citation_ids.len())
        .map(|ordinal| i32::try_from(ordinal))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| Failure::Terminal("AGENT_OUTPUT_INVALID", "citation ordinal".to_owned()))?;
    if citation_ids != row.citation_ids
        || row.citation_ordinals != expected_ordinals
        || row.source_use_sha256s != resolved_sources
        || canonical_hypothesis_payload(draft, &citation_ids)? != row.payload
    {
        return Ok(None);
    }
    let canonical = canonical_bytes(&row.payload)?;
    let digest = sha256(&canonical);
    if row.payload_canonical.as_deref() != Some(canonical.as_slice())
        || row.payload_sha256.as_deref().map(str::trim) != Some(digest.as_str())
    {
        return Err(Failure::Terminal(
            "AGENT_PROPOSAL_REPLAY_MISMATCH",
            "HYPOTHESIS_CANONICAL".to_owned(),
        ));
    }
    Ok(Some(HypothesisMaterialization {
        payload: row.payload,
        citation_ids,
    }))
}

fn canonical_hypothesis_payload(draft: &Value, citation_ids: &[Uuid]) -> Result<Value, Failure> {
    validate_hypothesis_draft(draft)?;
    let supporting_count = citation_indexes(draft, "supportingCitationIndexes")?.len();
    let contradicting_count = citation_indexes(draft, "contradictingCitationIndexes")?.len();
    if citation_ids.len() != supporting_count + contradicting_count {
        return Err(Failure::Terminal(
            "AGENT_OUTPUT_INVALID",
            "hypothesis citation identifier count".to_owned(),
        ));
    }
    let supporting = citation_ids[..supporting_count]
        .iter()
        .map(Uuid::to_string)
        .collect::<Vec<_>>();
    let contradicting = citation_ids[supporting_count..]
        .iter()
        .map(Uuid::to_string)
        .collect::<Vec<_>>();
    Ok(json!({
        "kind":"HYPOTHESIS",
        "statement":draft["statement"].clone(),
        "supportingCitationIds":supporting,
        "contradictingCitationIds":contradicting,
        "unknowns":draft["unknowns"].clone(),
        // HypothesisDraft has no limitations field. Empty is the only lossless
        // AgentProposal value; copying output-wide unknowns would invent meaning.
        "limitations":[],
    }))
}

fn validate_hypothesis_draft(draft: &Value) -> Result<(), Failure> {
    let object = draft.as_object().ok_or_else(|| {
        Failure::Terminal("AGENT_OUTPUT_INVALID", "hypothesis draft object".to_owned())
    })?;
    if object.len() != HYPOTHESIS_DRAFT_FIELDS.len()
        || object
            .keys()
            .any(|key| !HYPOTHESIS_DRAFT_FIELDS.contains(&key.as_str()))
        || draft.get("proposalKind").and_then(Value::as_str) != Some("HYPOTHESIS")
        || draft.get("proposalState").and_then(Value::as_str) != Some("PROPOSAL_ONLY")
        || !matches!(
            draft.get("assessment").and_then(Value::as_str),
            Some("SUPPORTED" | "CONTRADICTED" | "UNRESOLVED")
        )
    {
        return Err(Failure::Terminal(
            "AGENT_OUTPUT_INVALID",
            "hypothesis draft envelope".to_owned(),
        ));
    }
    let statement_length = draft
        .get("statement")
        .and_then(Value::as_str)
        .map(str::chars)
        .map(Iterator::count)
        .unwrap_or_default();
    let unknowns = draft
        .get("unknowns")
        .and_then(Value::as_array)
        .ok_or_else(|| {
            Failure::Terminal("AGENT_OUTPUT_INVALID", "hypothesis unknowns".to_owned())
        })?;
    let unique_unknowns = unknowns
        .iter()
        .filter_map(Value::as_str)
        .collect::<BTreeSet<_>>();
    if !(1..=4_000).contains(&statement_length)
        || unknowns.len() > 50
        || unique_unknowns.len() != unknowns.len()
        || unique_unknowns
            .iter()
            .any(|value| !(1..=1_000).contains(&value.chars().count()))
    {
        return Err(Failure::Terminal(
            "AGENT_OUTPUT_INVALID",
            "hypothesis draft content".to_owned(),
        ));
    }
    let supporting = citation_indexes(draft, "supportingCitationIndexes")?;
    let contradicting = citation_indexes(draft, "contradictingCitationIndexes")?;
    if supporting.is_empty() && contradicting.is_empty() {
        return Err(Failure::Terminal(
            "AGENT_OUTPUT_INVALID",
            "hypothesis citation missing".to_owned(),
        ));
    }
    Ok(())
}

fn citation_indexes<'a>(draft: &'a Value, key: &str) -> Result<&'a [Value], Failure> {
    draft
        .get(key)
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .ok_or_else(|| Failure::Terminal("AGENT_OUTPUT_INVALID", format!("hypothesis {key}")))
}

fn payload_citation_ids(payload: &Value) -> Result<Vec<Uuid>, Failure> {
    let mut ids = Vec::new();
    for key in ["supportingCitationIds", "contradictingCitationIds"] {
        let values = payload.get(key).and_then(Value::as_array).ok_or_else(|| {
            Failure::Terminal("AGENT_OUTPUT_INVALID", format!("hypothesis {key}"))
        })?;
        for value in values {
            ids.push(
                value
                    .as_str()
                    .and_then(|value| Uuid::parse_str(value).ok())
                    .ok_or_else(|| {
                        Failure::Terminal("AGENT_OUTPUT_INVALID", format!("hypothesis {key}"))
                    })?,
            );
        }
    }
    if ids.iter().copied().collect::<BTreeSet<_>>().len() != ids.len() {
        return Err(Failure::Terminal(
            "AGENT_OUTPUT_INVALID",
            "hypothesis duplicate citation identifier".to_owned(),
        ));
    }
    Ok(ids)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn draft() -> Value {
        json!({
            "proposalKind":"HYPOTHESIS",
            "proposalState":"PROPOSAL_ONLY",
            "statement":"공개 근거를 더 확인할 가설",
            "assessment":"UNRESOLVED",
            "supportingCitationIndexes":[0],
            "contradictingCitationIndexes":[1],
            "unknowns":["계약 시점 확인 필요"]
        })
    }

    #[test]
    fn canonical_payload_uses_server_citation_ids_and_no_invented_limitations() {
        let first = Uuid::from_u128(1);
        let second = Uuid::from_u128(2);
        let payload = canonical_hypothesis_payload(&draft(), &[first, second])
            .expect("closed hypothesis payload");
        assert_eq!(payload.as_object().map(|object| object.len()), Some(6));
        assert_eq!(payload["supportingCitationIds"], json!([first]));
        assert_eq!(payload["contradictingCitationIds"], json!([second]));
        assert_eq!(payload["limitations"], json!([]));
        assert_eq!(payload["unknowns"], draft()["unknowns"]);
    }

    #[test]
    fn canonical_payload_rejects_unbound_or_malformed_drafts() {
        assert!(canonical_hypothesis_payload(&draft(), &[Uuid::from_u128(1)]).is_err());
        let mut extra = draft();
        extra["limitations"] = json!(["provider supplied"]);
        assert!(
            canonical_hypothesis_payload(&extra, &[Uuid::from_u128(1), Uuid::from_u128(2)])
                .is_err()
        );
        let mut no_citations = draft();
        no_citations["supportingCitationIndexes"] = json!([]);
        no_citations["contradictingCitationIndexes"] = json!([]);
        assert!(canonical_hypothesis_payload(&no_citations, &[]).is_err());
    }

    #[test]
    fn replay_reuses_only_the_exact_persisted_citation_identifiers() {
        let ids = [Uuid::from_u128(1), Uuid::from_u128(2)];
        let payload =
            canonical_hypothesis_payload(&draft(), &ids).expect("closed hypothesis payload");
        let canonical = canonical_bytes(&payload).expect("canonical payload");
        let sources = vec!["a".repeat(64), "b".repeat(64)];
        let exact = ExistingHypothesisRow {
            payload: payload.clone(),
            payload_sha256: Some(sha256(&canonical)),
            payload_canonical: Some(canonical),
            citation_ids: ids.to_vec(),
            citation_ordinals: vec![0, 1],
            source_use_sha256s: sources.clone(),
        };
        let replayed = replay_materialization(&draft(), &sources, exact)
            .expect("exact replay")
            .expect("matching materialization");
        assert_eq!(replayed.citation_ids, ids.to_vec());

        let wrong_source = ExistingHypothesisRow {
            payload: payload.clone(),
            payload_sha256: Some(sha256(
                &canonical_bytes(&payload).expect("canonical payload"),
            )),
            payload_canonical: Some(canonical_bytes(&payload).expect("canonical payload")),
            citation_ids: ids.to_vec(),
            citation_ordinals: vec![0, 1],
            source_use_sha256s: vec!["c".repeat(64), "b".repeat(64)],
        };
        assert!(
            replay_materialization(&draft(), &sources, wrong_source)
                .expect("closed replay comparison")
                .is_none()
        );
    }
}
