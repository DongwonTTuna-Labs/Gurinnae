-- TEST_FIXTURE_ONLY: R6c accepted-hypothesis recursion runtime proof.
--
-- This phased fixture is consumed only by the disposable PostgreSQL instance
-- owned by scripts/test-event-consumers-runtime.sh.  It never seeds an
-- operational recursion policy.  Every policy row added by later phases is
-- explicitly test-only and immutable.  The recursion graph itself is created
-- only through the production owner routines; this file must never insert
-- directly into hypothesis_recursion_plans, nodes, transitions, receipts, or
-- budget_ledger.

\if :{?r6c_recursion_phase}
\else
\echo 'r6c_recursion_phase is required'
\quit 1
\endif

SELECT
  :'r6c_recursion_phase' = 'setup' AS r6c_recursion_setup,
  :'r6c_recursion_phase' IN (
    'approve_absent', 'approve_disabled', 'approve_case_budget',
    'approve_max_depth', 'approve_happy', 'approve_stale_case'
  ) AS r6c_recursion_approve,
  :'r6c_recursion_phase' IN (
    'policy_disabled', 'policy_case_budget',
    'policy_max_depth', 'policy_happy'
  ) AS r6c_recursion_policy,
  :'r6c_recursion_phase' IN (
    'verify_absent', 'verify_disabled', 'verify_case_budget',
    'verify_max_depth_root', 'verify_max_depth',
    'verify_exact_redelivery', 'verify_happy_root', 'verify_happy',
    'verify_stale_case_version', 'final_verify'
  ) AS r6c_recursion_verify,
  :'r6c_recursion_phase' IN (
    'complete_market_max_depth', 'complete_market_happy',
    'complete_skeptic_happy'
  ) AS r6c_recursion_complete_stage,
  :'r6c_recursion_phase' = 'prepare_exact_redelivery'
    AS r6c_recursion_prepare_redelivery,
  :'r6c_recursion_phase' = ANY(ARRAY[
    'setup', 'approve_absent', 'approve_disabled',
    'approve_case_budget', 'approve_max_depth', 'approve_happy',
    'approve_stale_case',
    'policy_disabled', 'policy_case_budget', 'policy_max_depth',
    'policy_happy', 'verify_absent', 'verify_disabled',
    'verify_case_budget', 'verify_max_depth_root',
    'complete_market_max_depth', 'verify_max_depth',
    'prepare_exact_redelivery', 'verify_exact_redelivery',
    'verify_happy_root', 'complete_market_happy',
    'complete_skeptic_happy', 'verify_happy',
    'verify_stale_case_version', 'final_verify'
  ]) AS r6c_recursion_phase_known
\gset

\if :r6c_recursion_phase_known
\else
\echo 'unknown r6c_recursion_phase'
\quit 1
\endif

\if :r6c_recursion_setup
BEGIN;
SET LOCAL TIME ZONE 'UTC';
SELECT set_config(
  'r6c.fixture.phase', :'r6c_recursion_phase', true
);

-- The proposer and reviewer are distinct real users.  The reviewer carries
-- the production EXECUTIVE_APPROVER role selected by the HYPOTHESIS review
-- owner; no fixture-only role or capability is invented.
INSERT INTO ops.users(
  id, oidc_subject, email, display_name, status
) VALUES
(
  '00000000-0000-4000-8000-000000000317',
  'r6c-recursion-proposer', 'r6c-recursion-proposer@example.test',
  'R6c recursion proposer', 'ACTIVE'
),
(
  '00000000-0000-4000-8000-000000000316',
  'r6c-recursion-reviewer', 'r6c-recursion-reviewer@example.test',
  'R6c recursion reviewer', 'ACTIVE'
);

INSERT INTO ops.user_roles(
  id, user_id, role_id, granted_by, reason, granted_at
)
SELECT fixture.id, fixture.user_id, role.id,
       '00000000-0000-4000-8000-000000000317',
       'TEST_FIXTURE_ONLY recursion approval role binding',
       '2026-08-01T03:00:00Z'
FROM (VALUES
  (
    '31600000-0000-4000-8000-000000000090'::uuid,
    '00000000-0000-4000-8000-000000000317'::uuid,
    'INVESTIGATOR'::text
  ),
  (
    '31600000-0000-4000-8000-000000000091'::uuid,
    '00000000-0000-4000-8000-000000000316'::uuid,
    'EXECUTIVE_APPROVER'::text
  )
) AS fixture(id, user_id, role_code)
JOIN ops.roles AS role ON role.code = fixture.role_code;

INSERT INTO ops.sessions(
  id, user_id, session_token_hash, auth_time, step_up_at,
  expires_at, csrf_token_hash
) VALUES (
  '31600000-0000-4000-8000-000000000092',
  '00000000-0000-4000-8000-000000000316', repeat('9', 64),
  clock_timestamp(), clock_timestamp(), '2099-01-01T00:00:00Z',
  repeat('8', 64)
);

-- The evidence segment is a deterministic, public, non-personal fixture.  It
-- reuses the source document, parser run, and rights decision already created
-- by the R6b2 runtime setup; no external request or synthetic rights grant is
-- introduced here.
DO $$
DECLARE
  v_evidence_id constant uuid :=
    '31600000-0000-4000-8000-000000000001';
  v_selected_text constant text :=
    'TEST_FIXTURE_ONLY 재귀 조사 가설의 공개 근거';
  v_locator constant text := '/contracts/0/recursion-evidence';
  v_selected_sha char(64);
  v_locator_sha char(64);
  v_segment_payload jsonb;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM raw.source_documents AS document
    JOIN core.parser_runs AS parser
      ON parser.id = '31300000-0000-4000-8000-000000000903'
     AND parser.source_document_id = document.id
     AND parser.status = 'SUCCEEDED'
    JOIN raw.asset_rights_decisions AS rights
      ON rights.id = '31300000-0000-4000-8000-000000000002'
     AND rights.asset_id = document.asset_id
     AND rights.asset_revision = document.asset_revision
     AND rights.asset_sha256 = document.content_sha256
     AND rights.access_right = 'ALLOW'
     AND rights.model_use_right = 'ALLOW'
    WHERE document.id = '31300000-0000-4000-8000-000000000001'
      AND document.asset_id = '31300000-0000-4000-8000-000000000001'
      AND document.asset_revision = 1
      AND document.content_sha256 = repeat('1', 64)
  ) THEN
    RAISE EXCEPTION 'R6c recursion source authority missing';
  END IF;

  v_selected_sha := encode(extensions.digest(
    convert_to(v_selected_text, 'UTF8'), 'sha256'
  ), 'hex');
  v_locator_sha := encode(extensions.digest(
    convert_to(v_locator, 'UTF8'), 'sha256'
  ), 'hex');
  v_segment_payload := jsonb_build_object(
    'schemaVersion', 'r6c-recursion-evidence-segment.v1',
    'evidenceSegmentId', v_evidence_id,
    'sourceDocumentId',
      '31300000-0000-4000-8000-000000000001'::uuid,
    'parserRunId', '31300000-0000-4000-8000-000000000903'::uuid,
    'locatorKind', 'JSON_POINTER',
    'locatorValue', v_locator,
    'locatorSha256', btrim(v_locator_sha),
    'selectedContentSha256', btrim(v_selected_sha),
    'classification', 'PUBLIC',
    'fixtureAuthority', 'TEST_FIXTURE_ONLY'
  );
  INSERT INTO raw.evidence_segments(
    id, source_document_id, source_asset_id, source_asset_revision,
    source_content_sha256, parser_run_id, parser_name, parser_version,
    segment_ordinal, locator_kind, locator_value, locator_digest,
    raw_value_sha256, selected_content_sha256,
    selected_content_object_key, selected_content_locator,
    selected_content_media_type, transformation_version, confidence,
    classification, source_authority, retrieved_at, segment_digest
  ) VALUES (
    v_evidence_id,
    '31300000-0000-4000-8000-000000000001',
    '31300000-0000-4000-8000-000000000001', 1, repeat('1', 64),
    '31300000-0000-4000-8000-000000000903',
    'connector-structured-json', 'connector-structured-json-v1', 0,
    'JSON_POINTER', v_locator, v_locator_sha, v_selected_sha,
    v_selected_sha, 'raw/r6c-recursion-evidence.json', v_locator,
    'application/json', 'r6c-recursion-fixture-v1', 1.0,
    'PUBLIC', 'TEST_FIXTURE_ONLY', '2026-08-01T03:00:00Z',
    encode(extensions.digest(
      ops.canonical_jsonb_v1(v_segment_payload), 'sha256'
    ), 'hex')
  );
END $$;

-- Build one snapshot-authoritative AGENT_CASE input through the production
-- begin/finalize primitives.  CONTRACT is the query root and
-- EVIDENCE_SEGMENT is the immutable citation source.
DO $$
DECLARE
  v_snapshot_job_id constant uuid :=
    '31600000-0000-4000-8000-000000000002';
  v_snapshot_id constant uuid :=
    '31600000-0000-4000-8000-000000000003';
  v_contract_member_id constant uuid :=
    '31600000-0000-4000-8000-000000000004';
  v_contract_source_id constant uuid :=
    '31600000-0000-4000-8000-000000000005';
  v_evidence_member_id constant uuid :=
    '31600000-0000-4000-8000-000000000006';
  v_evidence_source_id constant uuid :=
    '31600000-0000-4000-8000-000000000007';
  v_selection jsonb := jsonb_build_object(
    'fixtureAuthority', 'TEST_FIXTURE_ONLY',
    'purpose', 'accepted hypothesis recursion runtime proof'
  );
  v_watermarks jsonb := jsonb_build_object(
    'sourceDocumentId',
      '31300000-0000-4000-8000-000000000001'::uuid,
    'contractId', '31300000-0000-4000-8000-000000000012'::uuid
  );
  v_normalization jsonb := jsonb_build_object(
    'normalizationRunId',
      '31300000-0000-4000-8000-000000000905'::uuid,
    'parserRunId', '31300000-0000-4000-8000-000000000903'::uuid
  );
  v_producer_digest char(64);
  v_build_digest char(64);
  v_build_audit uuid;
  v_snapshot record;
  v_contract_payload jsonb;
  v_contract_payload_canonical bytea;
  v_contract_payload_sha char(64);
  v_contract_source_canonical bytea;
  v_contract_source_digest char(64);
  v_contract_source_set_digest char(64);
  v_contract_binding bytea;
  v_contract_member_digest char(64);
  v_evidence_payload jsonb;
  v_evidence_payload_canonical bytea;
  v_evidence_content_sha char(64);
  v_evidence_payload_sha char(64);
  v_evidence_source_canonical bytea;
  v_evidence_source_digest char(64);
  v_evidence_source_set_digest char(64);
  v_evidence_binding bytea;
  v_evidence_member_digest char(64);
  v_member_set char(64);
  v_manifest jsonb;
  v_manifest_canonical bytea;
  v_terminal_payload jsonb;
  v_terminal_receipt char(64);
  v_terminal_audit uuid;
  v_final record;
BEGIN
  v_producer_digest := encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion', 'r6c-recursion-snapshot-producer.v1',
      'fixtureAuthority', 'TEST_FIXTURE_ONLY'
    )), 'sha256'
  ), 'hex');
  v_build_digest := encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'snapshotId', v_snapshot_id,
      'snapshotKind', 'AGENT_CASE',
      'producerJobId', v_snapshot_job_id,
      'producerKey', 'r6c-hypothesis-recursion-runtime',
      'producerDigest', btrim(v_producer_digest)
    )), 'sha256'
  ), 'hex');
  INSERT INTO ops.jobs(
    id, job_type, queue, status, payload, dedupe_key,
    lease_owner, lease_token, lease_expires_at, fencing_token,
    attempt_count
  ) VALUES (
    v_snapshot_job_id, 'SNAPSHOT_BUILD', 'analysis-worker', 'RUNNING',
    jsonb_build_object(
      'fixtureAuthority', 'TEST_FIXTURE_ONLY',
      'producerKey', 'r6c-hypothesis-recursion-runtime',
      'snapshotId', v_snapshot_id
    ), 'r6c-hypothesis-recursion-snapshot-runtime',
    'r6c-recursion-snapshot-runtime',
    '31600000-0000-4000-8000-000000000008',
    clock_timestamp() + interval '10 minutes', 1, 1
  );
  INSERT INTO ops.job_attempts(
    job_id, attempt, worker_id, fencing_token, started_at
  ) VALUES (
    v_snapshot_job_id, 1, 'r6c-recursion-snapshot-runtime', 1,
    clock_timestamp()
  );
  v_build_audit := ops.append_audit_event(
    'snapshot:' || v_snapshot_id::text,
    'SERVICE', 'analysis-worker', NULL,
    'DATASET_SNAPSHOT_BUILD_STARTED', 'DatasetSnapshot',
    v_snapshot_id::text, 'jobs.operate', 'SUCCESS',
    NULL, v_snapshot_job_id, jsonb_build_object(
      'snapshotId', v_snapshot_id,
      'snapshotKind', 'AGENT_CASE',
      'producerJobId', v_snapshot_job_id,
      'buildRequestSha256', btrim(v_build_digest),
      'fixtureAuthority', 'TEST_FIXTURE_ONLY'
    )
  );
  IF NOT EXISTS (
    SELECT 1 FROM ops.audit_events AS audit
    WHERE audit.id = v_build_audit
      AND audit.actor_type = 'SERVICE'
      AND audit.actor_id = 'analysis-worker'
      AND audit.action = 'DATASET_SNAPSHOT_BUILD_STARTED'
      AND audit.object_type = 'DatasetSnapshot'
      AND audit.object_id = v_snapshot_id::text
      AND audit.capability = 'jobs.operate'
      AND audit.outcome = 'SUCCESS'
      AND audit.request_id = v_snapshot_job_id
      AND audit.details->>'snapshotId' = v_snapshot_id::text
      AND audit.details->>'snapshotKind' = 'AGENT_CASE'
      AND audit.details->>'producerJobId' = v_snapshot_job_id::text
      AND audit.details->>'buildRequestSha256' = btrim(v_build_digest)
  ) THEN
    RAISE EXCEPTION 'R6c recursion build audit binding invalid';
  END IF;
  SELECT begun.* INTO STRICT v_snapshot
  FROM core.begin_dataset_snapshot(
    'AGENT_CASE', v_snapshot_job_id,
    'r6c-hypothesis-recursion-runtime', v_producer_digest,
    'dataset-snapshot.v1',
    v_selection, ops.canonical_jsonb_v1(v_selection),
    v_watermarks, ops.canonical_jsonb_v1(v_watermarks),
    v_normalization, ops.canonical_jsonb_v1(v_normalization),
    v_build_digest, v_build_audit
  ) AS begun;
  IF v_snapshot.snapshot_id IS DISTINCT FROM v_snapshot_id
     OR v_snapshot.reused OR v_snapshot.state <> 'BUILDING' THEN
    RAISE EXCEPTION 'R6c recursion snapshot begin was not fresh';
  END IF;

  SELECT jsonb_build_object(
    'schemaVersion', 'r6c-recursion-contract-member.v1',
    'contractId', contract.id,
    'contractVersion', contract.version,
    'sourceDocumentId', contract.source_document_id,
    'fixtureAuthority', 'TEST_FIXTURE_ONLY'
  ) INTO STRICT v_contract_payload
  FROM core.contracts AS contract
  WHERE contract.id = '31300000-0000-4000-8000-000000000012';
  v_contract_payload_canonical := ops.canonical_jsonb_v1(
    v_contract_payload
  );
  v_contract_payload_sha := encode(extensions.digest(
    v_contract_payload_canonical, 'sha256'
  ), 'hex');
  v_contract_source_canonical := ops.canonical_jsonb_v1(
    jsonb_build_object(
      'schemaVersion', 'dataset-snapshot-member-source.v1',
      'snapshotId', v_snapshot.snapshot_id,
      'snapshotMemberId', v_contract_member_id,
      'memberOrdinal', 0,
      'sourceOrdinal', 0,
      'lineageKind', 'DIRECT_SOURCE',
      'sourceKind', 'SOURCE_DOCUMENT',
      'sourceDocumentId',
        '31300000-0000-4000-8000-000000000001'::uuid,
      'sourceAssetId',
        '31300000-0000-4000-8000-000000000001'::uuid,
      'sourceAssetRevision', 1,
      'sourceContentSha256', repeat('1', 64)
    )
  );
  v_contract_source_digest := encode(extensions.digest(
    v_contract_source_canonical, 'sha256'
  ), 'hex');
  v_contract_source_set_digest := encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_array(
      btrim(v_contract_source_digest)
    )), 'sha256'
  ), 'hex');
  v_contract_binding := ops.canonical_jsonb_v1(jsonb_build_object(
    'schemaVersion', 'dataset-snapshot-member-binding.v1',
    'snapshotId', v_snapshot.snapshot_id,
    'snapshotMemberId', v_contract_member_id,
    'snapshotKind', 'AGENT_CASE',
    'producerGeneration', v_snapshot.producer_generation,
    'snapshotContractVersion', 1,
    'memberOrdinal', 0,
    'objectType', 'CONTRACT',
    'objectId', '31300000-0000-4000-8000-000000000012'::uuid,
    'objectVersion', 3,
    'objectSchemaVersion', 'r6c-recursion-contract-member.v1',
    'objectContentSha256', btrim(v_contract_payload_sha),
    'payloadSha256', btrim(v_contract_payload_sha),
    'normalizationRunId', NULL,
    'normalizationVersion', NULL,
    'normalizationSha256', NULL,
    'evidenceSegmentId', NULL,
    'responseId', NULL,
    'sourceCount', 1,
    'sourceSetSha256', btrim(v_contract_source_set_digest)
  ));
  v_contract_member_digest := encode(extensions.digest(
    v_contract_binding, 'sha256'
  ), 'hex');
  INSERT INTO core.dataset_snapshot_members(
    id, dataset_snapshot_id, snapshot_kind, producer_generation,
    snapshot_contract_version, member_ordinal, object_type, object_id,
    object_version, object_schema_version, object_content_sha256,
    canonical_payload, canonical_payload_bytes, payload_sha256,
    normalization_run_id, normalization_version, normalization_sha256,
    source_count, source_set_sha256, member_binding_canonical,
    member_digest
  ) VALUES (
    v_contract_member_id, v_snapshot.snapshot_id, 'AGENT_CASE',
    v_snapshot.producer_generation, 1, 0, 'CONTRACT',
    '31300000-0000-4000-8000-000000000012', 3,
    'r6c-recursion-contract-member.v1', v_contract_payload_sha,
    v_contract_payload, v_contract_payload_canonical,
    v_contract_payload_sha,
    NULL, NULL, NULL, 1,
    v_contract_source_set_digest, v_contract_binding,
    v_contract_member_digest
  );
  INSERT INTO core.dataset_snapshot_member_sources(
    id, dataset_snapshot_id, snapshot_member_id, member_ordinal,
    snapshot_member_digest, source_ordinal, lineage_kind, source_kind,
    source_document_id, source_asset_id, source_asset_revision,
    source_content_sha256, source_digest
  ) VALUES (
    v_contract_source_id, v_snapshot.snapshot_id, v_contract_member_id,
    0, v_contract_member_digest, 0, 'DIRECT_SOURCE', 'SOURCE_DOCUMENT',
    '31300000-0000-4000-8000-000000000001',
    '31300000-0000-4000-8000-000000000001', 1, repeat('1', 64),
    v_contract_source_digest
  );

  SELECT jsonb_build_object(
    'schemaVersion', 'r6c-recursion-evidence-member.v1',
    'evidenceSegmentId', segment.id,
    'locatorSha256', btrim(segment.locator_digest),
    'selectedContentSha256', btrim(segment.selected_content_sha256),
    'classification', segment.classification,
    'fixtureAuthority', 'TEST_FIXTURE_ONLY'
  ) INTO STRICT v_evidence_payload
  FROM raw.evidence_segments AS segment
  WHERE segment.id = '31600000-0000-4000-8000-000000000001';
  v_evidence_payload_canonical := ops.canonical_jsonb_v1(
    v_evidence_payload
  );
  v_evidence_content_sha := (
    SELECT selected_content_sha256
    FROM raw.evidence_segments
    WHERE id = '31600000-0000-4000-8000-000000000001'
  );
  v_evidence_payload_sha := encode(extensions.digest(
    v_evidence_payload_canonical, 'sha256'
  ), 'hex');
  v_evidence_source_canonical := ops.canonical_jsonb_v1(
    jsonb_build_object(
      'schemaVersion', 'dataset-snapshot-member-source.v1',
      'snapshotId', v_snapshot.snapshot_id,
      'snapshotMemberId', v_evidence_member_id,
      'memberOrdinal', 1,
      'sourceOrdinal', 0,
      'lineageKind', 'EVIDENCE_SEGMENT',
      'sourceKind', 'SOURCE_DOCUMENT',
      'sourceDocumentId',
        '31300000-0000-4000-8000-000000000001'::uuid,
      'sourceAssetId',
        '31300000-0000-4000-8000-000000000001'::uuid,
      'sourceAssetRevision', 1,
      'sourceContentSha256', repeat('1', 64),
      'parserRunId',
        '31300000-0000-4000-8000-000000000903'::uuid,
      'evidenceSegmentId',
        '31600000-0000-4000-8000-000000000001'::uuid,
      'locatorSha256', (
        SELECT btrim(locator_digest)
        FROM raw.evidence_segments
        WHERE id = '31600000-0000-4000-8000-000000000001'
      )
    )
  );
  v_evidence_source_digest := encode(extensions.digest(
    v_evidence_source_canonical, 'sha256'
  ), 'hex');
  v_evidence_source_set_digest := encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_array(
      btrim(v_evidence_source_digest)
    )), 'sha256'
  ), 'hex');
  v_evidence_binding := ops.canonical_jsonb_v1(jsonb_build_object(
    'schemaVersion', 'dataset-snapshot-member-binding.v1',
    'snapshotId', v_snapshot.snapshot_id,
    'snapshotMemberId', v_evidence_member_id,
    'snapshotKind', 'AGENT_CASE',
    'producerGeneration', v_snapshot.producer_generation,
    'snapshotContractVersion', 1,
    'memberOrdinal', 1,
    'objectType', 'EVIDENCE_SEGMENT',
    'objectId', '31600000-0000-4000-8000-000000000001'::uuid,
    'objectVersion', 1,
    'objectSchemaVersion', 'r6c-recursion-evidence-member.v1',
    'objectContentSha256', btrim(v_evidence_content_sha),
    'payloadSha256', btrim(v_evidence_payload_sha),
    'normalizationRunId', NULL,
    'normalizationVersion', NULL,
    'normalizationSha256', NULL,
    'evidenceSegmentId',
      '31600000-0000-4000-8000-000000000001'::uuid,
    'responseId', NULL,
    'sourceCount', 1,
    'sourceSetSha256', btrim(v_evidence_source_set_digest)
  ));
  v_evidence_member_digest := encode(extensions.digest(
    v_evidence_binding, 'sha256'
  ), 'hex');
  INSERT INTO core.dataset_snapshot_members(
    id, dataset_snapshot_id, snapshot_kind, producer_generation,
    snapshot_contract_version, member_ordinal, object_type, object_id,
    object_version, object_schema_version, object_content_sha256,
    canonical_payload, canonical_payload_bytes, payload_sha256,
    evidence_segment_id, source_count, source_set_sha256,
    member_binding_canonical, member_digest
  ) VALUES (
    v_evidence_member_id, v_snapshot.snapshot_id, 'AGENT_CASE',
    v_snapshot.producer_generation, 1, 1, 'EVIDENCE_SEGMENT',
    '31600000-0000-4000-8000-000000000001', 1,
    'r6c-recursion-evidence-member.v1', v_evidence_content_sha,
    v_evidence_payload, v_evidence_payload_canonical,
    v_evidence_payload_sha,
    '31600000-0000-4000-8000-000000000001', 1,
    v_evidence_source_set_digest, v_evidence_binding,
    v_evidence_member_digest
  );
  INSERT INTO core.dataset_snapshot_member_sources(
    id, dataset_snapshot_id, snapshot_member_id, member_ordinal,
    snapshot_member_digest, source_ordinal, lineage_kind, source_kind,
    source_document_id, source_asset_id, source_asset_revision,
    source_content_sha256, parser_run_id, evidence_segment_id,
    locator_digest, source_digest
  ) VALUES (
    v_evidence_source_id, v_snapshot.snapshot_id, v_evidence_member_id,
    1, v_evidence_member_digest, 0, 'EVIDENCE_SEGMENT',
    'SOURCE_DOCUMENT',
    '31300000-0000-4000-8000-000000000001',
    '31300000-0000-4000-8000-000000000001', 1, repeat('1', 64),
    '31300000-0000-4000-8000-000000000903',
    '31600000-0000-4000-8000-000000000001',
    (
      SELECT locator_digest FROM raw.evidence_segments
      WHERE id = '31600000-0000-4000-8000-000000000001'
    ), v_evidence_source_digest
  );

  SELECT encode(extensions.digest(ops.canonical_jsonb_v1(jsonb_agg(
    btrim(member.member_digest) ORDER BY member.member_ordinal
  )), 'sha256'), 'hex')
  INTO STRICT v_member_set
  FROM core.dataset_snapshot_members AS member
  WHERE member.dataset_snapshot_id = v_snapshot.snapshot_id;
  SELECT jsonb_build_object(
    'schemaVersion', 'dataset-snapshot-manifest.v1',
    'snapshotId', snapshot.id,
    'snapshotKind', snapshot.snapshot_kind,
    'producerDigest', btrim(snapshot.producer_digest),
    'producerGeneration', snapshot.producer_generation,
    'selectionSha256', btrim(snapshot.selection_sha256),
    'sourceWatermarkSha256', btrim(snapshot.source_watermark_sha256),
    'normalizationSetSha256', btrim(snapshot.normalization_set_sha256),
    'memberCount', 2,
    'memberSetSha256', btrim(v_member_set)
  ) INTO STRICT v_manifest
  FROM core.dataset_snapshots AS snapshot
  WHERE snapshot.id = v_snapshot.snapshot_id;
  v_manifest_canonical := ops.canonical_jsonb_v1(v_manifest);
  v_terminal_payload := jsonb_build_object(
    'schemaVersion', 'dataset-snapshot-terminal-receipt.v1',
    'snapshotId', v_snapshot.snapshot_id,
    'state', 'READY',
    'aggregateVersion', 2,
    'snapshotSha256', encode(
      extensions.digest(v_manifest_canonical, 'sha256'), 'hex'
    ),
    'memberCount', 2,
    'memberSetSha256', btrim(v_member_set),
    'fixtureAuthority', 'TEST_FIXTURE_ONLY'
  );
  v_terminal_receipt := encode(extensions.digest(
    ops.canonical_jsonb_v1(v_terminal_payload), 'sha256'
  ), 'hex');
  v_terminal_audit := ops.append_audit_event(
    'snapshot:' || v_snapshot.snapshot_id::text,
    'SERVICE', 'analysis-worker', NULL,
    'DATASET_SNAPSHOT_READY', 'DatasetSnapshot',
    v_snapshot.snapshot_id::text, 'jobs.operate', 'SUCCESS', NULL,
    v_snapshot_job_id, jsonb_build_object(
      'snapshotId', v_snapshot.snapshot_id,
      'state', 'READY',
      'terminalReceiptDigest', btrim(v_terminal_receipt),
      'fixtureAuthority', 'TEST_FIXTURE_ONLY'
    )
  );
  IF NOT EXISTS (
    SELECT 1 FROM ops.audit_events AS audit
    WHERE audit.id = v_terminal_audit
      AND audit.actor_type = 'SERVICE'
      AND audit.actor_id = 'analysis-worker'
      AND audit.action = 'DATASET_SNAPSHOT_READY'
      AND audit.object_type = 'DatasetSnapshot'
      AND audit.object_id = v_snapshot.snapshot_id::text
      AND audit.capability = 'jobs.operate'
      AND audit.outcome = 'SUCCESS'
      AND audit.request_id = v_snapshot_job_id
      AND audit.details->>'snapshotId' = v_snapshot.snapshot_id::text
      AND audit.details->>'state' = 'READY'
      AND audit.details->>'terminalReceiptDigest' =
            btrim(v_terminal_receipt)
  ) THEN
    RAISE EXCEPTION 'R6c recursion terminal audit binding invalid';
  END IF;
  SELECT finalized.* INTO STRICT v_final
  FROM core.finalize_dataset_snapshot(
    v_snapshot.snapshot_id, 1, 'READY', 2, v_member_set,
    v_manifest, v_manifest_canonical, v_terminal_receipt,
    v_terminal_audit, NULL, NULL
  ) AS finalized;
  IF v_final.snapshot_id IS DISTINCT FROM v_snapshot_id
     OR v_final.state <> 'READY' OR v_final.version <> 2
     OR btrim(v_final.snapshot_sha256) IS DISTINCT FROM encode(
          extensions.digest(v_manifest_canonical, 'sha256'), 'hex'
        )
     OR EXISTS (
       SELECT 1 FROM core.dataset_snapshot_members AS member
       WHERE member.dataset_snapshot_id = v_snapshot_id
         AND (
           member.canonical_payload_bytes IS DISTINCT FROM
             ops.canonical_jsonb_v1(member.canonical_payload)
           OR (
             member.object_type = 'CONTRACT'
             AND btrim(member.object_content_sha256) IS DISTINCT FROM
                   btrim(member.payload_sha256)
           )
           OR (
             member.object_type = 'CONTRACT'
             AND btrim(member.payload_sha256) IS DISTINCT FROM encode(
               extensions.digest(member.canonical_payload_bytes, 'sha256'),
               'hex'
             )
           )
           OR (
             member.object_type = 'EVIDENCE_SEGMENT'
             AND member.canonical_payload->>'selectedContentSha256'
                   IS DISTINCT FROM btrim(member.object_content_sha256)
           )
           OR (
             member.object_type = 'EVIDENCE_SEGMENT'
             AND btrim(member.payload_sha256) IS DISTINCT FROM encode(
               extensions.digest(member.canonical_payload_bytes, 'sha256'),
               'hex'
             )
           )
           OR btrim(member.member_digest) IS DISTINCT FROM encode(
             extensions.digest(member.member_binding_canonical, 'sha256'),
             'hex'
           )
         )
     )
     OR NOT EXISTS (
       SELECT 1 FROM core.dataset_snapshot_member_sources AS source
       WHERE source.id = v_contract_source_id
         AND source.snapshot_member_id = v_contract_member_id
         AND btrim(source.snapshot_member_digest) =
               btrim(v_contract_member_digest)
         AND btrim(source.source_digest) = btrim(v_contract_source_digest)
     )
     OR NOT EXISTS (
       SELECT 1 FROM core.dataset_snapshot_member_sources AS source
       WHERE source.id = v_evidence_source_id
         AND source.snapshot_member_id = v_evidence_member_id
         AND btrim(source.snapshot_member_digest) =
               btrim(v_evidence_member_digest)
         AND btrim(source.source_digest) = btrim(v_evidence_source_digest)
     ) THEN
    RAISE EXCEPTION 'R6c recursion snapshot finalization invalid';
  END IF;
  UPDATE ops.jobs
  SET status = 'SUCCEEDED', lease_owner = NULL, lease_token = NULL,
      lease_expires_at = NULL, updated_at = clock_timestamp()
  WHERE id = v_snapshot_job_id AND status = 'RUNNING';
  UPDATE ops.job_attempts
  SET outcome = 'SUCCEEDED', finished_at = clock_timestamp()
  WHERE job_id = v_snapshot_job_id AND attempt = 1
    AND outcome IS NULL;
