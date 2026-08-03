mod analysis_provider_output_validation;
mod analysis_research_lineage;

use analysis_provider_output_validation::insert_output_validation;
use analysis_research_lineage::insert_research_artifact_model_inputs;

/// Bind the provider's accepted receipt to the exact evidence segments that
/// were selected by the pre-dispatch TOOL_QUERY rows. The insert is
/// idempotent on the run/source-use digest pair, so a replay of the same
/// receipt cannot create a second lineage branch.
async fn insert_model_input_source_uses(
    executor: &mut sqlx::PgConnection,
    turn: &ProviderTurnIdentity,
    receipt_id: Uuid,
    receipt_sha256: &str,
) -> Result<(), Failure>
where
{
    sqlx::query!(
        r#"
        WITH candidates AS (
          SELECT DISTINCT ON (root.source_use_id)
                 root.source_use_id AS parent_source_use_id,
                 root.source_use_sha256 AS parent_source_use_sha256,
                 root.agent_run_id,
                 root.dataset_snapshot_id,
                 member.id AS snapshot_member_id,
                 member.member_digest AS snapshot_member_digest,
                 member_source.id AS snapshot_member_source_id,
                 member_source.source_digest AS snapshot_member_source_digest,
                 member_source.source_kind AS member_source_kind,
                 member.object_type,
                 member.object_id,
                 member.object_version,
                 member.object_content_sha256,
                 seg.id AS evidence_segment_id,
                 seg.source_document_id,
                 seg.source_asset_id,
                 seg.source_asset_revision,
                 seg.source_content_sha256,
                 seg.locator_kind,
                 seg.locator_value,
                 seg.locator_digest,
                 seg.selected_content_sha256,
                 seg.classification,
                 rights.id AS rights_decision_id,
                 rights.decision_version AS rights_decision_version,
                 rights.decision_sha256 AS rights_decision_sha256,
                 rights.effective_at AS rights_effective_at,
                 rights.expires_at AS rights_expires_at,
                 rights.access_right,
                 rights.private_storage_right,
                 rights.model_egress_right,
                 rights.model_use_right,
                 rights.derivative_creation_right,
                 rights.excerpt_right,
                 rights.redistribution_right,
                 rights.commercial_use_right,
                 rights.public_display_right,
                 rights.policy_version AS rights_policy_version,
                 rights.policy_sha256 AS rights_policy_sha256,
                 turn.provider_turn_id,
                 turn.provider_receipt_id,
                 turn.provider_receipt_sha256,
                 turn.input_snapshot_sha256
            FROM ops.agent_source_uses root
            JOIN ops.agent_provider_turns turn
              ON turn.agent_run_id = root.agent_run_id
             AND turn.provider_turn_id = $1
             AND turn.status IN ('DISPATCHED','COMPLETED')
            JOIN core.dataset_snapshot_members member
              ON member.dataset_snapshot_id = root.dataset_snapshot_id
             AND member.snapshot_kind = 'AGENT_CASE'
             AND member.object_type = 'EVIDENCE_SEGMENT'
             AND member.object_version = 1
            JOIN raw.evidence_segments seg
              ON seg.id = member.evidence_segment_id
             AND seg.source_document_id = root.source_document_id
             AND seg.locator_value = root.locator_value
             AND seg.selected_content_sha256 = root.selected_content_sha256
            JOIN core.dataset_snapshot_member_sources member_source
              ON member_source.dataset_snapshot_id = member.dataset_snapshot_id
             AND member_source.snapshot_member_id = member.id
             AND member_source.snapshot_member_digest = member.member_digest
             AND member_source.evidence_segment_id = seg.id
            JOIN raw.asset_rights_decisions rights
              ON rights.id = root.asset_rights_decision_id
             AND rights.asset_id = seg.source_asset_id
             AND rights.asset_revision = seg.source_asset_revision
             AND rights.asset_sha256 = seg.source_content_sha256
             AND rights.decision_version = root.asset_rights_decision_version
             AND rights.decision_sha256 = root.asset_rights_decision_sha256
           WHERE root.agent_run_id = turn.agent_run_id
             AND root.use_kind = 'TOOL_QUERY'
             AND root.source_kind = 'DATASET_MEMBER'
           ORDER BY root.source_use_id, member.member_ordinal
        ), identities AS (
          SELECT c.*, gen_random_uuid() AS source_use_id, clock_timestamp() AS occurred_at
            FROM candidates c
        ), unsigned_payloads AS (
          SELECT i.*,
                 jsonb_build_object(
                   'schemaVersion','source-use.v2',
                   'sourceUseId',i.source_use_id,
                   'agentRunId',i.agent_run_id,
                   'providerTurnId',i.provider_turn_id,
                   'toolCallId',NULL,
                   'parentSourceUseId',i.parent_source_use_id,
                   'parentSourceUseSha256',i.parent_source_use_sha256,
                   'useKind','MODEL_INPUT',
                   'sourceKind','EVIDENCE_SEGMENT',
                   'sourceIdentity',jsonb_build_object(
                     'kind','EVIDENCE_SEGMENT',
                     'datasetSnapshotId',i.dataset_snapshot_id,
                     'snapshotMemberId',i.snapshot_member_id,
                     'snapshotMemberDigest',btrim(i.snapshot_member_digest::text),
                     'evidenceSegmentId',i.evidence_segment_id,
                     'sourceDocumentId',i.source_document_id,
                     'sourceAssetId',i.source_asset_id,
                     'sourceAssetRevision',i.source_asset_revision,
                     'sourceContentSha256',btrim(i.source_content_sha256::text)),
                   'locator',jsonb_build_object(
                     'kind',i.locator_kind,
                     'value',i.locator_value,
                     'locatorSha256',btrim(i.locator_digest::text)),
                   'selectedContentSha256',btrim(i.selected_content_sha256::text),
                   'classification',i.classification,
                   'rightsDecision',jsonb_build_object(
                     'decisionId',i.rights_decision_id,
                     'decisionVersion',i.rights_decision_version,
                     'decisionSha256',btrim(i.rights_decision_sha256::text),
                     'effectiveAt',i.rights_effective_at,
                     'expiresAt',i.rights_expires_at,
                     'accessRight',i.access_right,
                     'privateStorageRight',i.private_storage_right,
                     'modelEgressRight',i.model_egress_right,
                     'modelUseRight',i.model_use_right,
                     'derivativeCreationRight',i.derivative_creation_right,
                     'excerptRight',i.excerpt_right,
                     'redistributionRight',i.redistribution_right,
                     'commercialUseRight',i.commercial_use_right,
                     'publicDisplayRight',i.public_display_right),
                   'providerReceiptId',COALESCE($2,i.provider_turn_id),
                   'providerReceiptSha256',COALESCE($3,i.input_snapshot_sha256),
                   'occurredAt',i.occurred_at
                 ) AS unsigned_canonical
            FROM identities i
        ), payloads AS (
          SELECT u.*,
                 encode(extensions.digest(ops.canonical_jsonb_v1(u.unsigned_canonical),'sha256'),'hex') AS source_use_sha256
            FROM unsigned_payloads u
        )
        INSERT INTO ops.agent_source_uses(
          source_use_id,source_use_contract_version,agent_run_id,provider_turn_id,
          tool_call_id,parent_source_use_id,parent_source_use_sha256,use_kind,
          source_kind,dataset_snapshot_id,snapshot_member_id,snapshot_member_digest,
          snapshot_member_source_id,snapshot_member_source_digest,member_source_kind,
          object_type,object_id,object_version,object_content_sha256,evidence_segment_id,
          source_document_id,source_asset_id,source_asset_revision,source_content_sha256,
          locator_kind,locator_value,locator_sha256,selected_content_sha256,classification,
          rights_binding_kind,rights_asset_id,rights_asset_revision,rights_asset_sha256,
          asset_rights_decision_id,asset_rights_decision_version,asset_rights_decision_sha256,
          rights_effective_at,rights_expires_at,access_right,private_storage_right,
          model_egress_right,model_use_right,derivative_creation_right,excerpt_right,
          redistribution_right,commercial_use_right,public_display_right,rights_policy_version,
          rights_policy_sha256,provider_receipt_id,provider_receipt_sha256,occurred_at,
          source_use_canonical,source_use_sha256)
        SELECT p.source_use_id,2,p.agent_run_id,p.provider_turn_id,NULL,
               p.parent_source_use_id,p.parent_source_use_sha256,'MODEL_INPUT',
               'EVIDENCE_SEGMENT',p.dataset_snapshot_id,p.snapshot_member_id,
               p.snapshot_member_digest,p.snapshot_member_source_id,
               p.snapshot_member_source_digest,p.member_source_kind,p.object_type,
               p.object_id,p.object_version,p.object_content_sha256,p.evidence_segment_id,
               p.source_document_id,p.source_asset_id,p.source_asset_revision,
               p.source_content_sha256,p.locator_kind,p.locator_value,p.locator_digest,
               p.selected_content_sha256,p.classification,'ASSET_RIGHTS',p.source_asset_id,
               p.source_asset_revision,p.source_content_sha256,p.rights_decision_id,
               p.rights_decision_version,p.rights_decision_sha256,p.rights_effective_at,
               p.rights_expires_at,p.access_right,p.private_storage_right,p.model_egress_right,
               p.model_use_right,p.derivative_creation_right,p.excerpt_right,
               p.redistribution_right,p.commercial_use_right,p.public_display_right,
               p.rights_policy_version,p.rights_policy_sha256,COALESCE($2,p.provider_turn_id),COALESCE($3,p.input_snapshot_sha256),p.occurred_at,
               ops.canonical_jsonb_v1(p.unsigned_canonical || jsonb_build_object('sourceUseSha256',p.source_use_sha256)),
               p.source_use_sha256
          FROM payloads p
        ON CONFLICT (agent_run_id,source_use_sha256) DO NOTHING
        "#,
        turn.turn_id,
        receipt_id,
        receipt_sha256,
    )
    .execute(&mut *executor)
    .await
    .map_err(database)?;
    insert_research_artifact_model_inputs(executor, turn, receipt_id, receipt_sha256).await?;
    Ok(())
}

