use super::{Failure, ProviderTurnIdentity, database, required};
use gurine_agent_orchestration::runtime::SnapshotBinding;
use sqlx::{Postgres, Transaction};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum RuntimeSnapshotContract {
    V1,
    V2,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct ValidatedRuntimeSnapshot {
    pub contract: RuntimeSnapshotContract,
    pub producer_generation: i64,
}

pub(super) async fn validate(
    executor: &mut Transaction<'_, Postgres>,
    turn: &ProviderTurnIdentity,
    binding: &SnapshotBinding,
) -> Result<ValidatedRuntimeSnapshot, Failure> {
    if binding.run_id != turn.run_id || binding.input_snapshot_sha256 != turn.input_snapshot_sha256
    {
        return Err(invalid_binding());
    }
    let run = sqlx::query!(
        r#"
        SELECT run.run_contract_version AS "run_contract_version!",
               run.dataset_snapshot_id,
               btrim(run.input_snapshot_hash::text) AS "input_snapshot_sha256!",
               run.evidence_scope_ids AS "evidence_scope_ids!",
               run.case_id AS "case_id!", snapshot.id AS snapshot_id,
               btrim(snapshot.snapshot_sha256::text) AS snapshot_sha256,
               snapshot.snapshot_kind, snapshot.state AS snapshot_state,
               snapshot.producer_generation,
               snapshot.selection_spec->>'caseId' AS selection_case_id
          FROM ops.agent_runs run
          LEFT JOIN core.dataset_snapshots snapshot ON snapshot.id = $2
         WHERE run.id = $1
        "#,
        turn.run_id,
        binding.input_snapshot_id,
    )
    .fetch_optional(&mut **executor)
    .await
    .map_err(database)?
    .ok_or_else(invalid_binding)?;
    if run.input_snapshot_sha256 != binding.input_snapshot_sha256
        || run.snapshot_id != Some(binding.input_snapshot_id)
        || run.snapshot_sha256.as_deref() != Some(binding.input_snapshot_sha256.as_str())
        || run.snapshot_state.as_deref() != Some("READY")
    {
        return Err(invalid_binding());
    }
    let wrong_snapshot = required(
        sqlx::query_scalar!(
            "SELECT EXISTS(SELECT 1 FROM ops.agent_source_uses source_use
               WHERE source_use.agent_run_id=$1
                 AND source_use.dataset_snapshot_id IS NOT NULL
                 AND source_use.dataset_snapshot_id<>$2)",
            turn.run_id,
            binding.input_snapshot_id,
        )
        .fetch_one(&mut **executor)
        .await
        .map_err(database)?,
    )
    .map_err(database)?;
    if wrong_snapshot {
        return Err(invalid_binding());
    }
    let expected_case_id = run.case_id.to_string();
    let producer_generation = required(run.producer_generation).map_err(database)?;
    if producer_generation < 1 {
        return Err(invalid_binding());
    }
    match run.run_contract_version {
        1 => Ok(ValidatedRuntimeSnapshot {
            contract: RuntimeSnapshotContract::V1,
            producer_generation,
        }),
        2 if run.dataset_snapshot_id == Some(binding.input_snapshot_id)
            && run.evidence_scope_ids == serde_json::json!([])
            && turn.dataset_snapshot_id == Some(binding.input_snapshot_id)
            && run.snapshot_kind.as_deref() == Some("AGENT_CASE")
            && run.selection_case_id.as_deref() == Some(expected_case_id.as_str()) =>
        {
            validate_source_use_set(executor, turn.run_id, binding.input_snapshot_id).await?;
            Ok(ValidatedRuntimeSnapshot {
                contract: RuntimeSnapshotContract::V2,
                producer_generation,
            })
        }
        _ => Err(invalid_binding()),
    }
}

