async fn ensure_agent_source_use_roots(
    pool: &PgPool,
    run_id: Uuid,
    evidence_ids: &[Uuid],
) -> Result<(), Failure> {
    // The worker may materialize the initial TOOL_QUERY receipt when a
    // snapshot producer has not done so yet, but it must do that from the
    // immutable READY AGENT_CASE graph.  In particular, never synthesize a
    // segment/member identity from an editorial evidence row: every value in
    // the inserted row is selected from the FK target relation below.
    sqlx::query(
        r#"
        WITH snapshot_choice AS (
          SELECT ds.id AS dataset_snapshot_id,
                 ds.snapshot_kind,
                 ds.producer_generation,
                 ds.contract_version
            FROM core.dataset_snapshots ds
            JOIN core.dataset_snapshot_members m
              ON m.dataset_snapshot_id = ds.id
             AND m.snapshot_kind = ds.snapshot_kind
             AND m.producer_generation = ds.producer_generation
             AND m.snapshot_contract_version = ds.contract_version
             AND m.object_type IN ('AGENCY','SUPPLIER','CONTRACT','CONTRACT_LINE_ITEM','CONTRACT_CHANGE','PRICE_OBSERVATION')
            JOIN core.dataset_snapshot_member_sources ms
              ON ms.dataset_snapshot_id = m.dataset_snapshot_id
             AND ms.snapshot_member_id = m.id
             AND ms.snapshot_member_digest = m.member_digest
            JOIN editorial.evidence e
              ON e.source_document_id = ms.source_document_id
             AND e.id = ANY($2::uuid[])
           WHERE ds.snapshot_kind = 'AGENT_CASE'
             AND ds.state = 'READY'
             AND e.verification_status = 'VERIFIED'
           GROUP BY ds.id, ds.snapshot_kind, ds.producer_generation,
                    ds.contract_version, ds.ready_at
          HAVING count(DISTINCT e.id) = cardinality($2::uuid[])
           ORDER BY ds.ready_at DESC NULLS LAST, ds.id
           LIMIT 1
        ), candidates AS (
          SELECT DISTINCT ON (e.id)
                 sc.dataset_snapshot_id,
                 sc.snapshot_kind,
                 sc.producer_generation,
                 sc.contract_version,
                 m.id AS snapshot_member_id,
                 m.member_digest AS snapshot_member_digest,
                 m.object_type,
                 m.object_id,
                 m.object_version,
                 m.object_content_sha256,
                 ms.id AS snapshot_member_source_id,
                 ms.source_digest AS snapshot_member_source_digest,
                 ms.source_kind AS member_source_kind,
                 ms.source_document_id,
                 ms.source_asset_id,
                 ms.source_asset_revision,
                 ms.source_content_sha256,
                 seg.locator_kind,
                 seg.locator_value,
                 seg.locator_digest,
                 seg.selected_content_sha256,
                 e.classification,
                 r.id AS rights_decision_id,
                 r.decision_version AS rights_decision_version,
                 r.decision_sha256 AS rights_decision_sha256,
                 r.effective_at AS rights_effective_at,
                 r.expires_at AS rights_expires_at,
                 r.access_right,
                 r.private_storage_right,
                 r.model_egress_right,
                 r.model_use_right,
                 r.derivative_creation_right,
                 r.excerpt_right,
                 r.redistribution_right,
                 r.commercial_use_right,
                 r.public_display_right,
                 r.policy_version AS rights_policy_version,
                 r.policy_sha256 AS rights_policy_sha256
            FROM snapshot_choice sc
            JOIN core.dataset_snapshot_members m
              ON m.dataset_snapshot_id = sc.dataset_snapshot_id
             AND m.snapshot_kind = sc.snapshot_kind
             AND m.producer_generation = sc.producer_generation
             AND m.snapshot_contract_version = sc.contract_version
             AND m.object_type IN ('AGENCY','SUPPLIER','CONTRACT','CONTRACT_LINE_ITEM','CONTRACT_CHANGE','PRICE_OBSERVATION')
            JOIN core.dataset_snapshot_member_sources ms
              ON ms.dataset_snapshot_id = m.dataset_snapshot_id
             AND ms.snapshot_member_id = m.id
             AND ms.snapshot_member_digest = m.member_digest
            JOIN editorial.evidence e
              ON e.source_document_id = ms.source_document_id
             AND e.id = ANY($2::uuid[])
             AND e.verification_status = 'VERIFIED'
            JOIN core.dataset_snapshot_members em
              ON em.dataset_snapshot_id = sc.dataset_snapshot_id
             AND em.snapshot_kind = sc.snapshot_kind
             AND em.producer_generation = sc.producer_generation
             AND em.snapshot_contract_version = sc.contract_version
             AND em.snapshot_kind = 'AGENT_CASE'
             AND em.object_type = 'EVIDENCE_SEGMENT'
             AND em.object_id = e.id
             AND em.object_version = 1
             AND em.evidence_segment_id = e.id
            JOIN raw.evidence_segments seg
              ON seg.id = em.evidence_segment_id
             AND seg.source_document_id = ms.source_document_id
             AND seg.source_asset_id = ms.source_asset_id
             AND seg.source_asset_revision = ms.source_asset_revision
             AND seg.source_content_sha256 = ms.source_content_sha256
            JOIN raw.asset_rights_decisions r
              ON r.asset_id = ms.source_asset_id
             AND r.asset_revision = ms.source_asset_revision
             AND r.asset_sha256 = ms.source_content_sha256
             AND r.source_document_id = ms.source_document_id
             AND r.effective_at <= clock_timestamp()
             AND (r.expires_at IS NULL OR r.expires_at > clock_timestamp())
             AND r.access_right = 'ALLOW'
             AND r.private_storage_right = 'ALLOW'
             AND r.model_egress_right = 'ALLOW'
             AND r.model_use_right = 'ALLOW'
             AND r.derivative_creation_right = 'ALLOW'
            ORDER BY e.id, m.member_ordinal, r.decision_version DESC, r.id DESC
        ), identities AS (
          SELECT c.*, gen_random_uuid() AS source_use_id, clock_timestamp() AS occurred_at
            FROM candidates c
        ), unsigned_payloads AS (
          SELECT i.*,
                 jsonb_build_object(
                   'schemaVersion','source-use.v2',
                   'sourceUseId',i.source_use_id,
                   'agentRunId',$1,
                   'providerTurnId',NULL,
                   'toolCallId',NULL,
                   'parentSourceUseId',NULL,
                   'parentSourceUseSha256',NULL,
                   'useKind','TOOL_QUERY',
                   'sourceKind','DATASET_MEMBER',
                   'sourceIdentity',jsonb_build_object(
                     'kind','DATASET_MEMBER',
                     'datasetSnapshotId',i.dataset_snapshot_id,
                     'snapshotMemberId',i.snapshot_member_id,
                     'snapshotMemberDigest',btrim(i.snapshot_member_digest::text),
                     'objectType',i.object_type,
                     'objectId',i.object_id,
                     'objectVersion',i.object_version,
                     'objectContentSha256',btrim(i.object_content_sha256::text)),
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
                   'providerReceiptId',NULL,
                   'occurredAt',i.occurred_at
                 ) AS unsigned_canonical
            FROM identities i
        ), payloads AS (
          SELECT u.*,
                 encode(extensions.digest(ops.canonical_jsonb_v1(u.unsigned_canonical),'sha256'),'hex') AS source_use_sha256
            FROM unsigned_payloads u
        )
        INSERT INTO ops.agent_source_uses(
          source_use_id,source_use_contract_version,agent_run_id,
          use_kind,source_kind,dataset_snapshot_id,snapshot_member_id,
          snapshot_member_digest,snapshot_member_source_id,
          snapshot_member_source_digest,member_source_kind,object_type,
          object_id,object_version,object_content_sha256,source_document_id,
          source_asset_id,source_asset_revision,source_content_sha256,
          locator_kind,locator_value,locator_sha256,selected_content_sha256,
          classification,rights_binding_kind,rights_asset_id,
          rights_asset_revision,rights_asset_sha256,asset_rights_decision_id,
          asset_rights_decision_version,asset_rights_decision_sha256,
          rights_effective_at,rights_expires_at,access_right,private_storage_right,
          model_egress_right,model_use_right,derivative_creation_right,
          excerpt_right,redistribution_right,commercial_use_right,public_display_right,
          rights_policy_version,rights_policy_sha256,occurred_at,
          source_use_canonical,source_use_sha256)
        SELECT p.source_use_id,2,$1,'TOOL_QUERY','DATASET_MEMBER',
               p.dataset_snapshot_id,p.snapshot_member_id,p.snapshot_member_digest,
               p.snapshot_member_source_id,p.snapshot_member_source_digest,
               p.member_source_kind,p.object_type,p.object_id,p.object_version,
               p.object_content_sha256,p.source_document_id,p.source_asset_id,
               p.source_asset_revision,p.source_content_sha256,p.locator_kind,
               p.locator_value,p.locator_digest,p.selected_content_sha256,p.classification,
               'ASSET_RIGHTS',p.source_asset_id,p.source_asset_revision,
               p.source_content_sha256,p.rights_decision_id,p.rights_decision_version,
               p.rights_decision_sha256,p.rights_effective_at,p.rights_expires_at,
               p.access_right,p.private_storage_right,p.model_egress_right,
               p.model_use_right,p.derivative_creation_right,p.excerpt_right,
               p.redistribution_right,p.commercial_use_right,p.public_display_right,
               p.rights_policy_version,p.rights_policy_sha256,p.occurred_at,
               ops.canonical_jsonb_v1(p.unsigned_canonical || jsonb_build_object('sourceUseSha256',p.source_use_sha256)),
               p.source_use_sha256
          FROM payloads p
        ON CONFLICT (agent_run_id,source_use_sha256) DO NOTHING
        "#,
    )
    .bind(run_id)
    .bind(evidence_ids)
    .execute(pool)
    .await
    .map_err(database)?;

    let exists: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM ops.agent_source_uses WHERE agent_run_id=$1 AND use_kind='TOOL_QUERY' AND source_kind='DATASET_MEMBER')",
    )
    .bind(run_id)
    .fetch_one(pool)
    .await
    .map_err(database)?;
    if !exists {
        return Err(Failure::Terminal("AGENT_SOURCE_USE_MISSING", run_id.to_string()));
    }
    Ok(())
}
type AgentInputBundle = (Vec<String>, serde_json::Map<String, Value>, Value, Value);