END $$;

-- Start the authoritative investigator V2 run through the worker claim owner.
DO $$
DECLARE
  v_run_id constant uuid := '31600000-0000-4000-8000-000000000010';
  v_job_id constant uuid := '31600000-0000-4000-8000-000000000011';
  v_lease_token constant uuid :=
    '31600000-0000-4000-8000-000000000012';
  v_case_id uuid;
  v_snapshot_id uuid;
  v_snapshot_sha char(64);
  v_initial_transcript char(64);
BEGIN
  SELECT receipt.case_id INTO STRICT v_case_id
  FROM ops.signal_investigation_initiation_receipts AS receipt
  WHERE receipt.disposition = 'STARTED'
  ORDER BY receipt.created_at DESC, receipt.receipt_id DESC
  LIMIT 1;
  SELECT snapshot.id, snapshot.snapshot_sha256
  INTO STRICT v_snapshot_id, v_snapshot_sha
  FROM core.dataset_snapshots AS snapshot
  WHERE snapshot.producer_key = 'r6c-hypothesis-recursion-runtime'
    AND snapshot.snapshot_kind = 'AGENT_CASE'
    AND snapshot.state = 'READY';
  v_initial_transcript := encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion', 'agent-transcript.initial.v1',
      'runId', v_run_id,
      'caseId', v_case_id,
      'inputSnapshotSha256', btrim(v_snapshot_sha),
      'fixtureAuthority', 'TEST_FIXTURE_ONLY'
    )), 'sha256'
  ), 'hex');
  INSERT INTO ops.agent_runs(
    id, case_id, agent_type, objective, evidence_scope_ids,
    provider_policy, status, input_snapshot_hash, output_schema_version,
    max_cost, created_by, run_contract_version, dataset_snapshot_id,
    initial_transcript_sha256, control_state, prompt_id, prompt_version,
    prompt_sha256, output_schema_id, output_schema_contract_version,
    output_schema_sha256, provider_policy_version,
    provider_policy_sha256, provider_classification,
    provider_candidate_ids, max_micros_krw, reserved_micros_krw,
    settled_micros_krw, remaining_micros_krw,
    budget_reservation_state, budget_policy_version,
    budget_policy_sha256, max_provider_turns, max_tool_calls,
    completed_provider_turns, completed_tool_calls,
    next_turn_sequence, deadline_at, created_actor_type,
    created_service, created_at, updated_at
  ) VALUES (
    v_run_id, v_case_id, 'investigator',
    'TEST_FIXTURE_ONLY 승인 가설 재귀 원본 조사', '[]'::jsonb,
    'r6c-recursion-provider-policy-v1', 'QUEUED', v_snapshot_sha,
    'investigator-output.v2', 2.000000, NULL, 2, v_snapshot_id,
    v_initial_transcript, 'NONE', 'r6c-recursion-investigator', 'v1',
    encode(extensions.digest(
      convert_to('r6c-recursion-investigator:v1', 'UTF8'), 'sha256'
    ), 'hex'),
    'InvestigatorOutputV2', 'investigator-output.v2',
    'c9f4536c3d8f6ae58a66cc830fb1a71745fad01e370c69ef799511a21bc4f1f0',
    'r6c-recursion-provider-policy-v1',
    encode(extensions.digest(
      convert_to('r6c-recursion-provider-policy-v1', 'UTF8'), 'sha256'
    ), 'hex'),
    'PUBLIC', ARRAY['r6c-deterministic-double']::text[],
    2000000, 2000000, 0, 2000000, 'RESERVED',
    'r6c-recursion-budget-policy-v1',
    encode(extensions.digest(
      convert_to('r6c-recursion-budget-policy-v1', 'UTF8'), 'sha256'
    ), 'hex'),
    1, 0, 0, 0, 1, clock_timestamp() + interval '1 hour',
    'SERVICE', 'workflow-worker', clock_timestamp(), clock_timestamp()
  );
  INSERT INTO ops.jobs(
    id, job_type, queue, status, payload, dedupe_key,
    lease_owner, lease_token, lease_expires_at, fencing_token,
    attempt_count
  ) VALUES (
    v_job_id, 'AGENT_RUN', 'analysis-worker', 'RUNNING',
    jsonb_build_object(
      'agentRunId', v_run_id,
      'fixtureAuthority', 'TEST_FIXTURE_ONLY'
    ), 'r6c-recursion-origin-run:' || v_run_id::text,
    'r6c-recursion-origin-runtime', v_lease_token,
    clock_timestamp() + interval '10 minutes', 1, 1
  );
  INSERT INTO ops.job_attempts(
    job_id, attempt, worker_id, fencing_token, started_at
  ) VALUES (
    v_job_id, 1, 'r6c-recursion-origin-runtime', 1,
    clock_timestamp()
  );
END $$;

SET LOCAL ROLE gurine_analysis_worker;
DO $$
BEGIN
  PERFORM * FROM ops.claim_agent_run_worker_v2(
    '31600000-0000-4000-8000-000000000010',
    '31600000-0000-4000-8000-000000000011',
    '31600000-0000-4000-8000-000000000012', 1
  );
END $$;
RESET ROLE;

-- Persist one exact provider turn, its four-step source-use lineage, one
-- validated HYPOTHESIS suggestion, and its immutable citation.  The source
-- graph uses only PUBLIC data and the existing all-ALLOW rights decision.
DO $$
DECLARE
  v_run_id constant uuid := '31600000-0000-4000-8000-000000000010';
  v_job_id constant uuid := '31600000-0000-4000-8000-000000000011';
  v_lease_token constant uuid :=
    '31600000-0000-4000-8000-000000000012';
  v_turn_id constant uuid := '31600000-0000-4000-8000-000000000013';
  v_provider_receipt_id constant uuid :=
    '31600000-0000-4000-8000-000000000014';
  v_validation_id constant uuid :=
    '31600000-0000-4000-8000-000000000015';
  v_tool_query_use_id constant uuid :=
    '31600000-0000-4000-8000-000000000020';
  v_model_input_use_id constant uuid :=
    '31600000-0000-4000-8000-000000000021';
  v_derivation_use_id constant uuid :=
    '31600000-0000-4000-8000-000000000022';
  v_citation_use_id constant uuid :=
    '31600000-0000-4000-8000-000000000023';
  v_suggestion_ids constant uuid[] := ARRAY[
    '31600000-0000-4000-8000-000000000030'::uuid,
    '31600000-0000-4000-8000-000000000040'::uuid,
    '31600000-0000-4000-8000-000000000050'::uuid,
    '31600000-0000-4000-8000-000000000060'::uuid,
    '31600000-0000-4000-8000-000000000070'::uuid,
    '31600000-0000-4000-8000-000000000080'::uuid
  ];
  v_citation_ids constant uuid[] := ARRAY[
    '31600000-0000-4000-8000-000000000031'::uuid,
    '31600000-0000-4000-8000-000000000041'::uuid,
    '31600000-0000-4000-8000-000000000051'::uuid,
    '31600000-0000-4000-8000-000000000061'::uuid,
    '31600000-0000-4000-8000-000000000071'::uuid,
    '31600000-0000-4000-8000-000000000081'::uuid
  ];
  v_occurred_at constant timestamptz := '2026-08-01T03:00:00Z';
  v_snapshot core.dataset_snapshots%ROWTYPE;
  v_contract_member core.dataset_snapshot_members%ROWTYPE;
  v_contract_source core.dataset_snapshot_member_sources%ROWTYPE;
  v_evidence_member core.dataset_snapshot_members%ROWTYPE;
  v_evidence_source core.dataset_snapshot_member_sources%ROWTYPE;
  v_segment raw.evidence_segments%ROWTYPE;
  v_rights raw.asset_rights_decisions%ROWTYPE;
  v_run ops.agent_runs%ROWTYPE;
  v_claim ops.agent_run_control_receipts%ROWTYPE;
  v_statements constant text[] := ARRAY[
    '정책 미설정 경계 확인',
    '정책 비활성 경계 확인',
    '케이스 예산 상한 확인',
    '재귀 깊이 상한 확인',
    '경정 조사와 반증 단계 관통 확인',
    '케이스 버전 경합 차단 확인'
  ];
  v_unknowns constant text[] := ARRAY[
    '정책 미설정 항목',
    '정책 비활성 항목',
    '케이스 예산 항목',
    '재귀 깊이 항목',
    '근거 공백과 반증 항목',
    '동시 수정 버전 항목'
  ];
  v_supports constant text := '계약 변경 기록의 추가 확인 필요성을 뒷받침';
  v_supports_sha char(64);
  v_tool_query_unsigned jsonb;
  v_tool_query_sha char(64);
  v_model_input_unsigned jsonb;
  v_model_input_sha char(64);
  v_derivation_unsigned jsonb;
  v_derivation_sha char(64);
  v_citation_unsigned jsonb;
  v_citation_sha char(64);
  v_output jsonb;
  v_output_sha char(64);
  v_request jsonb := jsonb_build_object(
    'schemaVersion', 'r6c-recursion-provider-request.v1',
    'fixtureAuthority', 'TEST_FIXTURE_ONLY'
  );
  v_request_canonical bytea;
  v_request_sha char(64);
  v_provider_receipt jsonb := jsonb_build_object(
    'schemaVersion', 'r6c-recursion-provider-receipt.v1',
    'fixtureAuthority', 'TEST_FIXTURE_ONLY'
  );
  v_provider_receipt_canonical bytea;
  v_provider_receipt_sha char(64);
  v_turn_canonical bytea;
  v_turn_sha char(64);
  v_hypothesis_drafts jsonb := '[]'::jsonb;
  v_suggestion_payloads jsonb := '[]'::jsonb;
  v_suggestion_canonicals bytea[] := ARRAY[]::bytea[];
  v_suggestion_shas text[] := ARRAY[]::text[];
  v_citation_digests text[] := ARRAY[]::text[];
  v_citation_set_sha char(64);
  v_proposal_set_sha char(64);
  v_validation_preimage jsonb;
  v_validation_sha char(64);
  v_ordinal integer;