async fn insert_model_output_derivation_source_uses(
    executor: &mut sqlx::PgConnection,
    turn: &ProviderTurnIdentity,
    _receipt_id: Uuid,
    _receipt_sha256: &str,
    output: &Value,
) -> Result<(), Failure> {
    // Bind the derivation to the receipt values committed on the provider
    // turn itself.  The completion owner is the source of truth; reusing a
    // separately parsed value here could trip the database receipt guard on
    // an otherwise successful completion.
    let receipt = sqlx::query!(
        r#"SELECT provider_receipt_id, btrim(provider_receipt_sha256::text)
             FROM ops.agent_provider_turns
            WHERE agent_run_id=$1 AND provider_turn_id=$2
              AND provider_receipt_id IS NOT NULL
              AND provider_receipt_sha256 IS NOT NULL"#,
        turn.run_id,
        turn.turn_id,
    )
    .fetch_optional(&mut *executor)
    .await
    .map_err(database)?
    .ok_or_else(|| {
        Failure::Terminal(
            "PROVIDER_RECEIPT_INVALID",
            "completed turn receipt missing".into(),
        )
    })?;
    let bound_receipt_id = required(receipt.provider_receipt_id).map_err(database)?;
    let bound_receipt_sha256 = required(receipt.btrim).map_err(database)?;
    let output_sha256 = sha256(&canonical_bytes(output)?);
    sqlx::query(
        r#"
        WITH parents AS (
          SELECT * FROM ops.agent_source_uses
           WHERE agent_run_id=$1 AND provider_turn_id=$2 AND use_kind='MODEL_INPUT'
        ), pending AS (
          SELECT p.* FROM parents p
           WHERE NOT EXISTS (
             SELECT 1 FROM ops.agent_source_uses existing
              WHERE existing.agent_run_id=p.agent_run_id
                AND existing.provider_turn_id=$2
                AND existing.use_kind='CITATION'
                AND existing.parent_source_use_id=p.source_use_id
                AND existing.parent_source_use_sha256=p.source_use_sha256
           )
        ), identities AS (
          SELECT p.*, gen_random_uuid() AS new_source_use_id,
                 clock_timestamp() AS new_occurred_at
            FROM pending p
        ), unsigned AS (
          SELECT i.*, jsonb_build_object(
            'schemaVersion','source-use.v2','sourceUseId',i.new_source_use_id,
            'agentRunId',i.agent_run_id,'providerTurnId',i.provider_turn_id,
            'parentSourceUseId',i.source_use_id,'parentSourceUseSha256',btrim(i.source_use_sha256::text),
            'useKind','MODEL_OUTPUT_DERIVATION','sourceKind',i.source_kind,
            'providerReceiptId',$3,'providerReceiptSha256',$4,'outputSha256',$5,
            'selectedContentSha256',btrim(i.selected_content_sha256::text),
            'locator',jsonb_build_object('kind',i.locator_kind,'value',i.locator_value,'locatorSha256',btrim(i.locator_sha256::text)),
            'classification',i.classification,'occurredAt',i.new_occurred_at
          ) AS payload
          FROM identities i
        ), payloads AS (
          SELECT u.*, encode(extensions.digest(ops.canonical_jsonb_v1(u.payload),'sha256'),'hex') AS digest
            FROM unsigned u
        )
        INSERT INTO ops.agent_source_uses(
          source_use_id,source_use_contract_version,agent_run_id,provider_turn_id,
          parent_source_use_id,parent_source_use_sha256,use_kind,source_kind,
          dataset_snapshot_id,snapshot_member_id,snapshot_member_digest,snapshot_member_source_id,
          snapshot_member_source_digest,member_source_kind,object_type,object_id,object_version,
          object_content_sha256,evidence_segment_id,source_document_id,source_asset_id,
          source_asset_revision,source_content_sha256,response_id,response_version,response_content_sha256,
          response_publication_consent_sha256,research_artifact_id,research_asset_id,research_asset_revision,
          research_artifact_sha256,research_content_sha256,research_source_fetch_id,locator_kind,locator_value,
          locator_sha256,selected_content_sha256,classification,rights_binding_kind,rights_asset_id,
          rights_asset_revision,rights_asset_sha256,asset_rights_decision_id,asset_rights_decision_version,
          asset_rights_decision_sha256,rights_effective_at,rights_expires_at,access_right,private_storage_right,
          model_egress_right,model_use_right,derivative_creation_right,excerpt_right,redistribution_right,
          commercial_use_right,public_display_right,rights_policy_version,rights_policy_sha256,
          provider_receipt_id,provider_receipt_sha256,occurred_at,source_use_canonical,source_use_sha256)
        SELECT p.new_source_use_id,2,p.agent_run_id,p.provider_turn_id,
          p.source_use_id,p.source_use_sha256,'MODEL_OUTPUT_DERIVATION',p.source_kind,
          p.dataset_snapshot_id,p.snapshot_member_id,p.snapshot_member_digest,p.snapshot_member_source_id,
          p.snapshot_member_source_digest,p.member_source_kind,p.object_type,p.object_id,p.object_version,
          p.object_content_sha256,p.evidence_segment_id,p.source_document_id,p.source_asset_id,
          p.source_asset_revision,p.source_content_sha256,p.response_id,p.response_version,p.response_content_sha256,
          p.response_publication_consent_sha256,p.research_artifact_id,p.research_asset_id,p.research_asset_revision,
          p.research_artifact_sha256,p.research_content_sha256,p.research_source_fetch_id,p.locator_kind,p.locator_value,
          p.locator_sha256,p.selected_content_sha256,p.classification,p.rights_binding_kind,p.rights_asset_id,
          p.rights_asset_revision,p.rights_asset_sha256,p.asset_rights_decision_id,p.asset_rights_decision_version,
          p.asset_rights_decision_sha256,p.rights_effective_at,p.rights_expires_at,p.access_right,p.private_storage_right,
          p.model_egress_right,p.model_use_right,p.derivative_creation_right,p.excerpt_right,p.redistribution_right,
          p.commercial_use_right,p.public_display_right,p.rights_policy_version,p.rights_policy_sha256,
          $3,$4,p.new_occurred_at,
          ops.canonical_jsonb_v1(p.payload || jsonb_build_object('sourceUseSha256',p.digest)),p.digest
        FROM payloads p
        ON CONFLICT (agent_run_id,source_use_sha256) DO NOTHING
        "#,
    )
    .bind(turn.run_id)
    .bind(turn.turn_id)
    .bind(bound_receipt_id)
    .bind(&bound_receipt_sha256)
    .bind(output_sha256)
    .execute(&mut *executor)
    .await
    .map_err(database)?;
    Ok(())
}