async fn validate_source_use_set(
    executor: &mut Transaction<'_, Postgres>,
    run_id: uuid::Uuid,
    dataset_snapshot_id: uuid::Uuid,
) -> Result<(), Failure> {
    let complete = required(
        sqlx::query_scalar!(
            r#"
            SELECT EXISTS(
                     SELECT 1 FROM core.dataset_snapshot_members member
                      JOIN core.dataset_snapshot_member_sources source
                        ON source.dataset_snapshot_id=member.dataset_snapshot_id AND source.snapshot_member_id=member.id
                       AND source.snapshot_member_digest=member.member_digest AND source.source_kind='SOURCE_DOCUMENT'
                     WHERE member.dataset_snapshot_id=$2
                       AND member.object_type IN ('AGENCY','SUPPLIER','CONTRACT','CONTRACT_LINE_ITEM','CONTRACT_CHANGE','PRICE_OBSERVATION','TYPED_RELATIONSHIP_ASSERTION')
                   )
               AND NOT EXISTS(
                     SELECT 1 FROM core.dataset_snapshot_members member
                      JOIN core.dataset_snapshot_member_sources source
                        ON source.dataset_snapshot_id=member.dataset_snapshot_id AND source.snapshot_member_id=member.id
                       AND source.snapshot_member_digest=member.member_digest AND source.source_kind='SOURCE_DOCUMENT'
                     WHERE member.dataset_snapshot_id=$2
                       AND member.object_type IN ('AGENCY','SUPPLIER','CONTRACT','CONTRACT_LINE_ITEM','CONTRACT_CHANGE','PRICE_OBSERVATION','TYPED_RELATIONSHIP_ASSERTION')
                       AND 1<>(SELECT count(*) FROM ops.agent_source_uses source_use
                                WHERE source_use.agent_run_id=$1 AND source_use.use_kind='TOOL_QUERY'
                                  AND source_use.source_kind='DATASET_MEMBER'
                                  AND source_use.provider_turn_id IS NULL AND source_use.tool_call_id IS NULL
                                  AND source_use.dataset_snapshot_id=$2
                                  AND source_use.snapshot_member_id=member.id AND source_use.snapshot_member_digest=member.member_digest
                                  AND source_use.snapshot_member_source_id=source.id
                                  AND source_use.snapshot_member_source_digest=source.source_digest
                                  AND source_use.member_source_kind='SOURCE_DOCUMENT'
                                  AND source_use.object_type=member.object_type AND source_use.object_id=member.object_id
                                  AND source_use.object_version=member.object_version
                                  AND source_use.object_content_sha256=member.object_content_sha256
                                  AND source_use.source_document_id=source.source_document_id AND source_use.source_asset_id=source.source_asset_id
                                  AND source_use.source_asset_revision=source.source_asset_revision
                                  AND source_use.source_content_sha256=source.source_content_sha256
                                  AND source_use.access_right='ALLOW' AND source_use.private_storage_right='ALLOW'
                                  AND source_use.model_egress_right='ALLOW' AND source_use.model_use_right='ALLOW'
                                  AND source_use.derivative_creation_right='ALLOW' AND source_use.excerpt_right='ALLOW'
                                  AND source_use.redistribution_right='ALLOW' AND source_use.commercial_use_right='ALLOW'
                                  AND source_use.public_display_right='ALLOW'
                                  AND (source_use.rights_expires_at IS NULL OR source_use.rights_expires_at>transaction_timestamp()))
                   )
               AND NOT EXISTS(
                     SELECT 1 FROM ops.agent_source_uses source_use
                      WHERE source_use.agent_run_id=$1 AND source_use.use_kind='TOOL_QUERY'
                        AND source_use.provider_turn_id IS NULL AND source_use.tool_call_id IS NULL
                        AND (source_use.source_kind<>'DATASET_MEMBER' OR source_use.dataset_snapshot_id<>$2)
                   )
            "#,
            run_id,
            dataset_snapshot_id,
        )
        .fetch_one(&mut **executor)
        .await
        .map_err(database)?,
    )
    .map_err(database)?;
    if !complete {
        return Err(Failure::Terminal(
            "AGENT_SOURCE_USE_MISSING",
            run_id.to_string(),
        ));
    }
    Ok(())
}

fn invalid_binding() -> Failure {
    Failure::Terminal(
        "AGENT_EVIDENCE_SCOPE_INVALID",
        "input snapshot binding".to_owned(),
    )
}