BEGIN
  SELECT * INTO STRICT v_snapshot
  FROM core.dataset_snapshots
  WHERE producer_key = 'r6c-hypothesis-recursion-runtime'
    AND snapshot_kind = 'AGENT_CASE' AND state = 'READY';
  SELECT * INTO STRICT v_contract_member
  FROM core.dataset_snapshot_members
  WHERE dataset_snapshot_id = v_snapshot.id AND member_ordinal = 0;
  SELECT * INTO STRICT v_contract_source
  FROM core.dataset_snapshot_member_sources
  WHERE snapshot_member_id = v_contract_member.id AND source_ordinal = 0;
  SELECT * INTO STRICT v_evidence_member
  FROM core.dataset_snapshot_members
  WHERE dataset_snapshot_id = v_snapshot.id AND member_ordinal = 1;
  SELECT * INTO STRICT v_evidence_source
  FROM core.dataset_snapshot_member_sources
  WHERE snapshot_member_id = v_evidence_member.id AND source_ordinal = 0;
  SELECT * INTO STRICT v_segment
  FROM raw.evidence_segments
  WHERE id = '31600000-0000-4000-8000-000000000001';
  SELECT * INTO STRICT v_rights
  FROM raw.asset_rights_decisions
  WHERE id = '31300000-0000-4000-8000-000000000002';
  SELECT * INTO STRICT v_run FROM ops.agent_runs WHERE id = v_run_id;
  SELECT * INTO STRICT v_claim
  FROM ops.agent_run_control_receipts
  WHERE agent_run_id = v_run_id AND aggregate_version = 1;
  IF v_run.status <> 'RUNNING' OR v_run.version <> 2
     OR v_claim.reason_code <> 'RUN_STARTED' THEN
    RAISE EXCEPTION 'R6c recursion origin claim invalid';
  END IF;

  v_supports_sha := encode(extensions.digest(
    convert_to(v_supports, 'UTF8'), 'sha256'
  ), 'hex');
  v_tool_query_unsigned := jsonb_build_object(
    'schemaVersion', 'source-use.v2',
    'sourceUseId', v_tool_query_use_id,
    'agentRunId', v_run_id,
    'providerTurnId', NULL,
    'toolCallId', NULL,
    'parentSourceUseId', NULL,
    'parentSourceUseSha256', NULL,
    'useKind', 'TOOL_QUERY',
    'sourceKind', 'DATASET_MEMBER',
    'sourceIdentity', jsonb_build_object(
      'kind', 'DATASET_MEMBER',
      'datasetSnapshotId', v_snapshot.id,
      'snapshotMemberId', v_contract_member.id,
      'snapshotMemberDigest', btrim(v_contract_member.member_digest),
      'objectType', v_contract_member.object_type,
      'objectId', v_contract_member.object_id,
      'objectVersion', v_contract_member.object_version,
      'objectContentSha256', btrim(v_contract_member.object_content_sha256)
    ),
    'locator', jsonb_build_object(
      'kind', NULL, 'value', NULL, 'locatorSha256', NULL
    ),
    'selectedContentSha256', NULL,
    'classification', 'PUBLIC',
    'rightsDecision', jsonb_build_object(
      'decisionId', v_rights.id,
      'decisionVersion', v_rights.decision_version,
      'decisionSha256', btrim(v_rights.decision_sha256),
      'effectiveAt', v_rights.effective_at,
      'expiresAt', v_rights.expires_at,
      'accessRight', v_rights.access_right,
      'privateStorageRight', v_rights.private_storage_right,
      'modelEgressRight', v_rights.model_egress_right,
      'modelUseRight', v_rights.model_use_right,
      'derivativeCreationRight', v_rights.derivative_creation_right,
      'excerptRight', v_rights.excerpt_right,
      'redistributionRight', v_rights.redistribution_right,
      'commercialUseRight', v_rights.commercial_use_right,
      'publicDisplayRight', v_rights.public_display_right
    ),
    'providerReceiptId', NULL,
    'occurredAt', v_occurred_at
  );
  v_tool_query_sha := encode(extensions.digest(
    ops.canonical_jsonb_v1(v_tool_query_unsigned), 'sha256'
  ), 'hex');
  v_model_input_unsigned := jsonb_build_object(
    'schemaVersion', 'source-use.v2',
    'sourceUseId', v_model_input_use_id,
    'agentRunId', v_run_id,
    'providerTurnId', v_turn_id,
    'toolCallId', NULL,
    'parentSourceUseId', v_tool_query_use_id,
    'parentSourceUseSha256', btrim(v_tool_query_sha),
    'useKind', 'MODEL_INPUT',
    'sourceKind', 'EVIDENCE_SEGMENT',
    'sourceIdentity', jsonb_build_object(
      'kind', 'EVIDENCE_SEGMENT',
      'datasetSnapshotId', v_snapshot.id,
      'snapshotMemberId', v_evidence_member.id,
      'snapshotMemberDigest', btrim(v_evidence_member.member_digest),
      'objectType', 'EVIDENCE_SEGMENT',
      'objectId', v_segment.id,
      'objectVersion', 1,
      'objectContentSha256', btrim(v_segment.selected_content_sha256)
    ),
    'locator', jsonb_build_object(
      'kind', v_segment.locator_kind,
      'value', v_segment.locator_value,
      'locatorSha256', btrim(v_segment.locator_digest)
    ),
    'selectedContentSha256', btrim(v_segment.selected_content_sha256),
    'classification', 'PUBLIC',
    'rightsDecision', v_tool_query_unsigned->'rightsDecision',
    'providerReceiptId', v_provider_receipt_id,
    'occurredAt', v_occurred_at
  );
  v_model_input_sha := encode(extensions.digest(
    ops.canonical_jsonb_v1(v_model_input_unsigned), 'sha256'
  ), 'hex');
  v_derivation_unsigned := v_model_input_unsigned || jsonb_build_object(
    'sourceUseId', v_derivation_use_id,
    'parentSourceUseId', v_model_input_use_id,
    'parentSourceUseSha256', btrim(v_model_input_sha),
    'useKind', 'MODEL_OUTPUT_DERIVATION'
  );
  v_derivation_sha := encode(extensions.digest(
    ops.canonical_jsonb_v1(v_derivation_unsigned), 'sha256'
  ), 'hex');
  v_citation_unsigned := v_model_input_unsigned || jsonb_build_object(
    'sourceUseId', v_citation_use_id,
    'providerTurnId', NULL,
    'parentSourceUseId', v_derivation_use_id,
    'parentSourceUseSha256', btrim(v_derivation_sha),
    'useKind', 'CITATION',
    'providerReceiptId', NULL
  );
  v_citation_sha := encode(extensions.digest(
    ops.canonical_jsonb_v1(v_citation_unsigned), 'sha256'
  ), 'hex');

  FOR v_ordinal IN 1..array_length(v_suggestion_ids, 1) LOOP
    v_hypothesis_drafts := v_hypothesis_drafts || jsonb_build_array(
      jsonb_build_object(
        'proposalKind', 'HYPOTHESIS',
        'proposalState', 'PROPOSAL_ONLY',
        'statement', v_statements[v_ordinal],
        'assessment', 'UNRESOLVED',
        'supportingCitationIndexes', jsonb_build_array(0),
        'contradictingCitationIndexes', '[]'::jsonb,
        'unknowns', jsonb_build_array(v_unknowns[v_ordinal])
      )
    );
    v_suggestion_payloads := v_suggestion_payloads || jsonb_build_array(
      jsonb_build_object(
        'kind', 'HYPOTHESIS',
        'statement', v_statements[v_ordinal],
        'supportingCitationIds', jsonb_build_array(
          v_citation_ids[v_ordinal]
        ),
        'contradictingCitationIds', '[]'::jsonb,
        'unknowns', jsonb_build_array(v_unknowns[v_ordinal]),
        'limitations', '[]'::jsonb
      )
    );
  END LOOP;
  v_output := jsonb_build_object(
    'schemaVersion', 'investigator-output.v2',
    'outcome', 'COMPLETED',
    'summary', 'TEST_FIXTURE_ONLY 재귀 조사 제안',
    'investigationsPerformed', '[]'::jsonb,
    'citations', jsonb_build_array(jsonb_build_object(
      'sourceUseSha256', btrim(v_citation_sha),
      'locator', jsonb_build_object(
        'kind', v_segment.locator_kind,
        'value', v_segment.locator_value,
        'locatorSha256', btrim(v_segment.locator_digest)
      ),
      'selectedContentSha256', btrim(v_segment.selected_content_sha256),
      'supports', v_supports,
      'supportsSha256', btrim(v_supports_sha)
    )),
    'unknowns', jsonb_build_array('추가 확인 항목'),
    'nextActions', '[]'::jsonb,
    'abstentionReasons', '[]'::jsonb,
    'hypotheses', v_hypothesis_drafts,
    'counterEvidence', '[]'::jsonb,
    'tasks', '[]'::jsonb
  );
  v_output_sha := encode(extensions.digest(
    ops.canonical_jsonb_v1(v_output), 'sha256'
  ), 'hex');
  v_request_canonical := ops.canonical_jsonb_v1(v_request);
  v_request_sha := encode(extensions.digest(
    v_request_canonical, 'sha256'
  ), 'hex');
  v_provider_receipt_canonical := ops.canonical_jsonb_v1(
    v_provider_receipt
  );
  v_provider_receipt_sha := encode(extensions.digest(
    v_provider_receipt_canonical, 'sha256'
  ), 'hex');
  v_turn_canonical := ops.canonical_jsonb_v1(jsonb_build_object(
    'schemaVersion', 'r6c-recursion-provider-turn.v1',
    'providerTurnId', v_turn_id,
    'outputSha256', btrim(v_output_sha),
    'providerReceiptSha256', btrim(v_provider_receipt_sha),
    'fixtureAuthority', 'TEST_FIXTURE_ONLY'
  ));
  v_turn_sha := encode(extensions.digest(v_turn_canonical, 'sha256'), 'hex');
  INSERT INTO ops.agent_provider_turns(
    provider_turn_id, agent_run_id, input_snapshot_sha256,
    turn_sequence, attempt_sequence, prior_transcript_sha256,
    provider_mode, provider_candidate_id, model_id,
    model_configuration_sha256, routing_policy_version,
    routing_decision_sha256, prompt_id, prompt_version, prompt_sha256,
    output_schema_id, output_schema_version, output_schema_sha256,
    classification, model_use_rights_sha256,
    budget_reservation_key_sha256, dispatch_key_sha256,
    request_sha256, request_redacted, request_canonical, status,
    envelope_kind, envelope_sha256, envelope_payload_sha256,
    envelope_canonical, response_redacted, response_redacted_canonical,
    provider_receipt_id, provider_receipt, provider_receipt_canonical,
    provider_receipt_sha256, provider_turn_canonical,
    provider_turn_sha256, turn_transcript_sha256, input_units,
    output_units, latency_ms, version, dispatched_at, completed_at
  ) VALUES (
    v_turn_id, v_run_id, v_snapshot.snapshot_sha256, 1, 1,
    v_run.initial_transcript_sha256, 'DETERMINISTIC_DOUBLE',
    'r6c-deterministic-double', 'r6c-deterministic-model',
    encode(extensions.digest(
      convert_to('r6c-deterministic-model', 'UTF8'), 'sha256'
    ), 'hex'),
    v_run.provider_policy_version, v_run.provider_policy_sha256,
    v_run.prompt_id, v_run.prompt_version, v_run.prompt_sha256,
    v_run.output_schema_id, v_run.output_schema_contract_version,
    v_run.output_schema_sha256, 'PUBLIC', v_rights.decision_sha256,
    encode(extensions.digest(
      convert_to('r6c-recursion-budget-reservation', 'UTF8'), 'sha256'
    ), 'hex'),
    encode(extensions.digest(
      convert_to('r6c-recursion-dispatch', 'UTF8'), 'sha256'
    ), 'hex'),
    v_request_sha, v_request, v_request_canonical, 'COMPLETED',
    'FINAL_OUTPUT', v_output_sha, v_output_sha,
    ops.canonical_jsonb_v1(v_output), v_output,
    ops.canonical_jsonb_v1(v_output), v_provider_receipt_id,
    v_provider_receipt, v_provider_receipt_canonical,
    v_provider_receipt_sha, v_turn_canonical, v_turn_sha,
    encode(extensions.digest(
      ops.canonical_jsonb_v1(jsonb_build_object(
        'priorTranscriptSha256', btrim(v_run.initial_transcript_sha256),
        'providerTurnSha256', btrim(v_turn_sha)
      )), 'sha256'
    ), 'hex'),
    1, 1, 1, 1, v_occurred_at, v_occurred_at + interval '1 second'
  );

  FOR v_ordinal IN 1..array_length(v_suggestion_ids, 1) LOOP
    v_suggestion_canonicals := array_append(
      v_suggestion_canonicals,
      ops.canonical_jsonb_v1(v_suggestion_payloads->(v_ordinal - 1))
    );
    v_suggestion_shas := array_append(
      v_suggestion_shas,
      encode(extensions.digest(
        v_suggestion_canonicals[v_ordinal], 'sha256'
      ), 'hex')
    );
    v_citation_digests := array_append(
      v_citation_digests,
      encode(extensions.digest(convert_to(
        v_suggestion_ids[v_ordinal]::text || ':0:'
          || btrim(v_citation_sha),
        'UTF8'
      ), 'sha256'), 'hex')
    );
  END LOOP;
  v_citation_set_sha := encode(extensions.digest(
    ops.canonical_jsonb_v1(v_output->'citations'), 'sha256'
  ), 'hex');
  v_proposal_set_sha := encode(extensions.digest(
    ops.canonical_jsonb_v1(v_output->'hypotheses'), 'sha256'
  ), 'hex');
  v_validation_preimage := jsonb_build_object(
    'agentRunId', v_run_id,
    'providerTurnId', v_turn_id,
    'outputSha256', btrim(v_output_sha),
    'receiptSha256', btrim(v_provider_receipt_sha),
    'citationSetSha256', btrim(v_citation_set_sha)
  );
  v_validation_sha := encode(extensions.digest(
    ops.canonical_jsonb_v1(v_validation_preimage), 'sha256'
  ), 'hex');
  INSERT INTO ops.agent_output_validations(
    validation_id, agent_run_id, provider_turn_id,
    input_snapshot_sha256, provider_output_sha256,
    validator_version, validator_sha256, output_schema_id,
    output_schema_version, output_schema_sha256,
    validation_policy_version, validation_policy_sha256,
    validation_status, schema_status, citation_status, policy_status,
    run_terminal_status, output_status, failure_code,
    failure_details_redacted, validated_outcome,
    validated_outcome_sha256, citation_count, proposal_count,
    citation_set_sha256, proposal_set_sha256, validation_sha256,
    validated_at
  ) VALUES (
    v_validation_id, v_run_id, v_turn_id, v_snapshot.snapshot_sha256,
    v_output_sha, 'r6c-recursion-validator-v1',
    encode(extensions.digest(
      convert_to('r6c-recursion-validator-v1', 'UTF8'), 'sha256'
    ), 'hex'),
    v_run.output_schema_id, v_run.output_schema_contract_version,
    v_run.output_schema_sha256, 'r6c-recursion-validation-policy-v1',
    encode(extensions.digest(
      convert_to('r6c-recursion-validation-policy-v1', 'UTF8'), 'sha256'
    ), 'hex'),
    'VALID', 'PASS', 'PASS', 'PASS', 'SUCCEEDED', 'COMPLETED',
    NULL, '[]'::jsonb, v_output, v_output_sha, 1,
    array_length(v_suggestion_ids, 1),
    v_citation_set_sha, v_proposal_set_sha, v_validation_sha,
    v_occurred_at + interval '2 seconds'
  );
  FOR v_ordinal IN 1..array_length(v_suggestion_ids, 1) LOOP
    INSERT INTO ops.agent_suggestions(
      id, agent_run_id, case_id, suggestion_type, payload, evidence_ids,
      citation_checks, status, version, created_at,
      proposal_contract_version, target_schema_version, payload_sha256,
      payload_canonical, input_snapshot_sha256, citation_validation_id,
      expires_at
    ) VALUES (
      v_suggestion_ids[v_ordinal], v_run_id, v_run.case_id,
      'HYPOTHESIS', v_suggestion_payloads->(v_ordinal - 1),
      '[]'::jsonb, '[]'::jsonb, 'PENDING', 1,
      v_occurred_at + make_interval(secs => 2 + v_ordinal), 2,
      v_run.output_schema_id, v_suggestion_shas[v_ordinal],
      v_suggestion_canonicals[v_ordinal], v_snapshot.snapshot_sha256,
      v_validation_id, v_occurred_at + interval '7 days'
    );
  END LOOP;

  INSERT INTO ops.agent_source_uses(
    source_use_id, source_use_contract_version, agent_run_id,
    use_kind, source_kind, dataset_snapshot_id, snapshot_member_id,
    snapshot_member_digest, snapshot_member_source_id,
    snapshot_member_source_digest, member_source_kind, object_type,
    object_id, object_version, object_content_sha256,
    source_document_id, source_asset_id, source_asset_revision,
    source_content_sha256, selected_content_sha256, classification,
    rights_binding_kind, rights_asset_id, rights_asset_revision,
    rights_asset_sha256, asset_rights_decision_id,
    asset_rights_decision_version, asset_rights_decision_sha256,
    rights_effective_at, rights_expires_at, access_right,
    private_storage_right, model_egress_right, model_use_right,
    derivative_creation_right, excerpt_right, redistribution_right,
    commercial_use_right, public_display_right, rights_policy_version,
    rights_policy_sha256, occurred_at, source_use_canonical,
    source_use_sha256
  ) VALUES (
    v_tool_query_use_id, 2, v_run_id, 'TOOL_QUERY', 'DATASET_MEMBER',
    v_snapshot.id, v_contract_member.id, v_contract_member.member_digest,
    v_contract_source.id, v_contract_source.source_digest,
    'SOURCE_DOCUMENT', v_contract_member.object_type,
    v_contract_member.object_id, v_contract_member.object_version,
    v_contract_member.object_content_sha256,
    v_contract_source.source_document_id, v_contract_source.source_asset_id,
    v_contract_source.source_asset_revision,
    v_contract_source.source_content_sha256, NULL, 'PUBLIC',
    'ASSET_RIGHTS', v_rights.asset_id, v_rights.asset_revision,
    v_rights.asset_sha256, v_rights.id, v_rights.decision_version,
    v_rights.decision_sha256, v_rights.effective_at, v_rights.expires_at,
    v_rights.access_right, v_rights.private_storage_right,
    v_rights.model_egress_right, v_rights.model_use_right,
    v_rights.derivative_creation_right, v_rights.excerpt_right,
    v_rights.redistribution_right, v_rights.commercial_use_right,
    v_rights.public_display_right, v_rights.policy_version,
    v_rights.policy_sha256, v_occurred_at,
    ops.canonical_jsonb_v1(v_tool_query_unsigned || jsonb_build_object(
      'sourceUseSha256', btrim(v_tool_query_sha)
    )), v_tool_query_sha
  );

  INSERT INTO ops.agent_source_uses(
    source_use_id, source_use_contract_version, agent_run_id,
    provider_turn_id, parent_source_use_id, parent_source_use_sha256,
    use_kind, source_kind, dataset_snapshot_id, snapshot_member_id,
    snapshot_member_digest, snapshot_member_source_id,
    snapshot_member_source_digest, member_source_kind, object_type,
    object_id, object_version, object_content_sha256, evidence_segment_id,
    source_document_id, source_asset_id, source_asset_revision,
    source_content_sha256, locator_kind, locator_value, locator_sha256,
    selected_content_sha256, classification, rights_binding_kind,
    rights_asset_id, rights_asset_revision, rights_asset_sha256,
    asset_rights_decision_id, asset_rights_decision_version,
    asset_rights_decision_sha256, rights_effective_at, rights_expires_at,
    access_right, private_storage_right, model_egress_right,
    model_use_right, derivative_creation_right, excerpt_right,
    redistribution_right, commercial_use_right, public_display_right,
    rights_policy_version, rights_policy_sha256, provider_receipt_id,
    provider_receipt_sha256, occurred_at, source_use_canonical,
    source_use_sha256
  ) VALUES
  (
    v_model_input_use_id, 2, v_run_id, v_turn_id,
    v_tool_query_use_id, v_tool_query_sha, 'MODEL_INPUT',
    'EVIDENCE_SEGMENT', v_snapshot.id, v_evidence_member.id,
    v_evidence_member.member_digest, v_evidence_source.id,
    v_evidence_source.source_digest, 'SOURCE_DOCUMENT',
    'EVIDENCE_SEGMENT', v_segment.id, 1,
    v_segment.selected_content_sha256, v_segment.id,
    v_segment.source_document_id, v_segment.source_asset_id,
    v_segment.source_asset_revision, v_segment.source_content_sha256,
    v_segment.locator_kind, v_segment.locator_value,
    v_segment.locator_digest, v_segment.selected_content_sha256,
    'PUBLIC', 'ASSET_RIGHTS', v_rights.asset_id,
    v_rights.asset_revision, v_rights.asset_sha256, v_rights.id,
    v_rights.decision_version, v_rights.decision_sha256,
    v_rights.effective_at, v_rights.expires_at, v_rights.access_right,
    v_rights.private_storage_right, v_rights.model_egress_right,
    v_rights.model_use_right, v_rights.derivative_creation_right,
    v_rights.excerpt_right, v_rights.redistribution_right,
    v_rights.commercial_use_right, v_rights.public_display_right,
    v_rights.policy_version, v_rights.policy_sha256,
    v_provider_receipt_id, v_provider_receipt_sha, v_occurred_at,
    ops.canonical_jsonb_v1(v_model_input_unsigned || jsonb_build_object(
      'sourceUseSha256', btrim(v_model_input_sha)
    )), v_model_input_sha
  ),
  (
    v_derivation_use_id, 2, v_run_id, v_turn_id,
    v_model_input_use_id, v_model_input_sha, 'MODEL_OUTPUT_DERIVATION',
    'EVIDENCE_SEGMENT', v_snapshot.id, v_evidence_member.id,
    v_evidence_member.member_digest, v_evidence_source.id,
    v_evidence_source.source_digest, 'SOURCE_DOCUMENT',
    'EVIDENCE_SEGMENT', v_segment.id, 1,
    v_segment.selected_content_sha256, v_segment.id,
    v_segment.source_document_id, v_segment.source_asset_id,
    v_segment.source_asset_revision, v_segment.source_content_sha256,
    v_segment.locator_kind, v_segment.locator_value,
    v_segment.locator_digest, v_segment.selected_content_sha256,
    'PUBLIC', 'ASSET_RIGHTS', v_rights.asset_id,
    v_rights.asset_revision, v_rights.asset_sha256, v_rights.id,
    v_rights.decision_version, v_rights.decision_sha256,
    v_rights.effective_at, v_rights.expires_at, v_rights.access_right,
    v_rights.private_storage_right, v_rights.model_egress_right,
    v_rights.model_use_right, v_rights.derivative_creation_right,
    v_rights.excerpt_right, v_rights.redistribution_right,
    v_rights.commercial_use_right, v_rights.public_display_right,
    v_rights.policy_version, v_rights.policy_sha256,
    v_provider_receipt_id, v_provider_receipt_sha,
    v_occurred_at + interval '1 second',
    ops.canonical_jsonb_v1(v_derivation_unsigned || jsonb_build_object(
      'sourceUseSha256', btrim(v_derivation_sha)
    )), v_derivation_sha
  );

  INSERT INTO ops.agent_source_uses(
    source_use_id, source_use_contract_version, agent_run_id,
    parent_source_use_id, parent_source_use_sha256, use_kind,
    source_kind, dataset_snapshot_id, snapshot_member_id,
    snapshot_member_digest, snapshot_member_source_id,
    snapshot_member_source_digest, member_source_kind, object_type,
    object_id, object_version, object_content_sha256, evidence_segment_id,
    source_document_id, source_asset_id, source_asset_revision,
    source_content_sha256, locator_kind, locator_value, locator_sha256,
    selected_content_sha256, classification, rights_binding_kind,
    rights_asset_id, rights_asset_revision, rights_asset_sha256,
    asset_rights_decision_id, asset_rights_decision_version,
    asset_rights_decision_sha256, rights_effective_at, rights_expires_at,
    access_right, private_storage_right, model_egress_right,
    model_use_right, derivative_creation_right, excerpt_right,
    redistribution_right, commercial_use_right, public_display_right,
    rights_policy_version, rights_policy_sha256, occurred_at,
    source_use_canonical, source_use_sha256
  ) VALUES (
    v_citation_use_id, 2, v_run_id, v_derivation_use_id,
    v_derivation_sha, 'CITATION', 'EVIDENCE_SEGMENT', v_snapshot.id,
    v_evidence_member.id, v_evidence_member.member_digest,
    v_evidence_source.id, v_evidence_source.source_digest,
    'SOURCE_DOCUMENT', 'EVIDENCE_SEGMENT', v_segment.id, 1,
    v_segment.selected_content_sha256, v_segment.id,
    v_segment.source_document_id, v_segment.source_asset_id,
    v_segment.source_asset_revision, v_segment.source_content_sha256,
    v_segment.locator_kind, v_segment.locator_value,
    v_segment.locator_digest, v_segment.selected_content_sha256,
    'PUBLIC', 'ASSET_RIGHTS', v_rights.asset_id,
    v_rights.asset_revision, v_rights.asset_sha256, v_rights.id,
    v_rights.decision_version, v_rights.decision_sha256,
    v_rights.effective_at, v_rights.expires_at, v_rights.access_right,
    v_rights.private_storage_right, v_rights.model_egress_right,
    v_rights.model_use_right, v_rights.derivative_creation_right,
    v_rights.excerpt_right, v_rights.redistribution_right,
    v_rights.commercial_use_right, v_rights.public_display_right,
    v_rights.policy_version, v_rights.policy_sha256,
    v_occurred_at + interval '2 seconds',
    ops.canonical_jsonb_v1(v_citation_unsigned || jsonb_build_object(
      'sourceUseSha256', btrim(v_citation_sha)
    )), v_citation_sha
  );

  FOR v_ordinal IN 1..array_length(v_suggestion_ids, 1) LOOP
    INSERT INTO ops.agent_proposal_citations(
      citation_id, citation_contract_version, proposal_id, agent_run_id,
      provider_turn_id, validation_id, dataset_snapshot_id,
      snapshot_member_id, snapshot_member_digest, citation_ordinal,
      input_snapshot_sha256, proposal_payload_sha256, source_kind,
      source_use_id, source_use_sha256, evidence_segment_id, source_id,
      locator_kind, locator_value, locator_digest, content_sha256,
      supports_redacted, supports_sha256, citation_digest
    ) VALUES (
      v_citation_ids[v_ordinal], 2, v_suggestion_ids[v_ordinal],
      v_run_id, v_turn_id, v_validation_id, v_snapshot.id,
      v_evidence_member.id, v_evidence_member.member_digest, 0,
      v_snapshot.snapshot_sha256, v_suggestion_shas[v_ordinal],
      'EVIDENCE_SEGMENT', v_citation_use_id, v_citation_sha,
      v_segment.id, v_segment.id, v_segment.locator_kind,
      v_segment.locator_value, v_segment.locator_digest,
      v_segment.selected_content_sha256, v_supports, v_supports_sha,
      v_citation_digests[v_ordinal]
    );
  END LOOP;

