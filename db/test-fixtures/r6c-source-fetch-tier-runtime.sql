-- TEST_FIXTURE_ONLY: R6c source.fetch review-tier owner proof.
--
-- Run after reference-seed.sql, control-runtime-seed.sql, and
-- control-research-seed.sql in a disposable database.  The research artifact,
-- rights decision, parser result, EvidenceSegment, provider turn, tool call,
-- and TOOL_QUERY source use below were all created by the existing authoritative
-- fixture through ops.record_research_fetch_v1; this proof does not synthesize
-- replacements for any of those rows.
--
-- Citation source-use/proposal persistence is owned by the analysis-worker Rust
-- transaction and has no SQL-callable owner routine.  It is intentionally not
-- copied into this fixture: the Rust DB integration test owns that projection
-- and rollback proof.  This file exercises only the callable PostgreSQL owners:
-- the review authorization reader and atomic human-promotion routine.

BEGIN;
SET LOCAL TIME ZONE 'UTC';
SET CONSTRAINTS ALL DEFERRED;

CREATE TEMP TABLE r6c_source_tier_identity
ON COMMIT DROP
AS
SELECT
  artifact.id AS research_artifact_id,
  artifact.asset_id AS research_asset_id,
  artifact.asset_revision AS research_asset_revision,
  artifact.artifact_sha256 AS research_artifact_sha256,
  artifact.content_sha256 AS research_content_sha256,
  artifact.source_fetch_id AS research_source_fetch_id,
  artifact.agent_run_id,
  artifact.provider_turn_id,
  artifact.tool_call_id,
  artifact.request_kind,
  artifact.fetch_outcome,
  artifact.classification AS artifact_classification,
  artifact.content_safety_state,
  run.case_id,
  case_row.version AS initial_case_version,
  rights.id AS rights_decision_id,
  rights.decision_version AS rights_decision_version,
  rights.decision_sha256 AS rights_decision_sha256,
  segment.id AS evidence_segment_id,
  segment.locator_kind,
  segment.locator_value,
  segment.locator_digest,
  segment.selected_content_sha256,
  root_use.source_use_id AS root_source_use_id,
  root_use.source_use_sha256 AS root_source_use_sha256,
  root_use.source_use_canonical AS root_source_use_canonical,
  reviewer.id AS reviewer_user_id
FROM raw.research_artifacts AS artifact
JOIN ops.agent_runs AS run
  ON run.id = artifact.agent_run_id
JOIN editorial.cases AS case_row
  ON case_row.id = run.case_id
JOIN raw.asset_rights_decisions AS rights
  ON rights.research_artifact_id = artifact.id
 AND rights.asset_id = artifact.asset_id
 AND rights.asset_revision = artifact.asset_revision
 AND rights.asset_sha256 = artifact.content_sha256
 AND rights.decision_kind = 'GRANT'
JOIN raw.evidence_segments AS segment
  ON segment.id = '1e44d0d1-9826-59fb-bc26-07c443a2134d'
 AND segment.source_content_sha256 = artifact.content_sha256
JOIN ops.agent_source_uses AS root_use
  ON root_use.agent_run_id = artifact.agent_run_id
 AND root_use.provider_turn_id = artifact.provider_turn_id
 AND root_use.tool_call_id = artifact.tool_call_id
 AND root_use.use_kind = 'TOOL_QUERY'
 AND root_use.source_kind = 'RESEARCH_ARTIFACT'
 AND root_use.research_artifact_id = artifact.id
 AND root_use.research_asset_id = artifact.asset_id
 AND root_use.research_asset_revision = artifact.asset_revision
 AND root_use.research_artifact_sha256 = artifact.artifact_sha256
 AND root_use.research_content_sha256 = artifact.content_sha256
 AND root_use.research_source_fetch_id = artifact.source_fetch_id
JOIN ops.users AS reviewer
  ON reviewer.id = '11111111-1111-4111-8111-111111111111'
 AND reviewer.status = 'ACTIVE'
WHERE artifact.id = 'facc134e-f4d3-551d-bb42-55d4495373ae';

GRANT SELECT ON r6c_source_tier_identity
  TO gurine_analysis_worker, gurine_public_projector, gurine_control_api;

DO $$
DECLARE
  v_identity r6c_source_tier_identity%ROWTYPE;
  v_initial raw.research_artifact_review_tiers%ROWTYPE;
  v_root_payload jsonb;
