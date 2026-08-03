use super::*;

pub(super) async fn insert_research_artifact_model_inputs(
    executor: &mut sqlx::PgConnection,
    turn: &ProviderTurnIdentity,
    receipt_id: Option<Uuid>,
    receipt_sha256: Option<&str>,
) -> Result<(), Failure> {
    // This projection is receipt-bound even when the source artifact was
    // selected by an earlier tool turn.  Digest bytes are produced by the
    // database RFC8785 helper, never by jsonb::text.
    let sql = r#"
      WITH parents AS (
        SELECT p.* FROM ops.agent_source_uses p
         WHERE p.agent_run_id=$1 AND p.use_kind='TOOL_RESULT'
           AND p.source_kind='RESEARCH_ARTIFACT' AND p.provider_turn_id<>$2
      ), identities AS (
        SELECT p.*, gen_random_uuid() AS new_source_use_id,
               clock_timestamp() AS new_occurred_at
          FROM parents p
      ), unsigned AS (
        SELECT i.*, jsonb_build_object(
          'schemaVersion','source-use.v2','sourceUseId',i.new_source_use_id,
          'agentRunId',i.agent_run_id,'providerTurnId',$2,
          'parentSourceUseId',i.source_use_id,
          'parentSourceUseSha256',btrim(i.source_use_sha256::text),
          'useKind','MODEL_INPUT','sourceKind','RESEARCH_ARTIFACT',
          'researchArtifactId',i.research_artifact_id,
          'researchAssetId',i.research_asset_id,
          'researchAssetRevision',i.research_asset_revision,
          'researchArtifactSha256',btrim(i.research_artifact_sha256::text),
          'researchContentSha256',btrim(i.research_content_sha256::text),
          'researchSourceFetchId',i.research_source_fetch_id,
          'locator',jsonb_build_object('kind',i.locator_kind,'value',i.locator_value,
             'locatorSha256',btrim(i.locator_sha256::text)),
          'selectedContentSha256',btrim(i.selected_content_sha256::text),
          'classification',i.classification,'rightsDecisionId',i.asset_rights_decision_id,
          'rightsDecisionSha256',btrim(i.asset_rights_decision_sha256::text),
          'providerReceiptId',$3,'providerReceiptSha256',$4,
          'occurredAt',i.new_occurred_at) AS payload
          FROM identities i
      ), payloads AS (
        SELECT u.*, encode(extensions.digest(ops.canonical_jsonb_v1(u.payload),'sha256'),'hex') AS digest
          FROM unsigned u
      )
      INSERT INTO ops.agent_source_uses(
        source_use_id,source_use_contract_version,agent_run_id,provider_turn_id,
        tool_call_id,parent_source_use_id,parent_source_use_sha256,use_kind,source_kind,
        research_artifact_id,research_asset_id,research_asset_revision,research_artifact_sha256,
        research_content_sha256,research_source_fetch_id,locator_kind,locator_value,locator_sha256,
        selected_content_sha256,classification,rights_binding_kind,rights_asset_id,
        rights_asset_revision,rights_asset_sha256,asset_rights_decision_id,
        asset_rights_decision_version,asset_rights_decision_sha256,rights_effective_at,
        rights_expires_at,access_right,private_storage_right,model_egress_right,model_use_right,
        derivative_creation_right,excerpt_right,redistribution_right,commercial_use_right,
        public_display_right,rights_policy_version,rights_policy_sha256,provider_receipt_id,
        provider_receipt_sha256,occurred_at,source_use_canonical,source_use_sha256)
      SELECT p.new_source_use_id,2,p.agent_run_id,$2,NULL,p.source_use_id,p.source_use_sha256,
        'MODEL_INPUT','RESEARCH_ARTIFACT',p.research_artifact_id,p.research_asset_id,
        p.research_asset_revision,p.research_artifact_sha256,p.research_content_sha256,
        p.research_source_fetch_id,p.locator_kind,p.locator_value,p.locator_sha256,
        p.selected_content_sha256,p.classification,p.rights_binding_kind,p.rights_asset_id,
        p.rights_asset_revision,p.rights_asset_sha256,p.asset_rights_decision_id,
        p.asset_rights_decision_version,p.asset_rights_decision_sha256,p.rights_effective_at,
        p.rights_expires_at,p.access_right,p.private_storage_right,p.model_egress_right,
        p.model_use_right,p.derivative_creation_right,p.excerpt_right,p.redistribution_right,
        p.commercial_use_right,p.public_display_right,p.rights_policy_version,p.rights_policy_sha256,
        $3,$4,p.new_occurred_at,
        ops.canonical_jsonb_v1(p.payload || jsonb_build_object('sourceUseSha256',p.digest)),p.digest
        FROM payloads p
      ON CONFLICT (agent_run_id,source_use_sha256) DO NOTHING
    "#;
    sqlx::query(sql)
        .bind(turn.run_id)
        .bind(turn.turn_id)
        .bind(receipt_id)
        .bind(receipt_sha256)
        .execute(&mut *executor)
        .await
        .map_err(database)?;
    Ok(())
}