END $$;

SET LOCAL ROLE gurine_analysis_worker;
DO $$
DECLARE
  v_run_id constant uuid := '31600000-0000-4000-8000-000000000010';
  v_job_id constant uuid := '31600000-0000-4000-8000-000000000011';
  v_lease_token constant uuid :=
    '31600000-0000-4000-8000-000000000012';
  v_claim ops.agent_run_control_receipts%ROWTYPE;
  v_validation ops.agent_output_validations%ROWTYPE;
BEGIN
  SELECT * INTO STRICT v_claim
  FROM ops.agent_run_control_receipts
  WHERE agent_run_id = v_run_id AND aggregate_version = 1;
  SELECT * INTO STRICT v_validation
  FROM ops.agent_output_validations
  WHERE validation_id = '31600000-0000-4000-8000-000000000015';
  PERFORM * FROM ops.complete_agent_run_worker_v2(
    v_run_id, 2, v_claim.receipt_id, v_claim.receipt_sha256,
    v_job_id, v_lease_token, 1, 'SUCCEEDED',
    'r6c-deterministic-double', 'r6c-deterministic-model',
    v_validation.validated_outcome,
    v_validation.provider_output_sha256,
    NULL, NULL, NULL, 1.600000
  );
END $$;
RESET ROLE;

UPDATE ops.jobs
SET status = 'SUCCEEDED', lease_owner = NULL, lease_token = NULL,
    lease_expires_at = NULL, updated_at = clock_timestamp()
WHERE id = '31600000-0000-4000-8000-000000000011'
  AND status = 'RUNNING';
UPDATE ops.job_attempts
SET outcome = 'SUCCEEDED', finished_at = clock_timestamp()
WHERE job_id = '31600000-0000-4000-8000-000000000011'
  AND attempt = 1 AND outcome IS NULL;

DO $$
DECLARE
  v_run ops.agent_runs%ROWTYPE;
  v_suggestion_count bigint;
BEGIN
  SELECT * INTO STRICT v_run
  FROM ops.agent_runs
  WHERE id = '31600000-0000-4000-8000-000000000010';
  SELECT count(*) INTO STRICT v_suggestion_count
  FROM ops.agent_suggestions AS suggestion
  WHERE suggestion.agent_run_id = v_run.id
    AND suggestion.citation_validation_id =
      '31600000-0000-4000-8000-000000000015'
    AND suggestion.suggestion_type = 'HYPOTHESIS'
    AND suggestion.status = 'PENDING'
    AND suggestion.version = 1
    AND suggestion.proposal_contract_version = 2
    AND suggestion.payload_sha256 = encode(extensions.digest(
      suggestion.payload_canonical, 'sha256'
    ), 'hex');
  IF v_run.run_contract_version <> 2
     OR v_run.status <> 'SUCCEEDED'
     OR v_run.control_state <> 'SETTLED'
     OR v_run.version <> 3
     OR v_run.actual_cost <> 1.600000
     OR v_run.output_validation_id
       <> '31600000-0000-4000-8000-000000000015'
     OR v_suggestion_count <> 6
     OR (SELECT count(*) FROM ops.agent_source_uses
         WHERE agent_run_id = v_run.id) <> 4
     OR (SELECT count(*) FROM ops.agent_proposal_citations AS citation
         JOIN ops.agent_suggestions AS suggestion
           ON suggestion.id = citation.proposal_id
         WHERE suggestion.agent_run_id = v_run.id) <> 6
     OR NOT EXISTS (
       SELECT 1
       FROM ops.user_roles AS user_role
       JOIN ops.roles AS role ON role.id = user_role.role_id
       JOIN ops.role_capabilities AS capability
         ON capability.role_id = role.id
        AND capability.capability_code = 'actions.review'
       WHERE user_role.user_id =
         '00000000-0000-4000-8000-000000000316'
         AND user_role.revoked_at IS NULL
         AND role.code = 'EXECUTIVE_APPROVER'
     )
     OR NOT EXISTS (
       SELECT 1
       FROM ops.outbox
       WHERE aggregate_type = 'agent_run'
         AND aggregate_id = v_run.id::text
         AND event_type = 'agent.run_completed.v1'
         AND payload->>'status' = 'SUCCEEDED'
     ) THEN
    RAISE EXCEPTION 'R6c recursion authoritative origin invalid';
  END IF;
END $$;


COMMIT;
\endif

\if :r6c_recursion_prepare_redelivery
BEGIN;
SET LOCAL TIME ZONE 'UTC';

-- Re-open the exact successful EVENT_DELIVERY job and its inbox row as a
-- deterministic second attempt.  The producer job id and event payload stay
-- byte-identical, which is the owner routine's replay authority.  Baseline
-- cardinalities are recorded on attempt 1 before the retry so attempt 2 can
-- prove the immutable recursion graph did not grow.
DO $$
DECLARE
  v_receipt ops.hypothesis_recursion_receipts%ROWTYPE;
  v_job ops.jobs%ROWTYPE;
  v_event_id uuid;
  v_baseline jsonb;
BEGIN
  SELECT receipt.* INTO STRICT v_receipt
  FROM ops.hypothesis_recursion_receipts AS receipt
  JOIN ops.hypothesis_recursion_nodes AS node
    ON node.agent_run_id = receipt.trigger_id
  JOIN ops.hypothesis_recursion_plans AS plan
    ON plan.plan_id = node.plan_id
  JOIN ops.execution_authorizations AS execution_authorization
    ON execution_authorization.execution_id = plan.root_hypothesis_execution_id
   AND execution_authorization.generation =
     plan.root_hypothesis_execution_generation
  WHERE receipt.trigger_kind = 'AGENT_RUN'
    AND receipt.disposition = 'MAX_DEPTH_REACHED'
    AND execution_authorization.proposal_id =
      '31610000-0000-4000-8000-000000000004';
  SELECT job.* INTO STRICT v_job
  FROM ops.jobs AS job
  WHERE job.id = v_receipt.producer_job_id
  FOR UPDATE;
  v_event_id := (v_job.payload->>'eventId')::uuid;
  IF v_job.status <> 'SUCCEEDED' OR v_job.attempt_count <> 1
     OR v_job.fencing_token <> 1
     OR v_job.payload->>'eventType' <> 'agent.run_completed.v1'
     OR NOT EXISTS (
       SELECT 1 FROM ops.job_attempts AS attempt
       WHERE attempt.job_id = v_job.id AND attempt.attempt = 1
         AND attempt.outcome = 'SUCCEEDED'
         AND attempt.finished_at IS NOT NULL
     )
     OR NOT EXISTS (
       SELECT 1 FROM ops.inbox AS inbox
       WHERE inbox.consumer = 'workflow-worker'
         AND inbox.event_id = v_event_id
         AND inbox.processed_at IS NOT NULL
         AND inbox.result = 'SUCCEEDED'
     ) THEN
    RAISE EXCEPTION 'R6c exact redelivery predecessor invalid';
  END IF;
  v_baseline := jsonb_build_object(
    'policies',(SELECT count(*) FROM ops.hypothesis_recursion_policies),
    'plans',(SELECT count(*) FROM ops.hypothesis_recursion_plans),
    'nodes',(SELECT count(*) FROM ops.hypothesis_recursion_nodes),
    'transitions',(
      SELECT count(*) FROM ops.hypothesis_recursion_transitions
    ),
    'receipts',(SELECT count(*) FROM ops.hypothesis_recursion_receipts),
    'ledger',(
      SELECT count(*) FROM ops.hypothesis_recursion_budget_ledger
    ),
    'agentRuns',(SELECT count(*) FROM ops.agent_runs),
    'jobs',(SELECT count(*) FROM ops.jobs),
    'outbox',(SELECT count(*) FROM ops.outbox),
    'receiptId',v_receipt.receipt_id,
    'receiptDigest',btrim(v_receipt.receipt_digest::text),
    'producerJobId',v_job.id,
    'eventId',v_event_id
  );
  UPDATE ops.job_attempts AS attempt
  SET metrics = attempt.metrics || jsonb_build_object(
    'exactRedeliveryBaseline',v_baseline
  )
  WHERE attempt.job_id = v_job.id AND attempt.attempt = 1
    AND attempt.outcome = 'SUCCEEDED';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6c exact redelivery baseline write failed';
  END IF;
  UPDATE ops.inbox AS inbox
  SET processed_at = NULL,
      result = 'DISPATCHED:' || v_job.id::text
  WHERE inbox.consumer = 'workflow-worker'
    AND inbox.event_id = v_event_id
    AND inbox.processed_at IS NOT NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6c exact redelivery inbox reset failed';
  END IF;
  UPDATE ops.jobs AS job
  SET status = 'QUEUED',run_after = clock_timestamp(),
      lease_owner = NULL,lease_token = NULL,lease_expires_at = NULL,
      completed_at = NULL,last_error_code = NULL,last_error_detail = NULL,
      version = job.version + 1,updated_at = clock_timestamp()
  WHERE job.id = v_job.id
    AND job.status = 'SUCCEEDED'
    AND job.attempt_count = 1
    AND job.fencing_token = 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6c exact redelivery job reset failed';
  END IF;
END $$;

COMMIT;
\endif

\if :r6c_recursion_verify
BEGIN;
SET LOCAL TIME ZONE 'UTC';
SELECT set_config(
  'r6c.fixture.phase', :'r6c_recursion_phase', true
);
DO $$
DECLARE
  v_receipt ops.hypothesis_recursion_receipts%ROWTYPE;
  v_job ops.jobs%ROWTYPE;
  v_attempt_one ops.job_attempts%ROWTYPE;
  v_attempt_two ops.job_attempts%ROWTYPE;
  v_baseline jsonb;
  v_event_id uuid;