BEGIN
  IF (SELECT count(*) FROM r6c_source_tier_identity) <> 1 THEN
    RAISE EXCEPTION
      'R6c source-fetch authoritative fixture identity missing or ambiguous';
  END IF;
  SELECT * INTO STRICT v_identity FROM r6c_source_tier_identity;

  IF v_identity.request_kind <> 'FETCH_URL'
     OR v_identity.fetch_outcome <> 'STORED'
     OR v_identity.artifact_classification <> 'RESTRICTED'
     OR v_identity.content_safety_state <> 'CLEAN'
     OR v_identity.research_asset_revision <> 1
     OR v_identity.selected_content_sha256 <>
        v_identity.research_content_sha256 THEN
    RAISE EXCEPTION
      'R6c source-fetch artifact prerequisite contract invalid';
  END IF;

  SELECT tier.* INTO STRICT v_initial
  FROM raw.research_artifact_review_tiers AS tier
  WHERE tier.research_artifact_id = v_identity.research_artifact_id
    AND tier.revision = 1;
  IF (SELECT count(*)
      FROM raw.research_artifact_review_tiers AS tier
      WHERE tier.research_artifact_id = v_identity.research_artifact_id) <> 1
     OR v_initial.research_asset_id <> v_identity.research_asset_id
     OR v_initial.research_asset_revision <>
        v_identity.research_asset_revision
     OR v_initial.research_artifact_sha256 <>
        v_identity.research_artifact_sha256
     OR v_initial.research_content_sha256 <>
        v_identity.research_content_sha256
     OR v_initial.review_tier <> 'OFFICIAL_UNREVIEWED'
     OR v_initial.reviewed_classification <> 'RESTRICTED'
     OR v_initial.predecessor_revision IS NOT NULL
     OR v_initial.predecessor_receipt_sha256 IS NOT NULL
     OR v_initial.promotion_id IS NOT NULL
     OR v_initial.reviewed_by IS NOT NULL
     OR v_initial.receipt_canonical <>
        ops.canonical_jsonb_v1(v_initial.receipt_payload)
     OR v_initial.receipt_sha256 <> encode(
       extensions.digest(v_initial.receipt_canonical, 'sha256'), 'hex'
     ) THEN
    RAISE EXCEPTION 'R6c initial OFFICIAL_UNREVIEWED tier invalid';
  END IF;

  v_root_payload := convert_from(
    v_identity.root_source_use_canonical, 'UTF8'
  )::jsonb;
  IF v_root_payload->>'schemaVersion' <> 'source-use.v2'
     OR v_root_payload->>'useKind' <> 'TOOL_QUERY'
     OR v_root_payload->>'sourceKind' <> 'RESEARCH_ARTIFACT'
     OR (v_root_payload->>'providerTurnId')::uuid <>
        v_identity.provider_turn_id
     OR (v_root_payload->>'toolCallId')::uuid <> v_identity.tool_call_id
     OR v_root_payload->>'classification' <> 'RESTRICTED'
     OR v_identity.root_source_use_sha256 <> encode(
       extensions.digest(v_identity.root_source_use_canonical, 'sha256'),
       'hex'
     ) THEN
    RAISE EXCEPTION 'R6c source.fetch owner source-use binding invalid';
  END IF;
END $$;

CREATE TEMP TABLE r6c_source_tier_authorizations (
  stage text NOT NULL,
  use_scope text NOT NULL,
  review_tier text NOT NULL,
  reviewed_classification text NOT NULL,
  review_receipt_sha256 char(64) NOT NULL,
  promotion_id uuid NOT NULL,
  promotion_receipt_sha256 char(64) NOT NULL,
  reviewed_by uuid NOT NULL,
  reviewed_at timestamptz NOT NULL,
  source_locator_digest char(64) NOT NULL,
  official_source_registry_digest char(64) NOT NULL
) ON COMMIT DROP;
GRANT INSERT, SELECT ON r6c_source_tier_authorizations
  TO gurine_analysis_worker, gurine_public_projector;

SET LOCAL ROLE gurine_public_projector;
INSERT INTO r6c_source_tier_authorizations
SELECT 'PRE_PROMOTION', 'PUBLIC_CITATION', review_authorization.*
FROM r6c_source_tier_identity AS identity
CROSS JOIN LATERAL ops.read_research_artifact_review_authorization_v1(
  identity.research_artifact_id,
  identity.research_asset_id,
  identity.research_asset_revision,
  identity.research_artifact_sha256,
  identity.research_content_sha256,
  'PUBLIC_CITATION'
) AS review_authorization;
RESET ROLE;

