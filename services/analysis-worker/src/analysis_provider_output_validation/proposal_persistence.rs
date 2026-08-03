use super::hypotheses::{load_existing_hypothesis, materialize_new_hypothesis};
use super::*;

struct ProposalInsert<'a> {
    validation_id: Uuid,
    proposal_type: &'a str,
    payload: &'a Value,
    payload_sha256: &'a str,
    payload_canonical: Vec<u8>,
}

struct ProposalWork<'a> {
    turn: &'a ProviderTurnIdentity,
    validation: &'a PersistedValidation,
    proposal_type: &'static str,
    raw_payload: Value,
    output: &'a Value,
}

pub(super) async fn persist_output_proposals(
    executor: &mut sqlx::PgConnection,
    turn: &ProviderTurnIdentity,
    validation: PersistedValidation,
    proposals: Vec<(&'static str, Value)>,
    output: &Value,
) -> Result<(), Failure> {
    for (proposal_type, raw_payload) in proposals {
        persist_output_proposal(
            executor,
            ProposalWork {
                turn,
                validation: &validation,
                proposal_type,
                raw_payload,
                output,
            },
        )
        .await?;
    }
    Ok(())
}

async fn persist_output_proposal(
    executor: &mut sqlx::PgConnection,
    work: ProposalWork<'_>,
) -> Result<(), Failure> {
    let hypothesis = hypothesis_materialization(executor, &work).await?;
    let payload = hypothesis
        .as_ref()
        .map_or_else(|| work.raw_payload.clone(), |value| value.payload.clone());
    let payload_canonical = canonical_bytes(&payload)?;
    let payload_sha256 = sha256(&payload_canonical);
    let inserted = insert_proposal(
        executor,
        work.turn,
        ProposalInsert {
            validation_id: work.validation.id,
            proposal_type: work.proposal_type,
            payload: &payload,
            payload_sha256: &payload_sha256,
            payload_canonical,
        },
    )
    .await?;
    let proposal_id = match inserted {
        Some(id) => id,
        None => {
            load_exact_proposal(
                executor,
                work.turn,
                work.validation.id,
                work.proposal_type,
                &payload,
                &payload_sha256,
            )
            .await?
        }
    };
    insert_proposal_citations(
        executor,
        work.turn,
        work.validation.id,
        proposal_id,
        work.proposal_type,
        &work.raw_payload,
        work.output,
        &payload_sha256,
        hypothesis.as_ref(),
    )
    .await
}

async fn hypothesis_materialization(
    executor: &mut sqlx::PgConnection,
    work: &ProposalWork<'_>,
) -> Result<Option<HypothesisMaterialization>, Failure> {
    if work.proposal_type != "HYPOTHESIS" {
        return Ok(None);
    }
    if work.validation.replayed {
        load_existing_hypothesis(
            executor,
            work.turn,
            work.validation.id,
            &work.raw_payload,
            work.output,
        )
        .await
        .map(Some)
    } else {
        materialize_new_hypothesis(&work.raw_payload, work.output).map(Some)
    }
}

async fn insert_proposal(
    executor: &mut sqlx::PgConnection,
    turn: &ProviderTurnIdentity,
    insert: ProposalInsert<'_>,
) -> Result<Option<Uuid>, Failure> {
    sqlx::query_scalar!(
        r#"INSERT INTO ops.agent_suggestions(
           agent_run_id,case_id,suggestion_type,payload,evidence_ids,citation_checks,status,
           proposal_contract_version,target_schema_version,payload_sha256,payload_canonical,
           input_snapshot_sha256,citation_validation_id,expires_at)
         SELECT $1,(SELECT case_id FROM ops.agent_runs WHERE id=$1),$2,$3,'[]'::jsonb,'[]'::jsonb,'PENDING',2,$4,CAST($5 AS char(64)),$6,
                $7,$8,clock_timestamp()+interval '7 days'
         WHERE NOT EXISTS (SELECT 1 FROM ops.agent_suggestions WHERE agent_run_id=$1 AND citation_validation_id=$8 AND payload_sha256=CAST($5 AS char(64)))
         RETURNING id"#,
        turn.run_id,
        insert.proposal_type,
        insert.payload,
        &turn.output_schema_id,
        insert.payload_sha256,
        insert.payload_canonical,
        &turn.input_snapshot_sha256,
        insert.validation_id,
    )
    .fetch_optional(&mut *executor)
    .await
    .map_err(database)
}