BEGIN
  IF current_setting('r6c.fixture.phase') <> 'verify_exact_redelivery' THEN
    RETURN;
  END IF;
  SELECT receipt.* INTO STRICT v_receipt
  FROM ops.hypothesis_recursion_receipts AS receipt
  JOIN ops.hypothesis_recursion_nodes AS node
    ON node.agent_run_id = receipt.trigger_id
  JOIN ops.hypothesis_recursion_plans AS plan
    ON plan.plan_id = node.plan_id
  JOIN ops.execution_authorizations AS execution_authorization
    ON execution_authorization.execution_id = plan.root_hypothesis_execution_id
   AND execution_authorization.generation =
     plan.root_hypothesis_execution_generation
  WHERE receipt.trigger_kind = 'AGENT_RUN'
    AND receipt.disposition = 'MAX_DEPTH_REACHED'
    AND execution_authorization.proposal_id =
      '31610000-0000-4000-8000-000000000004';
  SELECT job.* INTO STRICT v_job
  FROM ops.jobs AS job WHERE job.id = v_receipt.producer_job_id;
  SELECT attempt.* INTO STRICT v_attempt_one
  FROM ops.job_attempts AS attempt
  WHERE attempt.job_id = v_job.id AND attempt.attempt = 1;
  SELECT attempt.* INTO STRICT v_attempt_two
  FROM ops.job_attempts AS attempt
  WHERE attempt.job_id = v_job.id AND attempt.attempt = 2;
  v_baseline := v_attempt_one.metrics->'exactRedeliveryBaseline';
  v_event_id := (v_job.payload->>'eventId')::uuid;
  IF jsonb_typeof(v_baseline) IS DISTINCT FROM 'object'
     OR (v_baseline->>'receiptId')::uuid <> v_receipt.receipt_id
     OR v_baseline->>'receiptDigest' <>
       btrim(v_receipt.receipt_digest::text)
     OR (v_baseline->>'producerJobId')::uuid <> v_job.id
     OR (v_baseline->>'eventId')::uuid <> v_event_id
     OR (v_baseline->>'policies')::bigint <>
       (SELECT count(*) FROM ops.hypothesis_recursion_policies)
     OR (v_baseline->>'plans')::bigint <>
       (SELECT count(*) FROM ops.hypothesis_recursion_plans)
     OR (v_baseline->>'nodes')::bigint <>
       (SELECT count(*) FROM ops.hypothesis_recursion_nodes)
     OR (v_baseline->>'transitions')::bigint <>
       (SELECT count(*) FROM ops.hypothesis_recursion_transitions)
     OR (v_baseline->>'receipts')::bigint <>
       (SELECT count(*) FROM ops.hypothesis_recursion_receipts)
     OR (v_baseline->>'ledger')::bigint <>
       (SELECT count(*) FROM ops.hypothesis_recursion_budget_ledger)
     OR (v_baseline->>'agentRuns')::bigint <>
       (SELECT count(*) FROM ops.agent_runs)
     OR (v_baseline->>'jobs')::bigint <>
       (SELECT count(*) FROM ops.jobs)
     OR (v_baseline->>'outbox')::bigint <>
       (SELECT count(*) FROM ops.outbox)
     OR v_job.status <> 'SUCCEEDED'
     OR v_job.attempt_count <> 2
     OR v_job.fencing_token <> 2
     OR v_attempt_one.outcome <> 'SUCCEEDED'
     OR v_attempt_two.outcome <> 'SUCCEEDED'
     OR v_attempt_two.metrics#>>'{hypothesisRecursion,replayed}' <> 'true'
     OR v_attempt_two.metrics#>>'{hypothesisRecursion,triggerKind}' <>
       'AGENT_RUN'
     OR v_attempt_two.metrics#>>'{hypothesisRecursion,disposition}' <>
       'MAX_DEPTH_REACHED'
     OR (v_attempt_two.metrics#>>'{hypothesisRecursion,receiptId}')::uuid
       <> v_receipt.receipt_id
     OR v_attempt_two.metrics#>>'{hypothesisRecursion,receiptDigest}' <>
       btrim(v_receipt.receipt_digest::text)
     OR NOT EXISTS (
       SELECT 1 FROM ops.inbox AS inbox
       WHERE inbox.consumer = 'workflow-worker'
         AND inbox.event_id = v_event_id
         AND inbox.processed_at IS NOT NULL
         AND inbox.result = 'SUCCEEDED'
     ) THEN
    RAISE EXCEPTION 'R6c exact redelivery invariant invalid';
  END IF;
END $$;
COMMIT;
\endif

\if :r6c_recursion_verify
BEGIN;
SET LOCAL TIME ZONE 'UTC';
SELECT set_config(
  'r6c.fixture.phase', :'r6c_recursion_phase', true
);

-- Root-trigger verification is shared by the three fail-closed cases and the
-- two policies that are allowed to create a MARKET_RESEARCHER node.  It reads
-- the durable product receipts only; no owner table is mutated here.
DO $$
DECLARE
  v_phase text := current_setting('r6c.fixture.phase');
  v_proposal_id uuid := CASE current_setting('r6c.fixture.phase')
    WHEN 'verify_absent'
      THEN '31610000-0000-4000-8000-000000000001'::uuid
    WHEN 'verify_disabled'
      THEN '31610000-0000-4000-8000-000000000002'::uuid
    WHEN 'verify_case_budget'
      THEN '31610000-0000-4000-8000-000000000003'::uuid
    WHEN 'verify_max_depth_root'
      THEN '31610000-0000-4000-8000-000000000004'::uuid
    WHEN 'verify_happy_root'
      THEN '31610000-0000-4000-8000-000000000005'::uuid
    ELSE NULL
  END;
  v_expected_disposition text := CASE current_setting('r6c.fixture.phase')
    WHEN 'verify_absent' THEN 'POLICY_ABSENT'
    WHEN 'verify_disabled' THEN 'POLICY_DISABLED'
    WHEN 'verify_case_budget' THEN 'CASE_BUDGET_BLOCKED'
    WHEN 'verify_max_depth_root' THEN 'STARTED'
    WHEN 'verify_happy_root' THEN 'STARTED'
    ELSE NULL
  END;
  v_expected_policy_version bigint := CASE current_setting(
    'r6c.fixture.phase'
  )
    WHEN 'verify_disabled' THEN 1
    WHEN 'verify_case_budget' THEN 2
    WHEN 'verify_max_depth_root' THEN 3
    WHEN 'verify_happy_root' THEN 4
    ELSE NULL
  END;
  v_expected_max_depth integer := CASE current_setting(
    'r6c.fixture.phase'
  )
    WHEN 'verify_max_depth_root' THEN 1
    WHEN 'verify_happy_root' THEN 2
    ELSE NULL
  END;
  v_execution ops.execution_authorizations%ROWTYPE;
  v_effect ops.in_flight_effects%ROWTYPE;
  v_receipt ops.hypothesis_recursion_receipts%ROWTYPE;
  v_plan ops.hypothesis_recursion_plans%ROWTYPE;
  v_node ops.hypothesis_recursion_nodes%ROWTYPE;
  v_run ops.agent_runs%ROWTYPE;
  v_job ops.jobs%ROWTYPE;
BEGIN
  IF v_proposal_id IS NULL THEN
    RETURN;
  END IF;
  SELECT execution_authorization.* INTO STRICT v_execution
  FROM ops.execution_authorizations AS execution_authorization
  WHERE execution_authorization.proposal_id = v_proposal_id
    AND execution_authorization.proposal_version = 1
    AND execution_authorization.generation = 1
    AND execution_authorization.action_kind = 'HYPOTHESIS'
    AND execution_authorization.executor_id = 'createHypothesis';
  SELECT effect.* INTO STRICT v_effect
  FROM ops.in_flight_effects AS effect
  WHERE effect.id = v_execution.execution_id
    AND effect.current_generation = v_execution.generation;
  SELECT receipt.* INTO STRICT v_receipt
  FROM ops.hypothesis_recursion_receipts AS receipt
  WHERE receipt.trigger_kind = 'ACTION_EXECUTION'
    AND receipt.trigger_id = v_execution.execution_id
    AND receipt.trigger_generation = v_execution.generation;

  IF v_effect.state <> 'SUCCEEDED'
     OR v_effect.action_proposal_id <> v_proposal_id
     OR v_receipt.disposition IS DISTINCT FROM v_expected_disposition
     OR v_receipt.trigger_digest IS DISTINCT FROM encode(
       extensions.digest(ops.canonical_jsonb_v1(
         (SELECT event.payload
          FROM ops.outbox AS event
          WHERE event.id = (SELECT (job.payload->>'eventId')::uuid
            FROM ops.jobs AS job
            WHERE job.id = v_receipt.producer_job_id)
         )
       ), 'sha256'), 'hex'
     )
     OR v_receipt.receipt_digest IS DISTINCT FROM encode(
       extensions.digest(v_receipt.receipt_canonical, 'sha256'), 'hex'
     )
     OR convert_from(v_receipt.receipt_canonical, 'UTF8')::jsonb
       IS DISTINCT FROM v_receipt.receipt_payload
     OR v_receipt.actor_type <> 'SERVICE'
     OR v_receipt.actor_id <> 'workflow-worker'
     OR v_receipt.retention_record_class <>
       'AGENT_RUNTIME_INITIATION_RECEIPT'
     OR NOT EXISTS (
       SELECT 1
       FROM ops.jobs AS delivery
       JOIN ops.job_attempts AS attempt
         ON attempt.job_id = delivery.id
       JOIN ops.inbox AS inbox
         ON inbox.consumer = delivery.payload->>'consumerId'
        AND inbox.event_id = (delivery.payload->>'eventId')::uuid
       WHERE delivery.id = v_receipt.producer_job_id
         AND delivery.job_type = 'EVENT_DELIVERY'
         AND delivery.queue = 'workflow-worker'
         AND delivery.status = 'SUCCEEDED'
         AND delivery.payload->>'eventType' =
           'action.execution_completed.v1'
         AND delivery.payload->>'aggregateId' =
           v_execution.execution_id::text
         AND attempt.attempt = 1
         AND attempt.outcome = 'SUCCEEDED'
         AND attempt.finished_at IS NOT NULL
         AND inbox.processed_at IS NOT NULL
         AND inbox.result = 'SUCCEEDED'
     ) THEN
    RAISE EXCEPTION 'R6c root receipt invalid: %', v_phase;
  END IF;

  IF v_expected_disposition <> 'STARTED' THEN
    IF v_receipt.policy_version IS DISTINCT FROM v_expected_policy_version
       OR (v_expected_policy_version IS NULL
         AND v_receipt.policy_id IS NOT NULL)
       OR (v_expected_policy_version IS NOT NULL AND NOT EXISTS (
         SELECT 1
         FROM ops.hypothesis_recursion_policies AS policy
         WHERE policy.policy_id = v_receipt.policy_id
           AND policy.version = v_receipt.policy_version
       ))
       OR num_nonnulls(
         v_receipt.plan_id,v_receipt.node_id,
         v_receipt.agent_run_id,v_receipt.job_id
       ) <> 0
       OR EXISTS (
         SELECT 1 FROM ops.hypothesis_recursion_plans AS plan
         WHERE plan.root_hypothesis_execution_id = v_execution.execution_id
           AND plan.root_hypothesis_execution_generation =
             v_execution.generation
       ) THEN
      RAISE EXCEPTION 'R6c fail-closed root leaked work: %', v_phase;
    END IF;
    RETURN;
  END IF;

  IF num_nonnulls(
       v_receipt.plan_id,v_receipt.node_id,
       v_receipt.agent_run_id,v_receipt.job_id
     ) <> 4
     OR v_receipt.policy_version <> v_expected_policy_version THEN
    RAISE EXCEPTION 'R6c started root receipt incomplete: %', v_phase;
  END IF;
  SELECT plan.* INTO STRICT v_plan
  FROM ops.hypothesis_recursion_plans AS plan
  WHERE plan.plan_id = v_receipt.plan_id;
  SELECT node.* INTO STRICT v_node
  FROM ops.hypothesis_recursion_nodes AS node
  WHERE node.node_id = v_receipt.node_id;
  SELECT run.* INTO STRICT v_run
  FROM ops.agent_runs AS run
  WHERE run.id = v_receipt.agent_run_id;
  SELECT job.* INTO STRICT v_job
  FROM ops.jobs AS job
  WHERE job.id = v_receipt.job_id;
  IF v_plan.root_hypothesis_execution_id <> v_execution.execution_id
     OR v_plan.root_hypothesis_execution_generation <>
       v_execution.generation
     OR v_plan.root_hypothesis_execution_digest <>
       v_execution.execution_digest
     OR v_plan.policy_id <> v_receipt.policy_id
     OR v_plan.policy_version <> v_expected_policy_version
     OR v_plan.max_depth <> v_expected_max_depth
     OR v_plan.case_budget_micros_krw <> 3000000
     OR v_node.plan_id <> v_plan.plan_id
     OR v_node.parent_node_id IS NOT NULL
     OR v_node.parent_depth IS NOT NULL
     OR v_node.depth <> 1
     OR v_node.stage <> 'MARKET_RESEARCHER'
     OR v_node.dedupe_key_sha256 <> encode(extensions.digest(
       ops.canonical_jsonb_v1(jsonb_build_array(
         v_plan.case_id,
         btrim(v_plan.root_hypothesis_execution_digest::text),
         btrim(v_plan.snapshot_sha256::text),
         'MARKET_RESEARCHER',1
       )),'sha256'
     ),'hex')
     OR v_node.agent_run_id <> v_run.id
     OR v_node.job_id <> v_job.id
     OR v_node.reserved_micros_krw <> 2000000
     OR v_run.agent_type <> 'market-researcher'
     OR v_run.run_contract_version <> 2
     OR v_run.status <> 'QUEUED'
     OR v_run.control_state <> 'NONE'
     OR v_run.version <> 1
     OR v_run.max_micros_krw <> 2000000
     OR v_run.reserved_micros_krw <> 2000000
     OR v_job.job_type <> 'AGENT_RUN'
     OR v_job.queue <> 'analysis-worker'
     OR v_job.status <> 'QUEUED'
     OR v_job.payload->>'agentRunId' <> v_run.id::text
     OR (SELECT count(*)
         FROM ops.hypothesis_recursion_transitions AS transition
         WHERE transition.plan_id = v_plan.plan_id) <> 2
     OR (SELECT array_agg(transition.next_state
           ORDER BY transition.transition_sequence)
         FROM ops.hypothesis_recursion_transitions AS transition
         WHERE transition.plan_id = v_plan.plan_id)
       <> ARRAY['ACTIVE','QUEUED']::text[]
     OR (SELECT count(*)
         FROM ops.hypothesis_recursion_budget_ledger AS ledger
         WHERE ledger.plan_id = v_plan.plan_id
           AND ledger.entry_kind = 'RESERVE'
           AND ledger.amount_micros_krw = 2000000) <> 1
     OR EXISTS (
       SELECT 1 FROM ops.agent_runs AS claim_run
       WHERE claim_run.case_id = v_plan.case_id
         AND claim_run.agent_type = 'claim-drafter'
         AND claim_run.created_at >= v_plan.created_at
     ) THEN
    RAISE EXCEPTION 'R6c started recursion graph invalid: %', v_phase;
  END IF;
END $$;

DO $$
DECLARE
  v_phase text := current_setting('r6c.fixture.phase');
  v_proposal_id uuid := CASE current_setting('r6c.fixture.phase')
    WHEN 'verify_max_depth'
      THEN '31610000-0000-4000-8000-000000000004'::uuid
    WHEN 'verify_happy'
      THEN '31610000-0000-4000-8000-000000000005'::uuid
    ELSE NULL
  END;
  v_plan ops.hypothesis_recursion_plans%ROWTYPE;
  v_market ops.hypothesis_recursion_nodes%ROWTYPE;
  v_skeptic ops.hypothesis_recursion_nodes%ROWTYPE;
  v_market_receipt ops.hypothesis_recursion_receipts%ROWTYPE;
  v_skeptic_receipt ops.hypothesis_recursion_receipts%ROWTYPE;
BEGIN
  IF v_proposal_id IS NULL THEN
    RETURN;
  END IF;
  SELECT plan.* INTO STRICT v_plan
  FROM ops.hypothesis_recursion_plans AS plan
  JOIN ops.execution_authorizations AS execution_authorization
    ON execution_authorization.execution_id = plan.root_hypothesis_execution_id
   AND execution_authorization.generation =
     plan.root_hypothesis_execution_generation
  WHERE execution_authorization.proposal_id = v_proposal_id;
  SELECT node.* INTO STRICT v_market
  FROM ops.hypothesis_recursion_nodes AS node
  WHERE node.plan_id = v_plan.plan_id
    AND node.stage = 'MARKET_RESEARCHER' AND node.depth = 1;
  SELECT receipt.* INTO STRICT v_market_receipt
  FROM ops.hypothesis_recursion_receipts AS receipt
  WHERE receipt.trigger_kind = 'AGENT_RUN'
    AND receipt.trigger_id = v_market.agent_run_id
    AND receipt.trigger_generation = 2;
  IF NOT EXISTS (
       SELECT 1 FROM ops.agent_runs AS run
       WHERE run.id = v_market.agent_run_id
         AND run.status = 'SUCCEEDED'
         AND run.control_state = 'SETTLED'
         AND run.version = 3 AND run.actual_cost = 1.000000
     )
     OR v_market_receipt.policy_id <> v_plan.policy_id
     OR v_market_receipt.policy_version <> v_plan.policy_version
     OR v_market_receipt.receipt_digest IS DISTINCT FROM encode(
       extensions.digest(v_market_receipt.receipt_canonical,'sha256'),
       'hex'
     )
     OR NOT EXISTS (
       SELECT 1 FROM ops.jobs AS delivery
       JOIN ops.job_attempts AS attempt ON attempt.job_id = delivery.id
       JOIN ops.inbox AS inbox
         ON inbox.consumer = delivery.payload->>'consumerId'
        AND inbox.event_id = (delivery.payload->>'eventId')::uuid
       WHERE delivery.id = v_market_receipt.producer_job_id
         AND delivery.status = 'SUCCEEDED'
         AND delivery.payload->>'eventType' = 'agent.run_completed.v1'
         AND attempt.attempt = 1 AND attempt.outcome = 'SUCCEEDED'
         AND inbox.processed_at IS NOT NULL AND inbox.result = 'SUCCEEDED'
     ) THEN
    RAISE EXCEPTION 'R6c market stage authority invalid: %', v_phase;
  END IF;
  IF v_phase = 'verify_max_depth' THEN
    IF v_plan.policy_version <> 3 OR v_plan.max_depth <> 1
       OR v_market_receipt.disposition <> 'MAX_DEPTH_REACHED'
       OR num_nonnulls(
         v_market_receipt.plan_id,v_market_receipt.node_id,
         v_market_receipt.agent_run_id,v_market_receipt.job_id
       ) <> 0
       OR (SELECT array_agg(transition.next_state
             ORDER BY transition.transition_sequence)
           FROM ops.hypothesis_recursion_transitions AS transition
           WHERE transition.plan_id = v_plan.plan_id)
         <> ARRAY['ACTIVE','QUEUED','SUCCEEDED']::text[]
       OR (SELECT array_agg(ledger.entry_kind
             ORDER BY ledger.ledger_sequence)
           FROM ops.hypothesis_recursion_budget_ledger AS ledger
           WHERE ledger.plan_id = v_plan.plan_id)
         <> ARRAY['RESERVE','SETTLE','RELEASE']::text[]
       OR (SELECT count(*) FROM ops.hypothesis_recursion_nodes AS node
           WHERE node.plan_id = v_plan.plan_id) <> 1 THEN
      RAISE EXCEPTION 'R6c max-depth terminal invalid';
    END IF;
    RETURN;
  END IF;
  SELECT node.* INTO STRICT v_skeptic
  FROM ops.hypothesis_recursion_nodes AS node
  WHERE node.plan_id = v_plan.plan_id
    AND node.stage = 'SKEPTIC' AND node.depth = 2;
  SELECT receipt.* INTO STRICT v_skeptic_receipt
  FROM ops.hypothesis_recursion_receipts AS receipt
  WHERE receipt.trigger_kind = 'AGENT_RUN'
    AND receipt.trigger_id = v_skeptic.agent_run_id
    AND receipt.trigger_generation = 2;
  IF v_plan.policy_version <> 4 OR v_plan.max_depth <> 2
     OR v_market_receipt.disposition <> 'STARTED'
     OR v_market_receipt.node_id <> v_skeptic.node_id
     OR v_market_receipt.agent_run_id <> v_skeptic.agent_run_id
     OR v_market_receipt.job_id <> v_skeptic.job_id
     OR v_skeptic.parent_node_id <> v_market.node_id
     OR v_skeptic.parent_depth <> v_market.depth
     OR v_skeptic.dedupe_key_sha256 <> encode(extensions.digest(
       ops.canonical_jsonb_v1(jsonb_build_array(
         v_plan.case_id,
         btrim(v_plan.root_hypothesis_execution_digest::text),
         btrim(v_plan.snapshot_sha256::text),
         'SKEPTIC',2
       )),'sha256'
     ),'hex')
     OR v_skeptic_receipt.disposition <> 'PLAN_TERMINAL'
     OR num_nonnulls(
       v_skeptic_receipt.plan_id,v_skeptic_receipt.node_id,
       v_skeptic_receipt.agent_run_id,v_skeptic_receipt.job_id
     ) <> 0
     OR NOT EXISTS (
       SELECT 1 FROM ops.agent_runs AS run
       WHERE run.id = v_skeptic.agent_run_id
         AND run.agent_type = 'skeptic'
         AND run.status = 'SUCCEEDED'
         AND run.control_state = 'SETTLED'
         AND run.version = 3 AND run.actual_cost = 0.500000
     )
     OR (SELECT array_agg(transition.next_state
           ORDER BY transition.transition_sequence)
         FROM ops.hypothesis_recursion_transitions AS transition
         WHERE transition.plan_id = v_plan.plan_id)
       <> ARRAY[
         'ACTIVE','QUEUED','SUCCEEDED','QUEUED','SUCCEEDED',
         'REVIEWED_TERMINAL'
       ]::text[]
     OR (SELECT array_agg(ledger.entry_kind
           ORDER BY ledger.ledger_sequence)
         FROM ops.hypothesis_recursion_budget_ledger AS ledger
         WHERE ledger.plan_id = v_plan.plan_id)
       <> ARRAY[
         'RESERVE','SETTLE','RELEASE',
         'RESERVE','SETTLE','RELEASE'
       ]::text[]
     OR EXISTS (
       SELECT 1 FROM ops.agent_runs AS run
       WHERE run.case_id = v_plan.case_id
         AND run.agent_type = 'claim-drafter'
         AND run.created_at >= v_plan.created_at
     ) THEN
    RAISE EXCEPTION 'R6c happy recursion terminal invalid';
  END IF;
END $$;

DO $$
DECLARE
  v_root_proposal_ids constant uuid[] := ARRAY[
    '31610000-0000-4000-8000-000000000001'::uuid,
    '31610000-0000-4000-8000-000000000002'::uuid,
    '31610000-0000-4000-8000-000000000003'::uuid,
    '31610000-0000-4000-8000-000000000004'::uuid,
    '31610000-0000-4000-8000-000000000005'::uuid
  ];
  v_plan_proposal_ids constant uuid[] := ARRAY[
    '31610000-0000-4000-8000-000000000004'::uuid,
    '31610000-0000-4000-8000-000000000005'::uuid
  ];
  v_scoped_receipts bigint;
  v_started bigint;
  v_policy_absent bigint;
  v_policy_disabled bigint;
  v_case_budget_blocked bigint;
  v_max_depth_reached bigint;
  v_plan_terminal bigint;
  v_unrelated_receipts bigint;
  v_unrelated_budget_receipts bigint;
  v_unrelated_signal_receipts bigint;
  v_unrelated_signal_types text[];
  v_unrelated_origin_receipts bigint;
BEGIN
  IF current_setting('r6c.fixture.phase') <> 'final_verify' THEN
    RETURN;
  END IF;
  SELECT
    count(*),
    count(*) FILTER (WHERE receipt.disposition = 'STARTED'),
    count(*) FILTER (WHERE receipt.disposition = 'POLICY_ABSENT'),
    count(*) FILTER (WHERE receipt.disposition = 'POLICY_DISABLED'),
    count(*) FILTER (WHERE receipt.disposition = 'CASE_BUDGET_BLOCKED'),
    count(*) FILTER (WHERE receipt.disposition = 'MAX_DEPTH_REACHED'),
    count(*) FILTER (WHERE receipt.disposition = 'PLAN_TERMINAL')
  INTO
    v_scoped_receipts,v_started,v_policy_absent,v_policy_disabled,
    v_case_budget_blocked,v_max_depth_reached,v_plan_terminal
  FROM ops.hypothesis_recursion_receipts AS receipt
  WHERE (
    receipt.trigger_kind = 'ACTION_EXECUTION'
    AND EXISTS (
      SELECT 1
      FROM ops.execution_authorizations AS execution_authorization
      WHERE execution_authorization.execution_id = receipt.trigger_id
        AND execution_authorization.generation = receipt.trigger_generation
        AND execution_authorization.proposal_id = ANY(v_root_proposal_ids)
    )
  ) OR (
    receipt.trigger_kind = 'AGENT_RUN'
    AND EXISTS (
      SELECT 1
      FROM ops.hypothesis_recursion_nodes AS node
      JOIN ops.hypothesis_recursion_plans AS plan
        ON plan.plan_id = node.plan_id
      JOIN ops.execution_authorizations AS execution_authorization
        ON execution_authorization.execution_id =
          plan.root_hypothesis_execution_id
       AND execution_authorization.generation =
          plan.root_hypothesis_execution_generation
      WHERE node.agent_run_id = receipt.trigger_id
        AND execution_authorization.proposal_id = ANY(v_plan_proposal_ids)
    )
  );
  SELECT count(*) INTO v_unrelated_receipts
  FROM ops.hypothesis_recursion_receipts AS receipt
  WHERE NOT (
    (
      receipt.trigger_kind = 'ACTION_EXECUTION'
      AND EXISTS (
        SELECT 1
        FROM ops.execution_authorizations AS execution_authorization
        WHERE execution_authorization.execution_id = receipt.trigger_id
          AND execution_authorization.generation = receipt.trigger_generation
          AND execution_authorization.proposal_id = ANY(v_root_proposal_ids)
      )
    ) OR (
      receipt.trigger_kind = 'AGENT_RUN'
      AND EXISTS (
        SELECT 1
        FROM ops.hypothesis_recursion_nodes AS node
        JOIN ops.hypothesis_recursion_plans AS plan
          ON plan.plan_id = node.plan_id
        JOIN ops.execution_authorizations AS execution_authorization
          ON execution_authorization.execution_id =
            plan.root_hypothesis_execution_id
         AND execution_authorization.generation =
            plan.root_hypothesis_execution_generation
        WHERE node.agent_run_id = receipt.trigger_id
          AND execution_authorization.proposal_id = ANY(v_plan_proposal_ids)
      )
    )
  );
  SELECT count(*) INTO v_unrelated_budget_receipts
  FROM ops.hypothesis_recursion_receipts AS receipt
  JOIN ops.signal_investigation_initiation_receipts AS initiation
    ON initiation.agent_run_id = receipt.trigger_id
  JOIN core.anomaly_signals AS signal
    ON signal.id = initiation.signal_id
  JOIN ops.agent_runs AS run
    ON run.id = initiation.agent_run_id
  WHERE receipt.trigger_kind = 'AGENT_RUN'
    AND receipt.trigger_generation = 2
    AND receipt.disposition = 'NODE_NOT_RECURSIVE'
    AND signal.rule_version_id =
      '31300000-0000-4000-8000-000000000020'
    AND signal.signal_type = 'CONTRACT_AMENDMENT_ESCALATION'
    AND run.status = 'BUDGET_BLOCKED'
    AND run.control_state = 'SETTLED'
    AND run.version = 3
    AND receipt.trigger_receipt_sha256 = run.terminal_receipt_sha256
    AND num_nonnulls(
      receipt.plan_id,receipt.node_id,receipt.agent_run_id,receipt.job_id
    ) = 0
    AND receipt.actor_type = 'SERVICE'
    AND receipt.actor_id = 'workflow-worker'
    AND receipt.receipt_digest = encode(
      extensions.digest(receipt.receipt_canonical,'sha256'),'hex'
    );
  SELECT count(*),array_agg(signal.signal_type ORDER BY signal.signal_type)
  INTO v_unrelated_signal_receipts,v_unrelated_signal_types
  FROM ops.hypothesis_recursion_receipts AS receipt
  JOIN ops.signal_investigation_initiation_receipts AS initiation
    ON initiation.agent_run_id = receipt.trigger_id
  JOIN core.anomaly_signals AS signal
    ON signal.id = initiation.signal_id
  JOIN ops.agent_runs AS run
    ON run.id = initiation.agent_run_id
  WHERE receipt.trigger_kind = 'AGENT_RUN'
    AND receipt.trigger_generation = 2
    AND receipt.disposition = 'NODE_NOT_RECURSIVE'
    AND signal.rule_version_id =
      '31300000-0000-4000-8000-000000000020'
    AND signal.signal_type IN (
      'CONTRACT_AMENDMENT_ESCALATION','R6B2_BUDGET_SEED'
    )
    AND initiation.disposition = 'STARTED'
    AND run.status = 'BUDGET_BLOCKED'
    AND run.control_state = 'SETTLED'
    AND run.version = 3
    AND receipt.trigger_receipt_sha256 = run.terminal_receipt_sha256
    AND num_nonnulls(
      receipt.plan_id,receipt.node_id,receipt.agent_run_id,receipt.job_id
    ) = 0
    AND receipt.actor_type = 'SERVICE'
    AND receipt.actor_id = 'workflow-worker'
    AND receipt.receipt_digest = encode(
      extensions.digest(receipt.receipt_canonical,'sha256'),'hex'
    );
  SELECT count(*) INTO v_unrelated_origin_receipts
  FROM ops.hypothesis_recursion_receipts AS receipt
  JOIN ops.agent_runs AS run ON run.id = receipt.trigger_id
  WHERE receipt.trigger_kind = 'AGENT_RUN'
    AND receipt.trigger_id = '31600000-0000-4000-8000-000000000010'
    AND receipt.trigger_generation = 2
    AND receipt.disposition = 'NODE_NOT_RECURSIVE'
    AND run.status = 'SUCCEEDED'
    AND run.control_state = 'SETTLED'
    AND run.version = 3
    AND receipt.trigger_receipt_sha256 = run.terminal_receipt_sha256
    AND num_nonnulls(
      receipt.plan_id,receipt.node_id,receipt.agent_run_id,receipt.job_id
    ) = 0
    AND receipt.actor_type = 'SERVICE'
    AND receipt.actor_id = 'workflow-worker'
    AND receipt.receipt_digest = encode(
      extensions.digest(receipt.receipt_canonical,'sha256'),'hex'
    );
  IF (SELECT count(*) FROM ops.hypothesis_recursion_policies) <> 4
     OR (SELECT count(*) FROM ops.hypothesis_recursion_plans) <> 2
     OR (SELECT count(*) FROM ops.hypothesis_recursion_nodes) <> 3
     OR v_scoped_receipts <> 8
     OR v_unrelated_receipts <> 3
     OR v_unrelated_budget_receipts <> 1
     OR v_unrelated_signal_receipts <> 2
     OR v_unrelated_signal_types IS DISTINCT FROM ARRAY[
       'CONTRACT_AMENDMENT_ESCALATION','R6B2_BUDGET_SEED'
     ]::text[]
     OR v_unrelated_origin_receipts <> 1
     OR (SELECT count(*) FROM ops.hypothesis_recursion_transitions) <> 9
     OR (SELECT count(*)
         FROM ops.hypothesis_recursion_budget_ledger) <> 9
     OR v_started <> 3
     OR v_policy_absent <> 1
     OR v_policy_disabled <> 1
     OR v_case_budget_blocked <> 1
     OR v_max_depth_reached <> 1
     OR v_plan_terminal <> 1
     OR EXISTS (
       SELECT 1 FROM ops.hypothesis_recursion_receipts AS receipt
       WHERE (
         (
           receipt.trigger_kind = 'ACTION_EXECUTION'
           AND EXISTS (
             SELECT 1
             FROM ops.execution_authorizations AS execution_authorization
             WHERE execution_authorization.execution_id = receipt.trigger_id
               AND execution_authorization.generation = receipt.trigger_generation
               AND execution_authorization.proposal_id = ANY(v_root_proposal_ids)
           )
         ) OR (
           receipt.trigger_kind = 'AGENT_RUN'
           AND EXISTS (
             SELECT 1
             FROM ops.hypothesis_recursion_nodes AS node
             JOIN ops.hypothesis_recursion_plans AS plan
               ON plan.plan_id = node.plan_id
             JOIN ops.execution_authorizations AS execution_authorization
               ON execution_authorization.execution_id =
                 plan.root_hypothesis_execution_id
              AND execution_authorization.generation =
                 plan.root_hypothesis_execution_generation
             WHERE node.agent_run_id = receipt.trigger_id
               AND execution_authorization.proposal_id = ANY(v_plan_proposal_ids)
           )
         )
       ) AND (
         receipt.receipt_digest IS DISTINCT FROM encode(
           extensions.digest(receipt.receipt_canonical,'sha256'),'hex'
         ) OR receipt.actor_type <> 'SERVICE'
           OR receipt.actor_id <> 'workflow-worker'
       )
     )
     OR EXISTS (
       SELECT 1 FROM ops.agent_runs AS run
     JOIN ops.hypothesis_recursion_nodes AS node
         ON node.agent_run_id = run.id
       WHERE run.created_actor_type <> 'SERVICE'
          OR run.created_service <> 'workflow-worker'
          OR run.status <> 'SUCCEEDED'
          OR run.control_state <> 'SETTLED'
     ) THEN
    RAISE EXCEPTION
      'R6c recursion final invariant invalid: policies %, plans %, nodes %, scoped %, unrelated %, unrelated_budget %, unrelated_signal %/%, unrelated_origin %, transitions %, ledger %, started %, absent %, disabled %, case_budget %, max_depth %, terminal %',
      (SELECT count(*) FROM ops.hypothesis_recursion_policies),
      (SELECT count(*) FROM ops.hypothesis_recursion_plans),
      (SELECT count(*) FROM ops.hypothesis_recursion_nodes),
      v_scoped_receipts,v_unrelated_receipts,v_unrelated_budget_receipts,
      v_unrelated_signal_receipts,v_unrelated_signal_types,
      v_unrelated_origin_receipts,
      (SELECT count(*) FROM ops.hypothesis_recursion_transitions),
      (SELECT count(*) FROM ops.hypothesis_recursion_budget_ledger),
      v_started,v_policy_absent,v_policy_disabled,v_case_budget_blocked,
      v_max_depth_reached,v_plan_terminal;
  END IF;
END $$;

COMMIT;
\endif

\if :r6c_recursion_policy
BEGIN;
SET LOCAL TIME ZONE 'UTC';
SELECT set_config(
  'r6c.fixture.phase', :'r6c_recursion_phase', true
);

-- TEST_FIXTURE_ONLY immutable policy sequence.  No version is installed by a
-- migration or activated outside this disposable runtime database.  Values
-- are deliberately cumulative so each execution observes exactly one newest
-- authority: disabled, root budget blocked, max-depth terminal, then the
-- approved happy-path budget/depth contract.
DO $$
DECLARE
  v_phase text := current_setting('r6c.fixture.phase');
  v_policy_id uuid := CASE current_setting('r6c.fixture.phase')
    WHEN 'policy_disabled'
      THEN '31630000-0000-4000-8000-000000000001'::uuid
    WHEN 'policy_case_budget'
      THEN '31630000-0000-4000-8000-000000000002'::uuid
    WHEN 'policy_max_depth'
      THEN '31630000-0000-4000-8000-000000000003'::uuid
    WHEN 'policy_happy'
      THEN '31630000-0000-4000-8000-000000000004'::uuid
  END;
  v_version bigint := CASE current_setting('r6c.fixture.phase')
    WHEN 'policy_disabled' THEN 1
    WHEN 'policy_case_budget' THEN 2
    WHEN 'policy_max_depth' THEN 3
    WHEN 'policy_happy' THEN 4
  END;
  v_enabled boolean :=
    current_setting('r6c.fixture.phase') <> 'policy_disabled';
  v_max_depth integer := CASE current_setting('r6c.fixture.phase')
    WHEN 'policy_max_depth' THEN 1
    ELSE 2
  END;
  v_case_budget bigint := CASE current_setting('r6c.fixture.phase')
    WHEN 'policy_case_budget' THEN 1000000
    ELSE 3000000
  END;
  v_market_budget constant bigint := 2000000;
  v_skeptic_budget constant bigint := 1000000;
  v_provider_policy_version constant text :=
    'r6c-recursion-provider-policy-v1';
  v_provider_policy_sha char(64) := encode(extensions.digest(
    convert_to(v_provider_policy_version, 'UTF8'), 'sha256'
  ), 'hex');
  v_budget_policy_version constant text :=
    'r6c-recursion-budget-policy-v1';
  v_budget_policy_sha char(64) := encode(extensions.digest(
    convert_to(v_budget_policy_version, 'UTF8'), 'sha256'
  ), 'hex');
  v_market_prompt_id constant text := 'r6c-recursion-market-researcher';
  v_market_prompt_version constant text := 'v1';
  v_market_prompt_sha char(64) := encode(extensions.digest(convert_to(
    v_market_prompt_id || ':' || v_market_prompt_version, 'UTF8'
  ), 'sha256'), 'hex');
  v_market_schema_id constant text := 'MarketResearcherOutputV1';
  v_market_schema_version constant text := 'market-researcher-output.v1';
  v_market_schema_sha char(64) := encode(extensions.digest(convert_to(
    v_market_schema_id || ':' || v_market_schema_version, 'UTF8'
  ), 'sha256'), 'hex');
  v_skeptic_prompt_id constant text := 'r6c-recursion-skeptic';
  v_skeptic_prompt_version constant text := 'v1';
  v_skeptic_prompt_sha char(64) := encode(extensions.digest(convert_to(
    v_skeptic_prompt_id || ':' || v_skeptic_prompt_version, 'UTF8'
  ), 'sha256'), 'hex');
  v_skeptic_schema_id constant text := 'SkepticOutputV1';
  v_skeptic_schema_version constant text := 'skeptic-output.v1';
  v_skeptic_schema_sha char(64) := encode(extensions.digest(convert_to(
    v_skeptic_schema_id || ':' || v_skeptic_schema_version, 'UTF8'
  ), 'sha256'), 'hex');
  v_created_by constant uuid :=
    '00000000-0000-4000-8000-000000000317';
  v_policy_payload jsonb;
  v_policy_canonical bytea;
  v_policy_digest char(64);
  v_inserted ops.hypothesis_recursion_policies%ROWTYPE;
BEGIN
  IF v_policy_id IS NULL OR v_version IS NULL
     OR (SELECT count(*) FROM ops.hypothesis_recursion_policies)
       <> v_version - 1
     OR COALESCE((
       SELECT max(version) FROM ops.hypothesis_recursion_policies
     ), 0) <> v_version - 1 THEN
    RAISE EXCEPTION 'R6c recursion policy phase order invalid: %', v_phase;
  END IF;
  v_policy_payload := jsonb_build_object(
    'schemaVersion','hypothesis-recursion-policy.v1',
    'policyId',v_policy_id,
    'policyKey','HYPOTHESIS_RECURSION',
    'version',v_version,
    'enabled',v_enabled,
    'maxDepth',v_max_depth,
    'caseBudgetMicrosKrw',v_case_budget,
    'marketResearcherStageBudgetMicrosKrw',v_market_budget,
    'skepticStageBudgetMicrosKrw',v_skeptic_budget,
    'providerPolicyVersion',v_provider_policy_version,
    'providerPolicySha256',btrim(v_provider_policy_sha::text),
    'providerClassification','PUBLIC',
    'providerCandidateIds',jsonb_build_array('r6c-deterministic-double'),
    'budgetPolicyVersion',v_budget_policy_version,
    'budgetPolicySha256',btrim(v_budget_policy_sha::text),
    'maxProviderTurns',1,
    'maxToolCalls',0,
    'deadlineInterval',(interval '1 hour')::text,
    'marketResearcherPromptId',v_market_prompt_id,
    'marketResearcherPromptVersion',v_market_prompt_version,
    'marketResearcherPromptSha256',btrim(v_market_prompt_sha::text),
    'marketResearcherOutputSchemaId',v_market_schema_id,
    'marketResearcherOutputSchemaVersion',v_market_schema_version,
    'marketResearcherOutputSchemaSha256',btrim(v_market_schema_sha::text),
    'skepticPromptId',v_skeptic_prompt_id,
    'skepticPromptVersion',v_skeptic_prompt_version,
    'skepticPromptSha256',btrim(v_skeptic_prompt_sha::text),
    'skepticOutputSchemaId',v_skeptic_schema_id,
    'skepticOutputSchemaVersion',v_skeptic_schema_version,
    'skepticOutputSchemaSha256',btrim(v_skeptic_schema_sha::text),
    'createdBy',v_created_by
  );
  v_policy_canonical := ops.canonical_jsonb_v1(v_policy_payload);
  v_policy_digest := encode(
    extensions.digest(v_policy_canonical, 'sha256'), 'hex'
  );
  INSERT INTO ops.hypothesis_recursion_policies(
    policy_id,policy_key,version,enabled,max_depth,
    case_budget_micros_krw,
    market_researcher_stage_budget_micros_krw,
    skeptic_stage_budget_micros_krw,
    provider_policy_version,provider_policy_sha256,
    provider_classification,provider_candidate_ids,
    budget_policy_version,budget_policy_sha256,
    max_provider_turns,max_tool_calls,deadline_interval,
    market_researcher_prompt_id,market_researcher_prompt_version,
    market_researcher_prompt_sha256,
    market_researcher_output_schema_id,
    market_researcher_output_schema_version,
    market_researcher_output_schema_sha256,
    skeptic_prompt_id,skeptic_prompt_version,skeptic_prompt_sha256,
    skeptic_output_schema_id,skeptic_output_schema_version,
    skeptic_output_schema_sha256,created_by,
    policy_canonical,policy_digest
  ) VALUES (
    v_policy_id,'HYPOTHESIS_RECURSION',v_version,v_enabled,v_max_depth,
    v_case_budget,v_market_budget,v_skeptic_budget,
    v_provider_policy_version,v_provider_policy_sha,'PUBLIC',
    ARRAY['r6c-deterministic-double']::text[],
    v_budget_policy_version,v_budget_policy_sha,1,0,interval '1 hour',
    v_market_prompt_id,v_market_prompt_version,v_market_prompt_sha,
    v_market_schema_id,v_market_schema_version,v_market_schema_sha,
    v_skeptic_prompt_id,v_skeptic_prompt_version,v_skeptic_prompt_sha,
    v_skeptic_schema_id,v_skeptic_schema_version,v_skeptic_schema_sha,
    v_created_by,v_policy_canonical,v_policy_digest
  ) RETURNING * INTO STRICT v_inserted;
  IF v_inserted.policy_canonical IS DISTINCT FROM v_policy_canonical
     OR v_inserted.policy_digest IS DISTINCT FROM v_policy_digest
     OR v_inserted.retention_record_class IS DISTINCT FROM
       'AGENT_RUNTIME_POLICY'
     OR v_inserted.retention_schedule_id IS NULL
     OR v_inserted.retention_schedule_digest IS NULL THEN
    RAISE EXCEPTION 'R6c recursion policy authority invalid: %', v_phase;
  END IF;
END $$;

COMMIT;
\endif

\if :r6c_recursion_approve
\if :{?r6c_payload_encrypted_base64}
\else
\echo 'r6c_payload_encrypted_base64 is required for approval phases'
\quit 1
\endif
\if :{?r6c_rationale_encrypted_base64}
\else
\echo 'r6c_rationale_encrypted_base64 is required for approval phases'
\quit 1
\endif

BEGIN;
SET LOCAL TIME ZONE 'UTC';
SELECT set_config(
  'r6c.fixture.phase', :'r6c_recursion_phase', true
);
SELECT set_config(
  'r6c.fixture.payload_encrypted_base64',
  :'r6c_payload_encrypted_base64', true
);
SELECT set_config(
  'r6c.fixture.rationale_encrypted_base64',
  :'r6c_rationale_encrypted_base64', true
);

SET LOCAL ROLE gurine_control_api;
DO $$
DECLARE
  v_phase text := current_setting('r6c.fixture.phase');
  v_ordinal integer := CASE current_setting('r6c.fixture.phase')
    WHEN 'approve_absent' THEN 1
    WHEN 'approve_disabled' THEN 2
    WHEN 'approve_case_budget' THEN 3
    WHEN 'approve_max_depth' THEN 4
    WHEN 'approve_happy' THEN 5
    WHEN 'approve_stale_case' THEN 6
  END;
  v_proposal_id uuid := CASE current_setting('r6c.fixture.phase')
    WHEN 'approve_absent'
      THEN '31610000-0000-4000-8000-000000000001'::uuid
    WHEN 'approve_disabled'
      THEN '31610000-0000-4000-8000-000000000002'::uuid
    WHEN 'approve_case_budget'
      THEN '31610000-0000-4000-8000-000000000003'::uuid
    WHEN 'approve_max_depth'
      THEN '31610000-0000-4000-8000-000000000004'::uuid
    WHEN 'approve_happy'
      THEN '31610000-0000-4000-8000-000000000005'::uuid
    WHEN 'approve_stale_case'
      THEN '31610000-0000-4000-8000-000000000006'::uuid
  END;
  v_actor constant uuid :=
    '00000000-0000-4000-8000-000000000317';
  v_reviewer constant uuid :=
    '00000000-0000-4000-8000-000000000316';
  v_suggestion ops.agent_suggestions%ROWTYPE;
  v_case editorial.cases%ROWTYPE;
  v_reason text := 'TEST_FIXTURE_ONLY ' || v_phase || ' acceptance';
  v_audit_id uuid;
  v_audit_request_id uuid := gen_random_uuid();
  v_object_scope_digest char(64);
  v_draft jsonb;
  v_create_request jsonb;
  v_create_receipt jsonb;
  v_preview_receipt jsonb;
  v_submit_receipt jsonb;
  v_claim_receipt jsonb;
  v_assignment_id uuid;
  v_approval_digest char(64);
  v_updated bigint;
BEGIN
  SELECT suggestion.* INTO STRICT v_suggestion
  FROM ops.agent_suggestions AS suggestion
  WHERE suggestion.agent_run_id =
      '31600000-0000-4000-8000-000000000010'
    AND suggestion.suggestion_type = 'HYPOTHESIS'
  ORDER BY suggestion.id
  OFFSET (v_ordinal - 1) LIMIT 1;
  IF v_suggestion.status <> 'PENDING' OR v_suggestion.version <> 1 THEN
    RAISE EXCEPTION 'R6c approval suggestion state invalid: %', v_phase;
  END IF;
  SELECT current_case.* INTO STRICT v_case
  FROM editorial.cases AS current_case
  WHERE current_case.id = v_suggestion.case_id;

  v_audit_id := ops.append_audit_event(
    'r6c-recursion-accept:' || v_suggestion.id::text,
    'USER', v_actor::text, NULL,
    'AGENT_SUGGESTION_ACCEPTED', 'AgentSuggestion',
    v_suggestion.id::text, 'agents.review', 'SUCCESS', v_reason,
    v_audit_request_id, jsonb_build_object(
      'suggestionId', v_suggestion.id,
      'version', v_suggestion.version,
      'payloadSha256', btrim(v_suggestion.payload_sha256),
      'decision', 'ACCEPT',
      'reason', v_reason
    )
  );
  v_object_scope_digest := encode(extensions.digest(
    convert_to(v_case.id::text, 'UTF8'), 'sha256'
  ), 'hex');
  v_draft := jsonb_build_object(
    'kind', 'HYPOTHESIS',
    'target', jsonb_build_object(
      'type', 'CASE', 'id', v_case.id, 'version', v_case.version,
      'digest', btrim(v_suggestion.input_snapshot_sha256)
    ),
    'objectScopeDigest', btrim(v_object_scope_digest),
    'contentDigest', btrim(v_suggestion.payload_sha256),
    'proposal', v_suggestion.payload
  );
  v_create_request := jsonb_build_object(
    '_proposalId', v_proposal_id,
    '_payloadEncryptedBase64', current_setting(
      'r6c.fixture.payload_encrypted_base64'
    ),
    '_rationaleEncryptedBase64', current_setting(
      'r6c.fixture.rationale_encrypted_base64'
    ),
    'actionKind', 'HYPOTHESIS',
    'origin', jsonb_build_object(
      'kind', 'AGENT_PROPOSAL', 'id', v_suggestion.id,
      'version', v_suggestion.version,
      'digest', btrim(v_suggestion.payload_sha256)
    ),
    'rationale', v_reason,
    'draft', v_draft
  );
  v_create_receipt := ops.execute_action_approval_v1(
    'createActionProposal', v_create_request, v_actor
  );
  IF v_create_receipt->>'proposalId' IS DISTINCT FROM v_proposal_id::text
     OR v_create_receipt->>'state' IS DISTINCT FROM 'DRAFT'
     OR v_create_receipt->>'actionKind' IS DISTINCT FROM 'HYPOTHESIS'
     OR COALESCE(v_create_receipt->>'contentDigest', '')
       !~ '^[0-9a-f]{64}$'
     OR COALESCE(v_create_receipt->>'receiptDigest', '')
       !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'R6c create proposal receipt invalid: %', v_phase;
  END IF;
  UPDATE ops.agent_suggestions AS suggestion
  SET status = 'ACCEPTED', decision_reason = v_reason,
      decided_by = v_actor, decided_at = clock_timestamp(),
      version = suggestion.version + 1, decision_kind = 'ACCEPT',
      decision_sha256 = encode(extensions.digest(convert_to(
        'ACCEPT:' || suggestion.id::text || ':'
          || suggestion.version::text || ':' || v_reason,
        'UTF8'
      ), 'sha256'), 'hex'),
      decision_audit_event_id = v_audit_id,
      materialized_target_type = 'ACTION_PROPOSAL_DRAFT',
      materialized_target_id = v_proposal_id,
      materialized_target_version = 1,
      materialized_target_digest = v_create_receipt->>'contentDigest',
      materialized_action_proposal_id = v_proposal_id,
      materialization_receipt_sha256 = v_create_receipt->>'receiptDigest'
  WHERE suggestion.id = v_suggestion.id
    AND suggestion.version = v_suggestion.version;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated <> 1 THEN
    RAISE EXCEPTION 'R6c suggestion acceptance fence stale: %', v_phase;
  END IF;

  v_preview_receipt := ops.execute_action_approval_v1(
    'previewActionDraft', jsonb_build_object(
      'proposalId', v_proposal_id,
      'expectedVersion', 1,
      'expectedContentDigest', v_create_receipt->>'contentDigest'
    ), v_actor
  );
  v_submit_receipt := ops.execute_action_approval_v1(
    'submitActionForReview', jsonb_build_object(
      'proposalId', v_proposal_id,
      'expectedVersion', 1,
      'expectedContentDigest', v_create_receipt->>'contentDigest',
      'previewId', v_preview_receipt->>'previewId',
      'previewDigest', v_preview_receipt->>'previewDigest'
    ), v_actor
  );
  v_assignment_id := (v_submit_receipt->'assignmentIds'->>0)::uuid;
  v_approval_digest := (v_submit_receipt->>'approvalDigest')::char(64);
  IF v_assignment_id IS NULL OR v_approval_digest IS NULL THEN
    RAISE EXCEPTION 'R6c HYPOTHESIS reviewer receipt invalid: %', v_phase;
  END IF;
  PERFORM set_config(
    'r6c.fixture.assignment_id', v_assignment_id::text, true
  );
  PERFORM set_config(
    'r6c.fixture.approval_digest', btrim(v_approval_digest), true
  );
  v_claim_receipt := ops.execute_action_approval_v1(
    'claimActionReview', jsonb_build_object(
      'proposalId', v_proposal_id,
      'assignmentId', v_assignment_id,
      'expectedProposalVersion', 1,
      'expectedAssignmentVersion', 1,
      'expectedApprovalDigest', btrim(v_approval_digest),
      'actionKind', 'HYPOTHESIS'
    ), v_reviewer
  );
  IF v_claim_receipt->>'state' IS DISTINCT FROM 'IN_PROGRESS'
     OR (v_claim_receipt->>'version')::bigint <> 2 THEN
    RAISE EXCEPTION 'R6c HYPOTHESIS claim invalid: %', v_phase;
  END IF;
  PERFORM set_config(
    'r6c.fixture.assignment_version', v_claim_receipt->>'version', true
  );
END $$;
RESET ROLE;

-- Step-up authorization is an Identity-owned boundary in production.  The
-- disposable fixture creates the same bounded row only after the assignment
-- exists, then returns to the Control API role for the decision owner call.
DO $$
DECLARE
  v_phase text := current_setting('r6c.fixture.phase');
  v_ordinal integer := CASE current_setting('r6c.fixture.phase')
    WHEN 'approve_absent' THEN 1
    WHEN 'approve_disabled' THEN 2
    WHEN 'approve_case_budget' THEN 3
    WHEN 'approve_max_depth' THEN 4
    WHEN 'approve_happy' THEN 5
    WHEN 'approve_stale_case' THEN 6
  END;
  v_proposal_id uuid := CASE current_setting('r6c.fixture.phase')
    WHEN 'approve_absent'
      THEN '31610000-0000-4000-8000-000000000001'::uuid
    WHEN 'approve_disabled'
      THEN '31610000-0000-4000-8000-000000000002'::uuid
    WHEN 'approve_case_budget'
      THEN '31610000-0000-4000-8000-000000000003'::uuid
    WHEN 'approve_max_depth'
      THEN '31610000-0000-4000-8000-000000000004'::uuid
    WHEN 'approve_happy'
      THEN '31610000-0000-4000-8000-000000000005'::uuid
    WHEN 'approve_stale_case'
      THEN '31610000-0000-4000-8000-000000000006'::uuid
  END;
  v_step_up_id uuid := CASE current_setting('r6c.fixture.phase')
    WHEN 'approve_absent'
      THEN '31620000-0000-4000-8000-000000000001'::uuid
    WHEN 'approve_disabled'
      THEN '31620000-0000-4000-8000-000000000002'::uuid
    WHEN 'approve_case_budget'
      THEN '31620000-0000-4000-8000-000000000003'::uuid
    WHEN 'approve_max_depth'
      THEN '31620000-0000-4000-8000-000000000004'::uuid
    WHEN 'approve_happy'
      THEN '31620000-0000-4000-8000-000000000005'::uuid
    WHEN 'approve_stale_case'
      THEN '31620000-0000-4000-8000-000000000006'::uuid
  END;
  v_assignment ops.action_review_assignments%ROWTYPE;
  v_action_digest char(64);
  v_idempotency_digest char(64);
BEGIN
  SELECT assignment.* INTO STRICT v_assignment
  FROM ops.action_review_assignments AS assignment
  WHERE assignment.id =
      current_setting('r6c.fixture.assignment_id')::uuid
    AND assignment.proposal_id = v_proposal_id
    AND assignment.slot_id = 'primary';
  IF v_assignment.reviewer_id IS DISTINCT FROM
       '00000000-0000-4000-8000-000000000316'::uuid
     OR v_assignment.allowed_role_codes IS DISTINCT FROM
       ARRAY['EXECUTIVE_APPROVER']::text[]
     OR v_assignment.approve_assurance IS DISTINCT FROM 'STEP_UP'
     OR v_assignment.required_capability IS DISTINCT FROM 'actions.review'
     OR v_assignment.version IS DISTINCT FROM
       current_setting('r6c.fixture.assignment_version')::bigint
     OR v_assignment.version <> 2
     OR v_assignment.state <> 'IN_PROGRESS'
     OR btrim(v_assignment.approval_digest) IS DISTINCT FROM
       current_setting('r6c.fixture.approval_digest') THEN
    RAISE EXCEPTION 'R6c step-up assignment state invalid: %', v_phase;
  END IF;
  v_action_digest := encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion', 'action-review-step-up.v1',
      'proposalId', v_proposal_id,
      'proposalVersion', 1,
      'approvalDigest', btrim(v_assignment.approval_digest),
      'assignmentId', v_assignment.id,
      'assignmentVersion', v_assignment.version,
      'assignmentGeneration', v_assignment.assignment_generation,
      'slotKind', v_assignment.slot_id,
      'decisionKind', 'APPROVE'
    )), 'sha256'
  ), 'hex');
  v_idempotency_digest := encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'fixtureAuthority', 'TEST_FIXTURE_ONLY',
      'phase', v_phase,
      'proposalId', v_proposal_id,
      'stepUpOrdinal', v_ordinal
    )), 'sha256'
  ), 'hex');
  INSERT INTO ops.step_up_authorizations(
    id, session_id, action_digest, idempotency_key_sha256,
    authorization_token_hash, expires_at, assertion_issue_count,
    max_assertion_issues, created_at, last_issued_at
  ) VALUES (
    v_step_up_id, '31600000-0000-4000-8000-000000000092',
    v_action_digest, v_idempotency_digest,
    encode(extensions.digest(convert_to(
      v_step_up_id::text || ':TEST_FIXTURE_ONLY', 'UTF8'
    ), 'sha256'), 'hex'),
    clock_timestamp() + interval '4 minutes', 1, 3,
    clock_timestamp() - interval '2 seconds',
    clock_timestamp() - interval '1 second'
  );
  PERFORM set_config(
    'r6c.fixture.step_up_action_digest', btrim(v_action_digest), true
  );
  PERFORM set_config(
    'r6c.fixture.step_up_idempotency_digest',
    btrim(v_idempotency_digest), true
  );