SET LOCAL ROLE gurine_analysis_worker;
INSERT INTO r6c_source_tier_authorizations
SELECT 'PRE_PROMOTION', 'PROVIDER_INPUT', review_authorization.*
FROM r6c_source_tier_identity AS identity
CROSS JOIN LATERAL ops.read_research_artifact_review_authorization_v1(
  identity.research_artifact_id,
  identity.research_asset_id,
  identity.research_asset_revision,
  identity.research_artifact_sha256,
  identity.research_content_sha256,
  'PROVIDER_INPUT'
) AS review_authorization;
RESET ROLE;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM r6c_source_tier_authorizations
    WHERE stage = 'PRE_PROMOTION'
  ) THEN
    RAISE EXCEPTION
      'R6c unreviewed artifact was authorized before human promotion';
  END IF;
END $$;

CREATE TEMP TABLE r6c_source_tier_promotion_request
ON COMMIT DROP
AS
WITH request_payload AS (
  SELECT
    jsonb_build_object(
      'schemaVersion', 'promote-research-artifact.request.v1',
      'caseId', identity.case_id,
      'expectedCaseVersion', identity.initial_case_version,
      'agentRunId', identity.agent_run_id,
      'researchArtifact', jsonb_build_object(
        'id', identity.research_artifact_id,
        'assetId', identity.research_asset_id,
        'assetRevision', identity.research_asset_revision,
        'artifactSha256', btrim(identity.research_artifact_sha256::text),
        'contentSha256', btrim(identity.research_content_sha256::text),
        'sourceFetchId', identity.research_source_fetch_id,
        'providerTurnId', identity.provider_turn_id,
        'toolCallId', identity.tool_call_id
      ),
      'rightsDecision', jsonb_build_object(
        'id', identity.rights_decision_id,
        'version', identity.rights_decision_version,
        'decisionSha256', btrim(identity.rights_decision_sha256::text)
      ),
      'evidence', jsonb_build_object(
        'evidenceType', 'SOURCE_DOCUMENT',
        'title', 'R6c source-fetch tier runtime evidence',
        'description',
          'TEST_FIXTURE_ONLY callable promotion-owner proof',
        'classification', 'PUBLIC',
        'verificationStatus', 'PENDING',
        'publicExcerpt', 'gurinnae control promotion fixture'
      ),
      'selectedSegments', jsonb_build_array(jsonb_build_object(
        'ordinal', 0,
        'locator', jsonb_build_object(
          'kind', identity.locator_kind,
          'value', identity.locator_value,
          'locatorSha256', btrim(identity.locator_digest::text)
        ),
        'selectedContentSha256',
          btrim(identity.selected_content_sha256::text),
        'selectionPurpose', 'PRIMARY_EVIDENCE'
      )),
      'reason',
        'Verify the R6c human-promotion review-tier owner transaction'
    ) AS payload,
    identity.reviewer_user_id AS actor_id,
    '31600000-0000-4000-8000-000000000001'::uuid AS request_id,
    encode(extensions.digest(
      convert_to('r6c-source-fetch-tier-runtime', 'UTF8'), 'sha256'
    ), 'hex')::char(64) AS idempotency_key_sha256
  FROM r6c_source_tier_identity AS identity
)
SELECT
  request_payload.*,
  encode(extensions.digest(
    ops.canonical_jsonb_v1(request_payload.payload), 'sha256'
  ), 'hex')::char(64) AS request_digest
FROM request_payload;

GRANT SELECT ON r6c_source_tier_promotion_request TO gurine_control_api;

DO $$
DECLARE
  v_request r6c_source_tier_promotion_request%ROWTYPE;
BEGIN
  SELECT * INTO STRICT v_request FROM r6c_source_tier_promotion_request;
  IF NOT ops.jsonb_object_has_exact_keys_v1(v_request.payload, ARRAY[
       'schemaVersion', 'caseId', 'expectedCaseVersion', 'agentRunId',
       'researchArtifact', 'rightsDecision', 'evidence',
       'selectedSegments', 'reason'
     ]::text[])
     OR NOT ops.jsonb_object_has_exact_keys_v1(
       v_request.payload->'researchArtifact', ARRAY[
         'id', 'assetId', 'assetRevision', 'artifactSha256',
         'contentSha256', 'sourceFetchId', 'providerTurnId', 'toolCallId'
       ]::text[]
     )
     OR NOT ops.jsonb_object_has_exact_keys_v1(
       v_request.payload->'rightsDecision',
       ARRAY['id', 'version', 'decisionSha256']::text[]
     )
     OR NOT ops.jsonb_object_has_exact_keys_v1(
       v_request.payload->'evidence', ARRAY[
         'evidenceType', 'title', 'description', 'classification',
         'verificationStatus', 'publicExcerpt'
       ]::text[]
     )
     OR v_request.request_digest <> encode(extensions.digest(
       ops.canonical_jsonb_v1(v_request.payload), 'sha256'
     ), 'hex') THEN
    RAISE EXCEPTION 'R6c promotion request canonical contract invalid';
  END IF;