async fn insert_citation_source_uses(
    executor: &mut sqlx::PgConnection,
    turn: &ProviderTurnIdentity,
    output: &Value,
) -> Result<(), Failure> {
    let citations = output
        .get("citations")
        .cloned()
        .unwrap_or_else(|| json!([]));
    let citation_count = citations.as_array().map_or(0, Vec::len);
    if citation_count == 0 {
        return Ok(());
    }
    let unmatched: bool = sqlx::query_scalar!(
        r#"
        SELECT EXISTS (
          SELECT 1
            FROM jsonb_array_elements($3::jsonb) AS requested(value)
           WHERE NOT EXISTS (
             SELECT 1
               FROM ops.agent_source_uses model_input
              WHERE model_input.agent_run_id=$1
                AND (
                  (model_input.provider_turn_id=$2
                   AND model_input.use_kind='MODEL_INPUT'
                   AND model_input.source_kind='EVIDENCE_SEGMENT')
                  OR (model_input.use_kind='TOOL_QUERY'
                      AND model_input.source_kind='RESEARCH_ARTIFACT'
                      AND model_input.provider_turn_id=$2
                      AND model_input.classification='RESTRICTED'
                      AND EXISTS (
                        SELECT 1 FROM ops.agent_tool_calls tool
                         WHERE tool.agent_run_id=model_input.agent_run_id
                           AND tool.tool_call_id=model_input.tool_call_id
                           AND tool.tool_id='source.fetch'
                           AND tool.status='SUCCEEDED'
                           AND tool.result_transcript_sha256=CAST($4 AS char(64))
                      )
                      AND EXISTS (
                        SELECT 1 FROM raw.research_artifact_review_tiers tier
                         WHERE tier.research_artifact_id=model_input.research_artifact_id
                           AND tier.research_asset_id=model_input.research_asset_id
                           AND tier.research_asset_revision=model_input.research_asset_revision
                           AND tier.research_artifact_sha256=model_input.research_artifact_sha256
                           AND tier.research_content_sha256=model_input.research_content_sha256
                           AND tier.review_tier='OFFICIAL_UNREVIEWED'
                           AND tier.reviewed_classification='RESTRICTED'
                           AND tier.revision=(
                             SELECT max(latest.revision)
                               FROM raw.research_artifact_review_tiers latest
                              WHERE latest.research_artifact_id=model_input.research_artifact_id
                           )
                      ))
                )
                AND (
                  model_input.source_use_sha256=CAST(requested.value->>'sourceUseSha256' AS char(64))
                  OR model_input.parent_source_use_sha256=CAST(requested.value->>'sourceUseSha256' AS char(64))
                )
                AND model_input.locator_value=requested.value->'locator'->>'value'
                AND model_input.selected_content_sha256=CAST(requested.value->>'selectedContentSha256' AS char(64))
           )
        )
        "#,
        turn.run_id,
        turn.turn_id,
        &citations,
        &turn.prior_transcript_sha256,
    )
    .fetch_one(&mut *executor)
    .await
    .map_err(database)?
    .ok_or_else(|| database(sqlx::Error::Decode(Box::new(sqlx::error::UnexpectedNullError))))?;
    if unmatched {
        return Err(Failure::Terminal(
            "AGENT_OUTPUT_INVALID",
            "citation source-use binding".into(),
        ));
    }
    sqlx::query!(
        r#"
        WITH requested AS (
          SELECT value, ordinality::int - 1 AS citation_ordinal
            FROM jsonb_array_elements($3::jsonb) WITH ORDINALITY
        ), parents AS (
          SELECT mi.*, r.value, r.citation_ordinal
            FROM requested r
            JOIN ops.agent_source_uses mi
             ON mi.agent_run_id=$1
             AND (
               (mi.provider_turn_id=$2 AND mi.use_kind='MODEL_INPUT'
                AND mi.source_kind='EVIDENCE_SEGMENT')
               OR (mi.use_kind='TOOL_QUERY'
                   AND mi.source_kind='RESEARCH_ARTIFACT'
                   AND mi.provider_turn_id=$2
                   AND mi.classification='RESTRICTED'
                   AND EXISTS (
                     SELECT 1 FROM ops.agent_tool_calls tool
                      WHERE tool.agent_run_id=mi.agent_run_id
                        AND tool.tool_call_id=mi.tool_call_id
                        AND tool.tool_id='source.fetch'
                        AND tool.status='SUCCEEDED'
                        AND tool.result_transcript_sha256=CAST($4 AS char(64))
                   )
                   AND EXISTS (
                     SELECT 1 FROM raw.research_artifact_review_tiers tier
                      WHERE tier.research_artifact_id=mi.research_artifact_id
                        AND tier.research_asset_id=mi.research_asset_id
                        AND tier.research_asset_revision=mi.research_asset_revision
                        AND tier.research_artifact_sha256=mi.research_artifact_sha256
                        AND tier.research_content_sha256=mi.research_content_sha256
                        AND tier.review_tier='OFFICIAL_UNREVIEWED'
                        AND tier.reviewed_classification='RESTRICTED'
                        AND tier.revision=(
                          SELECT max(latest.revision)
                            FROM raw.research_artifact_review_tiers latest
                           WHERE latest.research_artifact_id=mi.research_artifact_id
                        )
                   ))
             )
             AND (
               mi.source_use_sha256=CAST(r.value->>'sourceUseSha256' AS char(64))
               OR mi.parent_source_use_sha256=CAST(r.value->>'sourceUseSha256' AS char(64))
             )
             AND mi.locator_value=r.value->'locator'->>'value'
             AND mi.selected_content_sha256=CAST(r.value->>'selectedContentSha256' AS char(64))
        ), pending AS (
          SELECT p.*
            FROM parents p
           WHERE NOT EXISTS (
             SELECT 1
               FROM ops.agent_source_uses existing
              WHERE existing.agent_run_id=p.agent_run_id
                AND existing.provider_turn_id=$2::uuid
                AND existing.use_kind='CITATION'
                AND existing.parent_source_use_id=p.source_use_id
                AND existing.parent_source_use_sha256=p.source_use_sha256
           )
        ), identities AS (
          SELECT p.*, gen_random_uuid() AS new_source_use_id,
                 clock_timestamp() AS new_occurred_at
            FROM pending p
        ), unsigned AS (
          SELECT i.*, jsonb_build_object(
            'schemaVersion','source-use.v2','sourceUseId',i.new_source_use_id,
            'agentRunId',i.agent_run_id,'providerTurnId',$2::uuid,
            'toolCallId',NULL,
            'parentSourceUseId',i.source_use_id,
            'parentSourceUseSha256',btrim(i.source_use_sha256::text),
            'useKind','CITATION','sourceKind',i.source_kind,
            'sourceIdentity',CASE i.source_kind
              WHEN 'EVIDENCE_SEGMENT' THEN jsonb_build_object(
                'kind','EVIDENCE_SEGMENT','datasetSnapshotId',i.dataset_snapshot_id,
                'snapshotMemberId',i.snapshot_member_id,
                'snapshotMemberDigest',btrim(i.snapshot_member_digest::text),
                'evidenceSegmentId',i.evidence_segment_id,
                'sourceDocumentId',i.source_document_id,
                'sourceAssetId',i.source_asset_id,
                'sourceAssetRevision',i.source_asset_revision,
                'sourceContentSha256',btrim(i.source_content_sha256::text))
              WHEN 'RESEARCH_ARTIFACT' THEN jsonb_build_object(
                'kind','RESEARCH_ARTIFACT','researchArtifactId',i.research_artifact_id,
                'assetId',i.research_asset_id,'assetRevision',i.research_asset_revision,
                'artifactSha256',btrim(i.research_artifact_sha256::text),
                'contentSha256',btrim(i.research_content_sha256::text),
                'sourceFetchId',i.research_source_fetch_id)
              ELSE NULL
            END,
            'selectedContentSha256',btrim(i.selected_content_sha256::text),
            'locator',jsonb_build_object('kind',i.locator_kind,'value',i.locator_value,'locatorSha256',btrim(i.locator_sha256::text)),
            'classification',i.classification,
            'rightsDecision',jsonb_build_object(
              'decisionId',i.asset_rights_decision_id,
              'decisionVersion',i.asset_rights_decision_version,
              'decisionSha256',btrim(i.asset_rights_decision_sha256::text),
              'effectiveAt',i.rights_effective_at,'expiresAt',i.rights_expires_at,
              'accessRight',i.access_right,
              'privateStorageRight',i.private_storage_right,
              'modelEgressRight',i.model_egress_right,
              'modelUseRight',i.model_use_right,
              'derivativeCreationRight',i.derivative_creation_right,
              'excerptRight',i.excerpt_right,
              'redistributionRight',i.redistribution_right,
              'commercialUseRight',i.commercial_use_right,
              'publicDisplayRight',i.public_display_right),
            'providerReceiptId',NULL,'occurredAt',i.new_occurred_at
          ) AS payload
          FROM identities i
        ), payloads AS (
          SELECT u.*, encode(extensions.digest(ops.canonical_jsonb_v1(u.payload),'sha256'),'hex') AS digest
            FROM unsigned u
        )
        INSERT INTO ops.agent_source_uses(
          source_use_id,source_use_contract_version,agent_run_id,provider_turn_id,parent_source_use_id,parent_source_use_sha256,
          use_kind,source_kind,dataset_snapshot_id,snapshot_member_id,snapshot_member_digest,
          snapshot_member_source_id,snapshot_member_source_digest,member_source_kind,object_type,object_id,
          object_version,object_content_sha256,evidence_segment_id,source_document_id,source_asset_id,
          source_asset_revision,source_content_sha256,locator_kind,locator_value,locator_sha256,
          research_artifact_id,research_asset_id,research_asset_revision,research_artifact_sha256,
          research_content_sha256,research_source_fetch_id,
          selected_content_sha256,classification,rights_binding_kind,rights_asset_id,rights_asset_revision,
          rights_asset_sha256,asset_rights_decision_id,asset_rights_decision_version,asset_rights_decision_sha256,
          rights_effective_at,rights_expires_at,access_right,private_storage_right,model_egress_right,
          model_use_right,derivative_creation_right,excerpt_right,redistribution_right,commercial_use_right,
          public_display_right,rights_policy_version,rights_policy_sha256,occurred_at,source_use_canonical,source_use_sha256)
        SELECT p.new_source_use_id,2,p.agent_run_id,$2::uuid,p.source_use_id,p.source_use_sha256,
          'CITATION',p.source_kind,p.dataset_snapshot_id,p.snapshot_member_id,p.snapshot_member_digest,
          p.snapshot_member_source_id,p.snapshot_member_source_digest,p.member_source_kind,p.object_type,p.object_id,
          p.object_version,p.object_content_sha256,p.evidence_segment_id,p.source_document_id,p.source_asset_id,
          p.source_asset_revision,p.source_content_sha256,p.locator_kind,p.locator_value,p.locator_sha256,
          p.research_artifact_id,p.research_asset_id,p.research_asset_revision,p.research_artifact_sha256,
          p.research_content_sha256,p.research_source_fetch_id,
          p.selected_content_sha256,p.classification,p.rights_binding_kind,p.rights_asset_id,p.rights_asset_revision,
          p.rights_asset_sha256,p.asset_rights_decision_id,p.asset_rights_decision_version,p.asset_rights_decision_sha256,
          p.rights_effective_at,p.rights_expires_at,p.access_right,p.private_storage_right,p.model_egress_right,
          p.model_use_right,p.derivative_creation_right,p.excerpt_right,p.redistribution_right,p.commercial_use_right,
          p.public_display_right,p.rights_policy_version,p.rights_policy_sha256,p.new_occurred_at,
          ops.canonical_jsonb_v1(p.payload || jsonb_build_object('sourceUseSha256',p.digest)),p.digest
        FROM payloads p
        ON CONFLICT (agent_run_id,source_use_sha256) DO NOTHING
        "#,
        turn.run_id,
        turn.turn_id,
        citations,
        &turn.prior_transcript_sha256,
    )
    .execute(&mut *executor)
    .await
    .map_err(database)?;
    Ok(())
}