END $$;

-- A sixth, dedicated proposal preserves the reviewed pre-decision state while
-- a concurrent case version advances.  This direct version tick exists only
-- in the disposable fixture and is the concurrency stimulus; the decision is
-- still attempted solely through the public Control owner wrapper.
DO $$
DECLARE
  v_proposal ops.action_proposals%ROWTYPE;
BEGIN
  IF current_setting('r6c.fixture.phase') <> 'approve_stale_case' THEN
    RETURN;
  END IF;
  SELECT proposal.* INTO STRICT v_proposal
  FROM ops.action_proposals AS proposal
  WHERE proposal.id = '31610000-0000-4000-8000-000000000006';
  UPDATE editorial.cases AS current_case
  SET version = current_case.version + 1,
      updated_at = clock_timestamp()
  WHERE current_case.id = v_proposal.target_id::uuid
    AND current_case.version = v_proposal.target_version;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6c stale case concurrency stimulus invalid';
  END IF;
END $$;

SET LOCAL ROLE gurine_control_api;
DO $$
DECLARE
  v_phase text := current_setting('r6c.fixture.phase');
  v_proposal_id uuid := CASE current_setting('r6c.fixture.phase')
    WHEN 'approve_absent'
      THEN '31610000-0000-4000-8000-000000000001'::uuid
    WHEN 'approve_disabled'
      THEN '31610000-0000-4000-8000-000000000002'::uuid
    WHEN 'approve_case_budget'
      THEN '31610000-0000-4000-8000-000000000003'::uuid
    WHEN 'approve_max_depth'
      THEN '31610000-0000-4000-8000-000000000004'::uuid
    WHEN 'approve_happy'
      THEN '31610000-0000-4000-8000-000000000005'::uuid
    WHEN 'approve_stale_case'
      THEN '31610000-0000-4000-8000-000000000006'::uuid
  END;
  v_step_up_id uuid := CASE current_setting('r6c.fixture.phase')
    WHEN 'approve_absent'
      THEN '31620000-0000-4000-8000-000000000001'::uuid
    WHEN 'approve_disabled'
      THEN '31620000-0000-4000-8000-000000000002'::uuid
    WHEN 'approve_case_budget'
      THEN '31620000-0000-4000-8000-000000000003'::uuid
    WHEN 'approve_max_depth'
      THEN '31620000-0000-4000-8000-000000000004'::uuid
    WHEN 'approve_happy'
      THEN '31620000-0000-4000-8000-000000000005'::uuid
    WHEN 'approve_stale_case'
      THEN '31620000-0000-4000-8000-000000000006'::uuid
  END;
  v_reviewer constant uuid :=
    '00000000-0000-4000-8000-000000000316';
  v_assignment_id uuid :=
    current_setting('r6c.fixture.assignment_id')::uuid;
  v_assignment_version bigint :=
    current_setting('r6c.fixture.assignment_version')::bigint;
  v_approval_digest char(64) :=
    current_setting('r6c.fixture.approval_digest')::char(64);
  v_step_up_action_digest char(64) :=
    current_setting('r6c.fixture.step_up_action_digest')::char(64);
  v_step_up_idempotency_digest char(64) :=
    current_setting('r6c.fixture.step_up_idempotency_digest')::char(64);
  v_request_id uuid := gen_random_uuid();
  v_assertion_jti uuid := gen_random_uuid();
  v_receipt jsonb;