END $$;

CREATE TEMP TABLE r6c_source_tier_promotion_result (
  receipt jsonb NOT NULL
) ON COMMIT DROP;
GRANT INSERT, SELECT ON r6c_source_tier_promotion_result
  TO gurine_control_api;

SET LOCAL ROLE gurine_control_api;
INSERT INTO r6c_source_tier_promotion_result(receipt)
SELECT ops.promote_research_artifact_to_evidence_v1(
  request.payload,
  request.actor_id,
  request.request_id,
  request.idempotency_key_sha256,
  request.request_digest
)
FROM r6c_source_tier_promotion_request AS request;
RESET ROLE;

-- Force the deferred promotion graph guard before inspecting the result.
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;

SET LOCAL ROLE gurine_public_projector;
INSERT INTO r6c_source_tier_authorizations
SELECT 'POST_PROMOTION', 'PUBLIC_CITATION', review_authorization.*
FROM r6c_source_tier_identity AS identity
CROSS JOIN LATERAL ops.read_research_artifact_review_authorization_v1(
  identity.research_artifact_id,
  identity.research_asset_id,
  identity.research_asset_revision,
  identity.research_artifact_sha256,
  identity.research_content_sha256,
  'PUBLIC_CITATION'
) AS review_authorization;
RESET ROLE;

SET LOCAL ROLE gurine_analysis_worker;
INSERT INTO r6c_source_tier_authorizations
SELECT 'POST_PROMOTION', 'PROVIDER_INPUT', review_authorization.*
FROM r6c_source_tier_identity AS identity
CROSS JOIN LATERAL ops.read_research_artifact_review_authorization_v1(
  identity.research_artifact_id,
  identity.research_asset_id,
  identity.research_asset_revision,
  identity.research_artifact_sha256,
  identity.research_content_sha256,
  'PROVIDER_INPUT'
) AS review_authorization;
RESET ROLE;

DO $$
DECLARE
  v_identity r6c_source_tier_identity%ROWTYPE;
  v_request r6c_source_tier_promotion_request%ROWTYPE;
  v_result r6c_source_tier_promotion_result%ROWTYPE;
  v_initial raw.research_artifact_review_tiers%ROWTYPE;
  v_promoted raw.research_artifact_review_tiers%ROWTYPE;
  v_promotion raw.research_artifact_promotions%ROWTYPE;
  v_human_use ops.agent_source_uses%ROWTYPE;