BEGIN
  IF v_phase = 'approve_stale_case' THEN
    RETURN;
  END IF;
  v_receipt := ops.execute_action_approval_v1(
    'submitActionDecision', jsonb_build_object(
      'proposalId', v_proposal_id,
      'assignmentId', v_assignment_id,
      'expectedProposalVersion', 1,
      'expectedAssignmentVersion', v_assignment_version,
      'expectedApprovalDigest', btrim(v_approval_digest),
      'actionKind', 'HYPOTHESIS',
      'decision', jsonb_build_object(
        'kind', 'APPROVE', 'reason',
        'TEST_FIXTURE_ONLY ' || v_phase || ' approval',
        'assurance', 'STEP_UP',
        'stepUpAuthorizationId', v_step_up_id,
        'assertedActionDigest', btrim(v_step_up_action_digest)
      ),
      'reason', 'TEST_FIXTURE_ONLY ' || v_phase || ' approval',
      'assurance', 'STEP_UP',
      'stepUpAuthorizationId', v_step_up_id,
      'assertedActionDigest', btrim(v_step_up_action_digest),
      'requestId', v_request_id,
      '_idempotencyKeySha256', btrim(v_step_up_idempotency_digest),
      '_actorAssertionJti', v_assertion_jti,
      '_actorAssuranceLevel', 'STEP_UP',
      '_actorActionDigest', btrim(v_step_up_action_digest),
      '_actorStepUpAuthorizationId', v_step_up_id,
      '_actorIdempotencyKeySha256',
        btrim(v_step_up_idempotency_digest),
      '_actorRequestKeySha256', btrim(v_step_up_idempotency_digest)
    ), v_reviewer
  );
  IF v_receipt->>'decisionKind' IS DISTINCT FROM 'APPROVE'
     OR v_receipt->>'resultingState' IS DISTINCT FROM 'APPROVED'
     OR v_receipt->'executionAuthorization'->>'actionKind'
       IS DISTINCT FROM 'HYPOTHESIS'
     OR v_receipt->'executionAuthorization'->>'state'
       IS DISTINCT FROM 'QUEUED' THEN
    RAISE EXCEPTION 'R6c HYPOTHESIS approval invalid: %', v_phase;
  END IF;
END $$;
RESET ROLE;

DO $$
DECLARE
  v_phase text := current_setting('r6c.fixture.phase');
  v_proposal_id uuid := CASE current_setting('r6c.fixture.phase')
    WHEN 'approve_absent'
      THEN '31610000-0000-4000-8000-000000000001'::uuid
    WHEN 'approve_disabled'
      THEN '31610000-0000-4000-8000-000000000002'::uuid
    WHEN 'approve_case_budget'
      THEN '31610000-0000-4000-8000-000000000003'::uuid
    WHEN 'approve_max_depth'
      THEN '31610000-0000-4000-8000-000000000004'::uuid
    WHEN 'approve_happy'
      THEN '31610000-0000-4000-8000-000000000005'::uuid
    WHEN 'approve_stale_case'
      THEN '31610000-0000-4000-8000-000000000006'::uuid
  END;
BEGIN
  IF v_phase = 'approve_stale_case' THEN
    IF EXISTS (
         SELECT 1 FROM ops.execution_authorizations AS execution_authorization
         WHERE execution_authorization.proposal_id = v_proposal_id
       )
       OR NOT EXISTS (
         SELECT 1
         FROM ops.action_proposal_versions AS version
         JOIN ops.action_review_assignments AS assignment
           ON assignment.proposal_id = version.proposal_id
          AND assignment.proposal_version = version.version
         JOIN ops.action_proposals AS proposal
           ON proposal.id = version.proposal_id
         JOIN editorial.cases AS current_case
           ON current_case.id = proposal.target_id::uuid
         WHERE version.proposal_id = v_proposal_id
           AND version.state = 'PENDING_QUORUM'
           AND assignment.state = 'IN_PROGRESS'
           AND assignment.version = 2
           AND current_case.version = proposal.target_version + 1
       ) THEN
      RAISE EXCEPTION 'R6c stale proposal pre-decision state invalid';
    END IF;
    RETURN;
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM ops.execution_authorizations AS execution_authorization
    JOIN ops.action_proposal_versions AS proposal_version
      ON proposal_version.proposal_id = execution_authorization.proposal_id
     AND proposal_version.version = execution_authorization.proposal_version
    JOIN ops.agent_suggestions AS suggestion
      ON suggestion.materialized_action_proposal_id =
        execution_authorization.proposal_id
    WHERE execution_authorization.proposal_id = v_proposal_id
      AND execution_authorization.action_kind = 'HYPOTHESIS'
      AND execution_authorization.executor_id = 'createHypothesis'
      AND execution_authorization.transport = 'BASE_APPLICATION_COMMAND'
      AND execution_authorization.required_capability = 'cases.investigate'
      AND execution_authorization.target_request_schema_version =
        'action-payload.v1'
      AND execution_authorization.target_request_sha256 =
        proposal_version.content_digest
      AND suggestion.status = 'ACCEPTED'
      AND suggestion.version = 2
  ) THEN
    RAISE EXCEPTION 'R6c queued execution binding invalid: %', v_phase;
  END IF;
END $$;
COMMIT;
\endif

\if :r6c_recursion_verify
BEGIN;
SET LOCAL TIME ZONE 'UTC';
SELECT set_config(
  'r6c.fixture.phase', :'r6c_recursion_phase', true
);
DO $$
DECLARE
  v_assignment ops.action_review_assignments%ROWTYPE;
  v_step_up ops.step_up_authorizations%ROWTYPE;
BEGIN
  IF current_setting('r6c.fixture.phase') <>
       'verify_stale_case_version' THEN
    RETURN;
  END IF;
  PERFORM set_config('r6c.stale.decisions',(
    SELECT count(*)::text FROM ops.action_decisions
  ),true);
  PERFORM set_config('r6c.stale.authorizations',(
    SELECT count(*)::text FROM ops.execution_authorizations
  ),true);
  PERFORM set_config('r6c.stale.effects',(
    SELECT count(*)::text FROM ops.in_flight_effects
  ),true);
  PERFORM set_config('r6c.stale.audit',(
    SELECT count(*)::text FROM ops.audit_events
  ),true);
  PERFORM set_config('r6c.stale.execution_receipts',(
    SELECT count(*)::text FROM ops.execution_receipts
  ),true);
  PERFORM set_config('r6c.stale.outbox',(
    SELECT count(*)::text FROM ops.outbox
  ),true);
  PERFORM set_config('r6c.stale.step_up_issues',(
    SELECT assertion_issue_count::text
    FROM ops.step_up_authorizations
    WHERE id = '31620000-0000-4000-8000-000000000006'
  ),true);
  SELECT assignment.* INTO STRICT v_assignment
  FROM ops.action_review_assignments AS assignment
  WHERE assignment.proposal_id =
      '31610000-0000-4000-8000-000000000006'::uuid
    AND assignment.slot_id = 'primary';
  SELECT step_up.* INTO STRICT v_step_up
  FROM ops.step_up_authorizations AS step_up
  WHERE step_up.id =
    '31620000-0000-4000-8000-000000000006'::uuid;
  PERFORM set_config(
    'r6c.stale.assignment_id', v_assignment.id::text, true
  );
  PERFORM set_config(
    'r6c.stale.assignment_version', v_assignment.version::text, true
  );
  PERFORM set_config(
    'r6c.stale.approval_digest', btrim(v_assignment.approval_digest), true
  );
  PERFORM set_config(
    'r6c.stale.step_up_action_digest', btrim(v_step_up.action_digest), true
  );
  PERFORM set_config(
    'r6c.stale.step_up_idempotency_digest',
    btrim(v_step_up.idempotency_key_sha256), true
  );
END $$;

SET LOCAL ROLE gurine_control_api;
DO $$
DECLARE
  v_proposal_id constant uuid :=
    '31610000-0000-4000-8000-000000000006';
  v_reviewer constant uuid :=
    '00000000-0000-4000-8000-000000000316';
  v_assignment_id uuid;
  v_assignment_version bigint;
  v_approval_digest char(64);
  v_step_up_action_digest char(64);
  v_step_up_idempotency_digest char(64);
  v_message text;
  v_denied boolean := false;
BEGIN
  IF current_setting('r6c.fixture.phase') <>
       'verify_stale_case_version' THEN
    RETURN;
  END IF;
  v_assignment_id := current_setting('r6c.stale.assignment_id')::uuid;
  v_assignment_version :=
    current_setting('r6c.stale.assignment_version')::bigint;
  v_approval_digest :=
    current_setting('r6c.stale.approval_digest')::char(64);
  v_step_up_action_digest :=
    current_setting('r6c.stale.step_up_action_digest')::char(64);
  v_step_up_idempotency_digest :=
    current_setting('r6c.stale.step_up_idempotency_digest')::char(64);
  BEGIN
    PERFORM ops.execute_action_approval_v1(
      'submitActionDecision',jsonb_build_object(
        'proposalId',v_proposal_id,
        'assignmentId',v_assignment_id,
        'expectedProposalVersion',1,
        'expectedAssignmentVersion',v_assignment_version,
        'expectedApprovalDigest',btrim(v_approval_digest),
        'actionKind','HYPOTHESIS',
        'decision',jsonb_build_object(
          'kind','APPROVE',
          'reason','TEST_FIXTURE_ONLY stale case decision must fail',
          'assurance','STEP_UP',
          'stepUpAuthorizationId',
            '31620000-0000-4000-8000-000000000006'::uuid,
          'assertedActionDigest',btrim(v_step_up_action_digest)
        ),
        'reason','TEST_FIXTURE_ONLY stale case decision must fail',
        'assurance','STEP_UP',
        'stepUpAuthorizationId',
          '31620000-0000-4000-8000-000000000006'::uuid,
        'assertedActionDigest',btrim(v_step_up_action_digest),
        'requestId','31660000-0000-4000-8000-000000000002'::uuid,
        '_idempotencyKeySha256',btrim(v_step_up_idempotency_digest),
        '_actorAssertionJti',
          '31660000-0000-4000-8000-000000000001'::uuid,
        '_actorAssuranceLevel','STEP_UP',
        '_actorActionDigest',btrim(v_step_up_action_digest),
        '_actorStepUpAuthorizationId',
          '31620000-0000-4000-8000-000000000006'::uuid,
        '_actorIdempotencyKeySha256',
          btrim(v_step_up_idempotency_digest),
        '_actorRequestKeySha256',
          btrim(v_step_up_idempotency_digest)
      ),v_reviewer
    );
    RAISE EXCEPTION 'R6c stale case decision unexpectedly succeeded';
  EXCEPTION WHEN SQLSTATE '40001' THEN
    GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT;
    v_denied := v_message = 'hypothesis_action_decision_case_version_drift';
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'R6c stale case decision error contract invalid: %',
      COALESCE(v_message,'no 40001');
  END IF;