BEGIN
  SELECT * INTO STRICT v_identity FROM r6c_source_tier_identity;
  SELECT * INTO STRICT v_request FROM r6c_source_tier_promotion_request;
  SELECT * INTO STRICT v_result FROM r6c_source_tier_promotion_result;
  SELECT tier.* INTO STRICT v_initial
  FROM raw.research_artifact_review_tiers AS tier
  WHERE tier.research_artifact_id = v_identity.research_artifact_id
    AND tier.revision = 1;
  SELECT tier.* INTO STRICT v_promoted
  FROM raw.research_artifact_review_tiers AS tier
  WHERE tier.research_artifact_id = v_identity.research_artifact_id
    AND tier.revision = 2;
  SELECT promotion.* INTO STRICT v_promotion
  FROM raw.research_artifact_promotions AS promotion
  WHERE promotion.promotion_id = (v_result.receipt->>'promotionId')::uuid;
  SELECT source_use.* INTO STRICT v_human_use
  FROM ops.agent_source_uses AS source_use
  WHERE source_use.agent_run_id = v_identity.agent_run_id
    AND source_use.promotion_id = v_promotion.promotion_id
    AND source_use.use_kind = 'HUMAN_PROMOTION';

  IF (SELECT count(*)
      FROM raw.research_artifact_review_tiers AS tier
      WHERE tier.research_artifact_id = v_identity.research_artifact_id) <> 2
     OR v_promoted.review_tier <> 'HUMAN_PROMOTED'
     OR v_promoted.reviewed_classification <> 'PUBLIC'
     OR v_promoted.predecessor_revision <> 1
     OR v_promoted.predecessor_receipt_sha256 <>
        v_initial.receipt_sha256
     OR v_promoted.source_use_agent_run_id <> v_identity.agent_run_id
     OR v_promoted.source_use_id <> v_identity.root_source_use_id
     OR v_promoted.source_use_sha256 <> v_identity.root_source_use_sha256
     OR v_promoted.source_locator_digest <>
        v_initial.source_locator_digest
     OR v_promoted.official_source_registry_digest <>
        v_initial.official_source_registry_digest
     OR v_promoted.promotion_id <> v_promotion.promotion_id
     OR v_promoted.promotion_receipt_sha256 <>
        v_promotion.receipt_sha256
     OR v_promoted.reviewed_by <> v_identity.reviewer_user_id
     OR v_promoted.reviewed_at <> v_promotion.promoted_at
     OR v_promoted.receipt_canonical <>
        ops.canonical_jsonb_v1(v_promoted.receipt_payload)
     OR v_promoted.receipt_sha256 <> encode(extensions.digest(
       v_promoted.receipt_canonical, 'sha256'
     ), 'hex') THEN
    RAISE EXCEPTION 'R6c HUMAN_PROMOTED revision-2 tier invalid';
  END IF;

  IF v_promotion.research_artifact_id <>
       v_identity.research_artifact_id
     OR v_promotion.root_source_use_id <> v_identity.root_source_use_id
     OR v_promotion.root_source_use_sha256 <>
        v_identity.root_source_use_sha256
     OR v_promotion.expected_case_version <>
        v_identity.initial_case_version
     OR v_promotion.case_version <> v_identity.initial_case_version + 1
     OR v_promotion.receipt_sha256 <>
        (v_result.receipt->>'receiptSha256')::char(64)
     OR v_promotion.receipt_payload->>'requestDigest' <>
        btrim(v_request.request_digest::text)
     OR (SELECT version FROM editorial.cases
         WHERE id = v_identity.case_id) <>
        v_identity.initial_case_version + 1
     OR (SELECT classification::text FROM editorial.evidence
         WHERE id = v_promotion.evidence_id) <> 'PUBLIC' THEN
    RAISE EXCEPTION 'R6c promotion owner receipt/state binding invalid';
  END IF;

  IF v_human_use.source_kind <> 'RESEARCH_ARTIFACT'
     OR v_human_use.parent_source_use_id <> v_identity.root_source_use_id
     OR v_human_use.parent_source_use_sha256 <>
        v_identity.root_source_use_sha256
     OR v_human_use.promotion_receipt_sha256 <>
        v_promotion.receipt_sha256
     OR v_human_use.research_artifact_id <>
        v_identity.research_artifact_id
     OR v_human_use.research_asset_id <> v_identity.research_asset_id
     OR v_human_use.research_asset_revision <>
        v_identity.research_asset_revision
     OR v_human_use.research_artifact_sha256 <>
        v_identity.research_artifact_sha256
     OR v_human_use.research_content_sha256 <>
        v_identity.research_content_sha256
     OR v_human_use.research_source_fetch_id <>
        v_identity.research_source_fetch_id
     OR v_human_use.provider_turn_id IS NOT NULL
     OR v_human_use.tool_call_id IS NOT NULL
     OR v_human_use.source_use_canonical <> v_promotion.receipt_canonical
     OR v_human_use.source_use_sha256 <> v_promotion.receipt_sha256 THEN
    RAISE EXCEPTION 'R6c HUMAN_PROMOTION source-use binding invalid';
  END IF;

  IF (SELECT count(*) FROM r6c_source_tier_authorizations
      WHERE stage = 'POST_PROMOTION') <> 2
     OR NOT EXISTS (
       SELECT 1 FROM r6c_source_tier_authorizations
       WHERE stage = 'POST_PROMOTION'
         AND use_scope = 'PUBLIC_CITATION'
         AND review_tier = 'HUMAN_PROMOTED'
         AND reviewed_classification = 'PUBLIC'
         AND review_receipt_sha256 = v_promoted.receipt_sha256
         AND promotion_id = v_promotion.promotion_id
         AND promotion_receipt_sha256 = v_promotion.receipt_sha256
         AND reviewed_by = v_identity.reviewer_user_id
     )
     OR NOT EXISTS (
       SELECT 1 FROM r6c_source_tier_authorizations
       WHERE stage = 'POST_PROMOTION'
         AND use_scope = 'PROVIDER_INPUT'
         AND review_tier = 'HUMAN_PROMOTED'
         AND reviewed_classification = 'PUBLIC'
         AND review_receipt_sha256 = v_promoted.receipt_sha256
         AND promotion_id = v_promotion.promotion_id
         AND promotion_receipt_sha256 = v_promotion.receipt_sha256
         AND reviewed_by = v_identity.reviewer_user_id
     ) THEN
    RAISE EXCEPTION
      'R6c post-promotion PUBLIC_CITATION/PROVIDER_INPUT authorization invalid';
  END IF;
END $$;

ROLLBACK;