END $$;
RESET ROLE;

DO $$
DECLARE
  v_proposal_id constant uuid :=
    '31610000-0000-4000-8000-000000000006';
BEGIN
  IF current_setting('r6c.fixture.phase') <>
       'verify_stale_case_version' THEN
    RETURN;
  END IF;
  IF current_setting('r6c.stale.decisions')::bigint <>
       (SELECT count(*) FROM ops.action_decisions)
     OR current_setting('r6c.stale.authorizations')::bigint <>
       (SELECT count(*) FROM ops.execution_authorizations)
     OR current_setting('r6c.stale.effects')::bigint <>
       (SELECT count(*) FROM ops.in_flight_effects)
     OR current_setting('r6c.stale.audit')::bigint <>
       (SELECT count(*) FROM ops.audit_events)
     OR current_setting('r6c.stale.execution_receipts')::bigint <>
       (SELECT count(*) FROM ops.execution_receipts)
     OR current_setting('r6c.stale.outbox')::bigint <>
       (SELECT count(*) FROM ops.outbox)
     OR current_setting('r6c.stale.step_up_issues')::integer <>
       (SELECT assertion_issue_count FROM ops.step_up_authorizations
        WHERE id = '31620000-0000-4000-8000-000000000006')
     OR EXISTS (
       SELECT 1 FROM ops.action_decisions AS decision
       WHERE decision.proposal_id = v_proposal_id
     )
     OR EXISTS (
       SELECT 1 FROM ops.execution_authorizations AS execution_authorization
       WHERE execution_authorization.proposal_id = v_proposal_id
     )
     OR NOT EXISTS (
       SELECT 1
       FROM ops.action_proposal_versions AS version
       JOIN ops.action_review_assignments AS assignment
         ON assignment.proposal_id = version.proposal_id
        AND assignment.proposal_version = version.version
       JOIN ops.action_proposals AS proposal
         ON proposal.id = version.proposal_id
       JOIN editorial.cases AS current_case
         ON current_case.id = proposal.target_id::uuid
       WHERE version.proposal_id = v_proposal_id
         AND version.state = 'PENDING_QUORUM'
         AND assignment.state = 'IN_PROGRESS'
         AND assignment.version = 2
         AND current_case.version = proposal.target_version + 1
     ) THEN
    RAISE EXCEPTION 'R6c stale case side-effect boundary invalid';
  END IF;
END $$;
COMMIT;
\endif

\if :r6c_recursion_complete_stage
BEGIN;
SET LOCAL TIME ZONE 'UTC';
SELECT set_config(
  'r6c.fixture.phase', :'r6c_recursion_phase', true
);

-- Claim and complete the production-created V2 run through the analysis
-- worker owner routines.  Only provider/validation evidence is fixture data;
-- no recursion plan, node, transition, receipt, or ledger row is authored
-- here.  The resulting agent.run_completed.v1 outbox event must still pass
-- through scheduler -> workflow-worker in the surrounding runtime script.
DO $$
DECLARE
  v_phase text := current_setting('r6c.fixture.phase');
  v_proposal_id uuid := CASE current_setting('r6c.fixture.phase')
    WHEN 'complete_market_max_depth'
      THEN '31610000-0000-4000-8000-000000000004'::uuid
    ELSE '31610000-0000-4000-8000-000000000005'::uuid
  END;
  v_stage text := CASE current_setting('r6c.fixture.phase')
    WHEN 'complete_skeptic_happy' THEN 'SKEPTIC'
    ELSE 'MARKET_RESEARCHER'
  END;
  v_depth integer := CASE current_setting('r6c.fixture.phase')
    WHEN 'complete_skeptic_happy' THEN 2
    ELSE 1
  END;
  v_lease_token uuid := CASE current_setting('r6c.fixture.phase')
    WHEN 'complete_market_max_depth'
      THEN '31650000-0000-4000-8000-000000000001'::uuid
    WHEN 'complete_market_happy'
      THEN '31650000-0000-4000-8000-000000000002'::uuid
    WHEN 'complete_skeptic_happy'
      THEN '31650000-0000-4000-8000-000000000003'::uuid
  END;
  v_node ops.hypothesis_recursion_nodes%ROWTYPE;
  v_run ops.agent_runs%ROWTYPE;
  v_job ops.jobs%ROWTYPE;
BEGIN
  SELECT node.* INTO STRICT v_node
  FROM ops.hypothesis_recursion_nodes AS node
  JOIN ops.hypothesis_recursion_plans AS plan
    ON plan.plan_id = node.plan_id
  JOIN ops.execution_authorizations AS execution_authorization
    ON execution_authorization.execution_id = plan.root_hypothesis_execution_id
   AND execution_authorization.generation =
     plan.root_hypothesis_execution_generation
  WHERE execution_authorization.proposal_id = v_proposal_id
    AND node.stage = v_stage
    AND node.depth = v_depth;
  SELECT run.* INTO STRICT v_run
  FROM ops.agent_runs AS run
  WHERE run.id = v_node.agent_run_id;
  SELECT job.* INTO STRICT v_job
  FROM ops.jobs AS job
  WHERE job.id = v_node.job_id
  FOR UPDATE;
  IF v_run.run_contract_version <> 2
     OR v_run.status <> 'QUEUED'
     OR v_run.control_state <> 'NONE'
     OR v_run.version <> 1
     OR v_job.job_type <> 'AGENT_RUN'
     OR v_job.queue <> 'analysis-worker'
     OR v_job.status <> 'QUEUED'
     OR v_job.attempt_count <> 0
     OR v_job.payload->>'agentRunId' <> v_run.id::text THEN
    RAISE EXCEPTION 'R6c stage run preclaim invalid: %', v_phase;
  END IF;
  UPDATE ops.jobs AS job
  SET status = 'RUNNING',
      lease_owner = 'r6c-recursion-stage-runtime',
      lease_token = v_lease_token,
      lease_expires_at = clock_timestamp() + interval '10 minutes',
      fencing_token = job.fencing_token + 1,
      attempt_count = job.attempt_count + 1,
      updated_at = clock_timestamp()
  WHERE job.id = v_job.id
    AND job.status = 'QUEUED'
    AND job.attempt_count = 0;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6c stage job claim fence stale: %', v_phase;
  END IF;
  INSERT INTO ops.job_attempts(
    job_id,attempt,worker_id,fencing_token,started_at
  ) VALUES (
    v_job.id,1,'r6c-recursion-stage-runtime',1,clock_timestamp()
  );
  PERFORM set_config('r6c.fixture.stage_run_id', v_run.id::text, true);
  PERFORM set_config('r6c.fixture.stage_job_id', v_job.id::text, true);
  PERFORM set_config(
    'r6c.fixture.stage_lease_token', v_lease_token::text, true
  );
END $$;

SET LOCAL ROLE gurine_analysis_worker;
DO $$
BEGIN
  PERFORM * FROM ops.claim_agent_run_worker_v2(
    current_setting('r6c.fixture.stage_run_id')::uuid,
    current_setting('r6c.fixture.stage_job_id')::uuid,
    current_setting('r6c.fixture.stage_lease_token')::uuid,
    1
  );
END $$;
RESET ROLE;

DO $$
DECLARE
  v_phase text := current_setting('r6c.fixture.phase');
  v_run_id uuid := current_setting('r6c.fixture.stage_run_id')::uuid;
  v_turn_id uuid := CASE current_setting('r6c.fixture.phase')
    WHEN 'complete_market_max_depth'
      THEN '31640000-0000-4000-8000-000000000101'::uuid
    WHEN 'complete_market_happy'
      THEN '31640000-0000-4000-8000-000000000201'::uuid
    WHEN 'complete_skeptic_happy'
      THEN '31640000-0000-4000-8000-000000000301'::uuid
  END;
  v_provider_receipt_id uuid := CASE current_setting('r6c.fixture.phase')
    WHEN 'complete_market_max_depth'
      THEN '31640000-0000-4000-8000-000000000102'::uuid
    WHEN 'complete_market_happy'
      THEN '31640000-0000-4000-8000-000000000202'::uuid
    WHEN 'complete_skeptic_happy'
      THEN '31640000-0000-4000-8000-000000000302'::uuid
  END;
  v_validation_id uuid := CASE current_setting('r6c.fixture.phase')
    WHEN 'complete_market_max_depth'
      THEN '31640000-0000-4000-8000-000000000103'::uuid
    WHEN 'complete_market_happy'
      THEN '31640000-0000-4000-8000-000000000203'::uuid
    WHEN 'complete_skeptic_happy'
      THEN '31640000-0000-4000-8000-000000000303'::uuid
  END;
  v_run ops.agent_runs%ROWTYPE;
  v_claim ops.agent_run_control_receipts%ROWTYPE;
  v_output jsonb;
  v_output_sha char(64);
  v_request jsonb;
  v_request_canonical bytea;
  v_request_sha char(64);
  v_provider_receipt jsonb;
  v_provider_receipt_canonical bytea;
  v_provider_receipt_sha char(64);
  v_turn_canonical bytea;
  v_turn_sha char(64);
  v_citation_set_sha char(64);
  v_proposal_set_sha char(64);
  v_validation_sha char(64);
  v_occurred_at timestamptz := clock_timestamp();
BEGIN
  SELECT run.* INTO STRICT v_run
  FROM ops.agent_runs AS run
  WHERE run.id = v_run_id;
  SELECT receipt.* INTO STRICT v_claim
  FROM ops.agent_run_control_receipts AS receipt
  WHERE receipt.agent_run_id = v_run_id
    AND receipt.aggregate_version = 1;
  IF v_run.status <> 'RUNNING' OR v_run.control_state <> 'ACTIVE'
     OR v_run.version <> 2 OR v_claim.reason_code <> 'RUN_STARTED' THEN
    RAISE EXCEPTION 'R6c stage run owner claim invalid: %', v_phase;
  END IF;
  v_output := jsonb_build_object(
    'schemaVersion', CASE v_run.agent_type
      WHEN 'market-researcher' THEN 'market-researcher-output.v1'
      ELSE 'skeptic-output.v1'
    END,
    'outcome','COMPLETED',
    'summary',CASE v_run.agent_type
      WHEN 'market-researcher'
        THEN 'TEST_FIXTURE_ONLY 승인 가설의 근거 공백 조사 완료'
      ELSE 'TEST_FIXTURE_ONLY 승인 가설의 반증 검토 완료'
    END,
    'fixtureAuthority','TEST_FIXTURE_ONLY'
  );
  v_output_sha := encode(extensions.digest(
    ops.canonical_jsonb_v1(v_output), 'sha256'
  ), 'hex');
  v_request := jsonb_build_object(
    'schemaVersion','r6c-recursion-stage-request.v1',
    'agentRunId',v_run.id,
    'fixtureAuthority','TEST_FIXTURE_ONLY'
  );
  v_request_canonical := ops.canonical_jsonb_v1(v_request);
  v_request_sha := encode(
    extensions.digest(v_request_canonical, 'sha256'), 'hex'
  );
  v_provider_receipt := jsonb_build_object(
    'schemaVersion','r6c-recursion-stage-provider-receipt.v1',
    'agentRunId',v_run.id,
    'fixtureAuthority','TEST_FIXTURE_ONLY'
  );
  v_provider_receipt_canonical := ops.canonical_jsonb_v1(
    v_provider_receipt
  );
  v_provider_receipt_sha := encode(extensions.digest(
    v_provider_receipt_canonical, 'sha256'
  ), 'hex');
  v_turn_canonical := ops.canonical_jsonb_v1(jsonb_build_object(
    'schemaVersion','r6c-recursion-stage-provider-turn.v1',
    'providerTurnId',v_turn_id,
    'agentRunId',v_run.id,
    'outputSha256',btrim(v_output_sha::text),
    'providerReceiptSha256',btrim(v_provider_receipt_sha::text),
    'fixtureAuthority','TEST_FIXTURE_ONLY'
  ));
  v_turn_sha := encode(
    extensions.digest(v_turn_canonical, 'sha256'), 'hex'
  );
  INSERT INTO ops.agent_provider_turns(
    provider_turn_id,agent_run_id,input_snapshot_sha256,
    turn_sequence,attempt_sequence,prior_transcript_sha256,
    provider_mode,provider_candidate_id,model_id,
    model_configuration_sha256,routing_policy_version,
    routing_decision_sha256,prompt_id,prompt_version,prompt_sha256,
    output_schema_id,output_schema_version,output_schema_sha256,
    classification,model_use_rights_sha256,
    budget_reservation_key_sha256,dispatch_key_sha256,
    request_sha256,request_redacted,request_canonical,status,
    envelope_kind,envelope_sha256,envelope_payload_sha256,
    envelope_canonical,response_redacted,response_redacted_canonical,
    provider_receipt_id,provider_receipt,provider_receipt_canonical,
    provider_receipt_sha256,provider_turn_canonical,
    provider_turn_sha256,turn_transcript_sha256,
    input_units,output_units,latency_ms,version,dispatched_at,completed_at
  ) VALUES (
    v_turn_id,v_run.id,v_run.input_snapshot_hash,1,1,
    v_run.initial_transcript_sha256,'DETERMINISTIC_DOUBLE',
    'r6c-deterministic-double','r6c-deterministic-model',
    encode(extensions.digest(convert_to(
      'r6c-deterministic-model','UTF8'
    ),'sha256'),'hex'),
    v_run.provider_policy_version,v_run.provider_policy_sha256,
    v_run.prompt_id,v_run.prompt_version,v_run.prompt_sha256,
    v_run.output_schema_id,v_run.output_schema_contract_version,
    v_run.output_schema_sha256,v_run.provider_classification,
    encode(extensions.digest(convert_to(
      'TEST_FIXTURE_ONLY public model use','UTF8'
    ),'sha256'),'hex'),
    encode(extensions.digest(convert_to(
      v_run.id::text || ':budget','UTF8'
    ),'sha256'),'hex'),
    encode(extensions.digest(convert_to(
      v_run.id::text || ':dispatch','UTF8'
    ),'sha256'),'hex'),
    v_request_sha,v_request,v_request_canonical,'COMPLETED',
    'FINAL_OUTPUT',v_output_sha,v_output_sha,
    ops.canonical_jsonb_v1(v_output),v_output,
    ops.canonical_jsonb_v1(v_output),v_provider_receipt_id,
    v_provider_receipt,v_provider_receipt_canonical,
    v_provider_receipt_sha,v_turn_canonical,v_turn_sha,
    encode(extensions.digest(ops.canonical_jsonb_v1(
      jsonb_build_object(
        'priorTranscriptSha256',btrim(v_run.initial_transcript_sha256),
        'providerTurnSha256',btrim(v_turn_sha::text)
      )
    ),'sha256'),'hex'),
    1,1,1,1,v_occurred_at,v_occurred_at + interval '1 second'
  );
  v_citation_set_sha := encode(extensions.digest(
    ops.canonical_jsonb_v1('[]'::jsonb), 'sha256'
  ), 'hex');
  v_proposal_set_sha := v_citation_set_sha;
  v_validation_sha := encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'agentRunId',v_run.id,
      'providerTurnId',v_turn_id,
      'outputSha256',btrim(v_output_sha::text),
      'receiptSha256',btrim(v_provider_receipt_sha::text),
      'citationSetSha256',btrim(v_citation_set_sha::text)
    )), 'sha256'
  ), 'hex');
  INSERT INTO ops.agent_output_validations(
    validation_id,agent_run_id,provider_turn_id,input_snapshot_sha256,
    provider_output_sha256,validator_version,validator_sha256,
    output_schema_id,output_schema_version,output_schema_sha256,
    validation_policy_version,validation_policy_sha256,
    validation_status,schema_status,citation_status,policy_status,
    run_terminal_status,output_status,failure_code,
    failure_details_redacted,validated_outcome,validated_outcome_sha256,
    citation_count,proposal_count,citation_set_sha256,
    proposal_set_sha256,validation_sha256,validated_at
  ) VALUES (
    v_validation_id,v_run.id,v_turn_id,v_run.input_snapshot_hash,
    v_output_sha,'r6c-recursion-stage-validator-v1',
    encode(extensions.digest(convert_to(
      'r6c-recursion-stage-validator-v1','UTF8'
    ),'sha256'),'hex'),
    v_run.output_schema_id,v_run.output_schema_contract_version,
    v_run.output_schema_sha256,
    'r6c-recursion-stage-validation-policy-v1',
    encode(extensions.digest(convert_to(
      'r6c-recursion-stage-validation-policy-v1','UTF8'
    ),'sha256'),'hex'),
    'VALID','PASS','PASS','PASS','SUCCEEDED','COMPLETED',
    NULL,'[]'::jsonb,v_output,v_output_sha,0,0,
    v_citation_set_sha,v_proposal_set_sha,v_validation_sha,
    v_occurred_at + interval '2 seconds'
  );
  PERFORM set_config(
    'r6c.fixture.stage_validation_id', v_validation_id::text, true
  );
  PERFORM set_config(
    'r6c.fixture.stage_output_sha', btrim(v_output_sha::text), true
  );
END $$;

SET LOCAL ROLE gurine_analysis_worker;
DO $$
DECLARE
  v_phase text := current_setting('r6c.fixture.phase');
  v_run ops.agent_runs%ROWTYPE;
  v_claim ops.agent_run_control_receipts%ROWTYPE;
  v_validation ops.agent_output_validations%ROWTYPE;
  v_actual_cost numeric(18,6) := CASE current_setting(
    'r6c.fixture.phase'
  )
    WHEN 'complete_skeptic_happy' THEN 0.500000
    ELSE 1.000000
  END;
BEGIN
  SELECT run.* INTO STRICT v_run
  FROM ops.agent_runs AS run
  WHERE run.id = current_setting('r6c.fixture.stage_run_id')::uuid;
  SELECT receipt.* INTO STRICT v_claim
  FROM ops.agent_run_control_receipts AS receipt
  WHERE receipt.agent_run_id = v_run.id
    AND receipt.aggregate_version = 1;
  SELECT validation.* INTO STRICT v_validation
  FROM ops.agent_output_validations AS validation
  WHERE validation.validation_id = current_setting(
    'r6c.fixture.stage_validation_id'
  )::uuid;
  PERFORM * FROM ops.complete_agent_run_worker_v2(
    v_run.id,2,v_claim.receipt_id,v_claim.receipt_sha256,
    current_setting('r6c.fixture.stage_job_id')::uuid,
    current_setting('r6c.fixture.stage_lease_token')::uuid,
    1,'SUCCEEDED','r6c-deterministic-double',
    'r6c-deterministic-model',v_validation.validated_outcome,
    v_validation.provider_output_sha256,NULL,NULL,NULL,v_actual_cost
  );
END $$;
RESET ROLE;

DO $$
DECLARE
  v_phase text := current_setting('r6c.fixture.phase');
  v_run_id uuid := current_setting('r6c.fixture.stage_run_id')::uuid;
  v_job_id uuid := current_setting('r6c.fixture.stage_job_id')::uuid;
  v_run ops.agent_runs%ROWTYPE;
BEGIN
  UPDATE ops.jobs
  SET status = 'SUCCEEDED',lease_owner = NULL,lease_token = NULL,
      lease_expires_at = NULL,completed_at = clock_timestamp(),
      updated_at = clock_timestamp()
  WHERE id = v_job_id AND status = 'RUNNING';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6c stage job completion fence stale: %', v_phase;
  END IF;
  UPDATE ops.job_attempts
  SET outcome = 'SUCCEEDED',finished_at = clock_timestamp(),
      metrics = jsonb_build_object(
        'agentRunId',v_run_id,
        'fixtureAuthority','TEST_FIXTURE_ONLY'
      )
  WHERE job_id = v_job_id AND attempt = 1 AND outcome IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6c stage job attempt completion stale: %', v_phase;
  END IF;
  SELECT run.* INTO STRICT v_run
  FROM ops.agent_runs AS run
  WHERE run.id = v_run_id;
  IF v_run.status <> 'SUCCEEDED'
     OR v_run.control_state <> 'SETTLED'
     OR v_run.version <> 3
     OR v_run.output_validation_id IS NULL
     OR v_run.terminal_receipt_sha256 IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM ops.outbox AS event
       WHERE event.aggregate_type = 'agent_run'
         AND event.aggregate_id = v_run.id::text
         AND event.aggregate_version = 2
         AND event.event_type = 'agent.run_completed.v1'
         AND event.payload->>'status' = 'SUCCEEDED'
     ) THEN
    RAISE EXCEPTION 'R6c stage terminal authority invalid: %', v_phase;
  END IF;
END $$;

COMMIT;
\endif
