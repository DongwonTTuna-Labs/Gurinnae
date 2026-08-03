-- TEST_FIXTURE_ONLY: R6c typed graph v3 runtime proof.
--
-- This fixture is loaded only by scripts/test-event-consumers-runtime.sh.  It
-- deliberately creates no operational policy or source activation row, makes
-- no external request, and rolls back every row after exercising the owner
-- routines under their runtime roles.

BEGIN;

CREATE TEMP TABLE r6c_graph_endpoints (
  fixture_key text PRIMARY KEY,
  endpoint_id uuid NOT NULL,
  endpoint_kind text NOT NULL,
  endpoint_digest char(64) NOT NULL,
  identity_resolution_status text NOT NULL,
  parsed_record_id uuid NOT NULL
);
CREATE TEMP TABLE r6c_graph_assertions (
  fixture_key text PRIMARY KEY,
  assertion_id uuid NOT NULL,
  assertion_revision bigint NOT NULL,
  assertion_digest char(64) NOT NULL,
  receipt_sha256 char(64) NOT NULL,
  verification_status text NOT NULL,
  public_use_status text NOT NULL,
  disposition text NOT NULL,
  replayed boolean NOT NULL
);
CREATE TEMP TABLE r6c_graph_decisions (
  fixture_key text PRIMARY KEY,
  decision_id uuid NOT NULL,
  assertion_id uuid NOT NULL,
  assertion_revision bigint NOT NULL,
  assertion_digest char(64) NOT NULL,
  verification_status text NOT NULL,
  public_use_status text NOT NULL,
  receipt_sha256 char(64) NOT NULL,
  replayed boolean NOT NULL
);
CREATE TEMP TABLE r6c_graph_endpoint_boundary (
  before_count bigint NOT NULL,
  shape_denied boolean NOT NULL DEFAULT false,
  identity_denied boolean NOT NULL DEFAULT false
);
CREATE TEMP TABLE r6c_graph_assertion_boundary (
  before_count bigint NOT NULL,
  family_denied boolean NOT NULL DEFAULT false,
  zero_denied boolean NOT NULL DEFAULT false,
  oversized_denied boolean NOT NULL DEFAULT false,
  pair_denied boolean NOT NULL DEFAULT false
);
CREATE TEMP TABLE r6c_graph_digest_preimages (
  digest_domain text NOT NULL,
  fixture_key text NOT NULL,
  canonical_preimage bytea NOT NULL,
  expected_digest char(64) NOT NULL,
  PRIMARY KEY (digest_domain, fixture_key)
);
INSERT INTO r6c_graph_digest_preimages(
  digest_domain, fixture_key, canonical_preimage, expected_digest
)
SELECT fixture.digest_domain, fixture.fixture_key,
       convert_to(fixture.preimage, 'UTF8'),
       encode(extensions.digest(
         convert_to(fixture.preimage, 'UTF8'), 'sha256'
       ), 'hex')
FROM (VALUES
  (
    'IDENTIFIER', 'bid_supplier',
    '{"fixtureAuthority":"TEST_FIXTURE_ONLY","fixtureKey":"bid_supplier","schemaVersion":"r6c-typed-graph-identifier.v1","scheme":"KONEPS_PARTY_KEY"}'
  ),
  (
    'IDENTIFIER', 'notice',
    '{"fixtureAuthority":"TEST_FIXTURE_ONLY","fixtureKey":"notice","schemaVersion":"r6c-typed-graph-identifier.v1","scheme":"KONEPS_NOTICE_KEY"}'
  ),
  (
    'IDENTIFIER', 'sanction_supplier',
    '{"fixtureAuthority":"TEST_FIXTURE_ONLY","fixtureKey":"sanction_supplier","schemaVersion":"r6c-typed-graph-identifier.v1","scheme":"KONEPS_PARTY_KEY"}'
  ),
  (
    'IDENTIFIER', 'sanction',
    '{"fixtureAuthority":"TEST_FIXTURE_ONLY","fixtureKey":"sanction","schemaVersion":"r6c-typed-graph-identifier.v1","scheme":"PPS_SANCTION_KEY"}'
  ),
  (
    'IDENTIFIER', 'person',
    '{"fixtureAuthority":"TEST_FIXTURE_ONLY","fixtureKey":"person","schemaVersion":"r6c-typed-graph-identifier.v1","scheme":"PUBLIC_CONTEXT_DIGEST"}'
  ),
  (
    'IDENTIFIER', 'agency',
    '{"fixtureAuthority":"TEST_FIXTURE_ONLY","fixtureKey":"agency","schemaVersion":"r6c-typed-graph-identifier.v1","scheme":"AGENCY_ID"}'
  ),
  (
    'ENTITY', 'bid_supplier',
    '{"entityId":"31300000-0000-4000-8000-000000000011","entityRevision":1,"fixtureAuthority":"TEST_FIXTURE_ONLY","schemaVersion":"r6c-typed-graph-entity.v1"}'
  ),
  (
    'ENTITY', 'notice',
    '{"entityId":"31500000-0000-4000-8000-000000000103","entityRevision":1,"fixtureAuthority":"TEST_FIXTURE_ONLY","schemaVersion":"r6c-typed-graph-entity.v1"}'
  ),
  (
    'ENTITY', 'sanction_supplier',
    '{"entityId":"31300000-0000-4000-8000-000000000011","entityRevision":1,"fixtureAuthority":"TEST_FIXTURE_ONLY","schemaVersion":"r6c-typed-graph-entity.v1"}'
  ),
  (
    'ENTITY', 'sanction',
    '{"entityId":"31500000-0000-4000-8000-000000000105","entityRevision":1,"fixtureAuthority":"TEST_FIXTURE_ONLY","schemaVersion":"r6c-typed-graph-entity.v1"}'
  ),
  (
    'ENTITY', 'agency',
    '{"entityId":"31300000-0000-4000-8000-000000000010","entityRevision":1,"fixtureAuthority":"TEST_FIXTURE_ONLY","schemaVersion":"r6c-typed-graph-entity.v1"}'
  ),
  (
    'EVIDENCE', 'bid',
    '{"assertionId":"31500000-0000-4000-8000-000000000201","fixtureAuthority":"TEST_FIXTURE_ONLY","schemaVersion":"r6c-typed-graph-evidence.v1","sourceLocator":"https://fixture.invalid/koneps/opening/TEST-001"}'
  ),
  (
    'EVIDENCE', 'sanction',
    '{"assertionId":"31500000-0000-4000-8000-000000000202","fixtureAuthority":"TEST_FIXTURE_ONLY","schemaVersion":"r6c-typed-graph-evidence.v1","sourceLocator":"https://fixture.invalid/pps-sanctions/TEST-001"}'
  ),
  (
    'EVIDENCE', 'former',
    '{"assertionId":"31500000-0000-4000-8000-000000000203","fixtureAuthority":"TEST_FIXTURE_ONLY","schemaVersion":"r6c-typed-graph-evidence.v1","sourceLocator":"https://fixture.invalid/ethics/TEST-001"}'
  ),
  (
    'EVIDENCE', 'pending',
    '{"assertionId":"31500000-0000-4000-8000-000000000204","fixtureAuthority":"TEST_FIXTURE_ONLY","schemaVersion":"r6c-typed-graph-evidence.v1","sourceLocator":"https://fixture.invalid/koneps/opening/TEST-001#partial"}'
  ),
  (
    'EVIDENCE', 'human_proposal',
    '{"assertionId":"31500000-0000-4000-8000-000000000205","fixtureAuthority":"TEST_FIXTURE_ONLY","schemaVersion":"r6c-typed-graph-evidence.v1","sourceLocator":"https://fixture.invalid/koneps/opening/TEST-HUMAN-PROPOSAL"}'
  )
) AS fixture(digest_domain, fixture_key, preimage);
DO $$
BEGIN
  IF (SELECT count(*) FROM r6c_graph_digest_preimages) <> 16
     OR EXISTS (
       SELECT 1 FROM r6c_graph_digest_preimages AS preimage
       WHERE preimage.canonical_preimage IS DISTINCT FROM
               ops.canonical_jsonb_v1(
                 convert_from(preimage.canonical_preimage, 'UTF8')::jsonb
               )
          OR btrim(preimage.expected_digest) IS DISTINCT FROM encode(
               extensions.digest(preimage.canonical_preimage, 'sha256'),
               'hex'
             )
     ) THEN
    RAISE EXCEPTION 'R6c typed graph digest preimage closure invalid';
  END IF;
END $$;
GRANT INSERT, SELECT ON r6c_graph_endpoints TO gurine_ingest_worker;
GRANT INSERT, SELECT ON r6c_graph_assertions TO gurine_ingest_worker;
GRANT SELECT ON r6c_graph_endpoints, r6c_graph_assertions
  TO gurine_identity_api;
GRANT SELECT ON r6c_graph_endpoints TO gurine_analysis_worker;
GRANT INSERT, SELECT ON r6c_graph_decisions TO gurine_identity_api;
GRANT SELECT, UPDATE ON r6c_graph_endpoint_boundary
  TO gurine_ingest_worker;
GRANT SELECT, UPDATE ON r6c_graph_assertion_boundary
  TO gurine_ingest_worker;
GRANT SELECT ON r6c_graph_digest_preimages
  TO gurine_ingest_worker, gurine_identity_api;

INSERT INTO core.parser_runs(
  id, source_document_id, parser_name, parser_version, status,
  output_record_count, output_digest, input_content_sha256,
  extraction_schema_version, implementation_sha256,
  extraction_receipt_sha256, started_at, completed_at
) VALUES (
  '31500000-0000-4000-8000-000000000001',
  '31300000-0000-4000-8000-000000000001',
  'connector-structured-json', 'connector-structured-json-v1', 'SUCCEEDED',
  6, encode(extensions.digest(ops.canonical_jsonb_v1(jsonb_build_array(
    '5759d5946af587202425eec1d6f2231fac1b5b13941fc0c70c553170d31deeaf',
    '8994445117b843f0f939bdef82774647fd4dcd66caaf288128418d40f20b3d5e',
    '7730d3027929745426be2e3c0619e98123263a357e3a0622ac324c36c52d61e4',
    '79d0ff92286f1703b79e51461765038229e0ca5b2786a3fde7e7013a8861fbf8',
    '2c8f9b3674474a255df9f11bc21fb1dfdfe70fc69562a2e9da568b6c5d7d1c17',
    '05660daba70ada8aa35a629b7172f759591781b77d54952204d585e2f35e462f'
  )), 'sha256'), 'hex'), repeat('1', 64), 'extraction-result.v1',
  repeat('7', 64), repeat('8', 64),
  clock_timestamp() - interval '1 second', clock_timestamp()
);

INSERT INTO raw.parsed_records(
  id, source_document_id, record_type, record_index, parser_version,
  payload, payload_sha256, parser_run_id
) VALUES
  (
    '31500000-0000-4000-8000-000000000002',
    '31300000-0000-4000-8000-000000000001', 'SUPPLIER', 0,
    'connector-structured-json-v1',
    '{"fixtureAuthority":"TEST_FIXTURE_ONLY","kind":"BID_SUPPLIER"}',
    '5759d5946af587202425eec1d6f2231fac1b5b13941fc0c70c553170d31deeaf',
    '31500000-0000-4000-8000-000000000001'
  ),
  (
    '31500000-0000-4000-8000-000000000003',
    '31300000-0000-4000-8000-000000000001', 'PROCUREMENT_NOTICE', 1,
    'connector-structured-json-v1',
    '{"fixtureAuthority":"TEST_FIXTURE_ONLY","kind":"NOTICE"}',
    '8994445117b843f0f939bdef82774647fd4dcd66caaf288128418d40f20b3d5e',
    '31500000-0000-4000-8000-000000000001'
  ),
  (
    '31500000-0000-4000-8000-000000000004',
    '31300000-0000-4000-8000-000000000001', 'SUPPLIER', 2,
    'connector-structured-json-v1',
    '{"fixtureAuthority":"TEST_FIXTURE_ONLY","kind":"SANCTION_SUPPLIER"}',
    '7730d3027929745426be2e3c0619e98123263a357e3a0622ac324c36c52d61e4',
    '31500000-0000-4000-8000-000000000001'
  ),
  (
    '31500000-0000-4000-8000-000000000005',
    '31300000-0000-4000-8000-000000000001', 'SANCTION', 3,
    'connector-structured-json-v1',
    '{"fixtureAuthority":"TEST_FIXTURE_ONLY","kind":"SANCTION"}',
    '79d0ff92286f1703b79e51461765038229e0ca5b2786a3fde7e7013a8861fbf8',
    '31500000-0000-4000-8000-000000000001'
  ),
  (
    '31500000-0000-4000-8000-000000000006',
    '31300000-0000-4000-8000-000000000001', 'PERSON_CONTEXT', 4,
    'connector-structured-json-v1',
    '{"fixtureAuthority":"TEST_FIXTURE_ONLY","kind":"FORMER_OFFICIAL"}',
    '2c8f9b3674474a255df9f11bc21fb1dfdfe70fc69562a2e9da568b6c5d7d1c17',
    '31500000-0000-4000-8000-000000000001'
  ),
  (
    '31500000-0000-4000-8000-000000000007',
    '31300000-0000-4000-8000-000000000001', 'AGENCY', 5,
    'connector-structured-json-v1',
    '{"fixtureAuthority":"TEST_FIXTURE_ONLY","kind":"FORMER_AGENCY"}',
    '05660daba70ada8aa35a629b7172f759591781b77d54952204d585e2f35e462f',
    '31500000-0000-4000-8000-000000000001'
  );

DO $$
BEGIN
  IF (SELECT count(*) FROM raw.parsed_records AS record
      WHERE record.parser_run_id =
        '31500000-0000-4000-8000-000000000001') <> 6
     OR EXISTS (
       SELECT 1
       FROM raw.parsed_records AS record
       WHERE record.parser_run_id =
               '31500000-0000-4000-8000-000000000001'
         AND btrim(record.payload_sha256) IS DISTINCT FROM encode(
               extensions.digest(
                 ops.canonical_jsonb_v1(record.payload), 'sha256'
               ), 'hex'
             )
     ) THEN
    RAISE EXCEPTION 'R6c parsed payload canonical digest invalid';
  END IF;
END $$;

SET LOCAL SESSION AUTHORIZATION gurine_ingest_worker;
DO $$
BEGIN
  IF session_user <> 'gurine_ingest_worker'
     OR current_user <> 'gurine_ingest_worker' THEN
    RAISE EXCEPTION 'R6c ingest session authorization boundary invalid';
  END IF;
END $$;

WITH fixtures(
  fixture_key, endpoint_kind, contextual_name, role_title, source_kind,
  source_locator, parsed_record_id, parsed_payload_sha256,
  entity_id, entity_revision, identifier_digest, entity_digest
) AS (
  VALUES
    (
      'bid_supplier', 'SUPPLIER', NULL::text, NULL::text,
      'KONEPS_BID_AWARD',
      'https://fixture.invalid/koneps/opening/TEST-001#supplier',
      '31500000-0000-4000-8000-000000000002'::uuid,
      '5759d5946af587202425eec1d6f2231fac1b5b13941fc0c70c553170d31deeaf',
      '31300000-0000-4000-8000-000000000011'::uuid, 1::bigint,
      (SELECT expected_digest FROM r6c_graph_digest_preimages
       WHERE digest_domain = 'IDENTIFIER' AND fixture_key = 'bid_supplier'),
      (SELECT expected_digest FROM r6c_graph_digest_preimages
       WHERE digest_domain = 'ENTITY' AND fixture_key = 'bid_supplier')
    ),
    (
      'notice', 'PROCUREMENT_NOTICE', NULL::text, NULL::text,
      'KONEPS_BID_AWARD',
      'https://fixture.invalid/koneps/opening/TEST-001',
      '31500000-0000-4000-8000-000000000003'::uuid,
      '8994445117b843f0f939bdef82774647fd4dcd66caaf288128418d40f20b3d5e',
      '31500000-0000-4000-8000-000000000103'::uuid, 1::bigint,
      (SELECT expected_digest FROM r6c_graph_digest_preimages
       WHERE digest_domain = 'IDENTIFIER' AND fixture_key = 'notice'),
      (SELECT expected_digest FROM r6c_graph_digest_preimages
       WHERE digest_domain = 'ENTITY' AND fixture_key = 'notice')
    ),
    (
      'sanction_supplier', 'SUPPLIER', NULL::text, NULL::text,
      'PPS_SANCTION_CSV',
      'https://fixture.invalid/pps-sanctions/TEST-001#supplier',
      '31500000-0000-4000-8000-000000000004'::uuid,
      '7730d3027929745426be2e3c0619e98123263a357e3a0622ac324c36c52d61e4',
      '31300000-0000-4000-8000-000000000011'::uuid, 1::bigint,
      (SELECT expected_digest FROM r6c_graph_digest_preimages
       WHERE digest_domain = 'IDENTIFIER'
         AND fixture_key = 'sanction_supplier'),
      (SELECT expected_digest FROM r6c_graph_digest_preimages
       WHERE digest_domain = 'ENTITY'
         AND fixture_key = 'sanction_supplier')
    ),
    (
      'sanction', 'SANCTION', NULL::text, NULL::text,
      'PPS_SANCTION_CSV',
      'https://fixture.invalid/pps-sanctions/TEST-001',
      '31500000-0000-4000-8000-000000000005'::uuid,
      '79d0ff92286f1703b79e51461765038229e0ca5b2786a3fde7e7013a8861fbf8',
      '31500000-0000-4000-8000-000000000105'::uuid, 1::bigint,
      (SELECT expected_digest FROM r6c_graph_digest_preimages
       WHERE digest_domain = 'IDENTIFIER' AND fixture_key = 'sanction'),
      (SELECT expected_digest FROM r6c_graph_digest_preimages
       WHERE digest_domain = 'ENTITY' AND fixture_key = 'sanction')
    ),
    (
      'person', 'PERSON', '테스트 공시 인물', '전직 담당자',
      'PUBLIC_OFFICIAL_ETHICS_NOTICE',
      'https://fixture.invalid/ethics/TEST-001#person',
      '31500000-0000-4000-8000-000000000006'::uuid,
      '2c8f9b3674474a255df9f11bc21fb1dfdfe70fc69562a2e9da568b6c5d7d1c17',
      NULL::uuid, NULL::bigint,
      (SELECT expected_digest FROM r6c_graph_digest_preimages
       WHERE digest_domain = 'IDENTIFIER' AND fixture_key = 'person'),
      NULL::text
    ),
    (
      'agency', 'AGENCY', NULL::text, NULL::text,
      'PUBLIC_OFFICIAL_ETHICS_NOTICE',
      'https://fixture.invalid/ethics/TEST-001#agency',
      '31500000-0000-4000-8000-000000000007'::uuid,
      '05660daba70ada8aa35a629b7172f759591781b77d54952204d585e2f35e462f',
      '31300000-0000-4000-8000-000000000010'::uuid, 1::bigint,
      (SELECT expected_digest FROM r6c_graph_digest_preimages
       WHERE digest_domain = 'IDENTIFIER' AND fixture_key = 'agency'),
      (SELECT expected_digest FROM r6c_graph_digest_preimages
       WHERE digest_domain = 'ENTITY' AND fixture_key = 'agency')
    )
), requests AS (
  SELECT fixture.*, jsonb_build_object(
    'schemaVersion', 'typed-relationship-endpoint.record.request.v2',
    'endpointKind', fixture.endpoint_kind,
    'contextualName', fixture.contextual_name,
    'roleTitle', fixture.role_title,
    'sourceKind', fixture.source_kind,
    'sourceLocator', fixture.source_locator,
    'identifierDigest', fixture.identifier_digest,
    'entityId', fixture.entity_id,
    'entityRevision', fixture.entity_revision,
    'entityDigest', fixture.entity_digest,
    'sourceDocument', jsonb_build_object(
      'id', '31300000-0000-4000-8000-000000000001'::uuid,
      'assetId', '31300000-0000-4000-8000-000000000001'::uuid,
      'assetRevision', 1,
      'contentSha256', repeat('1', 64),
      'parserRunId', '31500000-0000-4000-8000-000000000001'::uuid,
      'parsedRecordId', fixture.parsed_record_id,
      'parserVersion', 'connector-structured-json-v1',
      'parsedPayloadSha256', fixture.parsed_payload_sha256
    ),
    'operationId', 'recordTypedRelationshipEndpoint'
  ) AS request
  FROM fixtures AS fixture
), recorded AS (
  SELECT request.fixture_key, request.parsed_record_id,
         core.record_typed_relationship_endpoint_v2(request.request) AS result
  FROM requests AS request
)
INSERT INTO r6c_graph_endpoints(
  fixture_key, endpoint_id, endpoint_kind, endpoint_digest,
  identity_resolution_status, parsed_record_id
)
SELECT
  recorded.fixture_key,
  (recorded.result->>'endpointId')::uuid,
  recorded.result->>'endpointKind',
  recorded.result->>'endpointDigest',
  recorded.result->>'identityResolutionStatus',
  recorded.parsed_record_id
FROM recorded;

RESET SESSION AUTHORIZATION;
DO $$
BEGIN
  IF (SELECT count(*) FROM r6c_graph_endpoints) <> 6
     OR EXISTS (
       SELECT 1
       FROM r6c_graph_endpoints AS fixture
       JOIN core.relationship_graph_endpoints_v2 AS endpoint
         ON endpoint.endpoint_id = fixture.endpoint_id
       JOIN r6c_graph_digest_preimages AS identifier_preimage
         ON identifier_preimage.digest_domain = 'IDENTIFIER'
        AND identifier_preimage.fixture_key = fixture.fixture_key
       LEFT JOIN r6c_graph_digest_preimages AS entity_preimage
         ON entity_preimage.digest_domain = 'ENTITY'
        AND entity_preimage.fixture_key = fixture.fixture_key
       WHERE btrim(endpoint.identifier_digest) IS DISTINCT FROM
               btrim(identifier_preimage.expected_digest)
          OR endpoint.endpoint_payload->>'identifierDigest'
               IS DISTINCT FROM btrim(identifier_preimage.expected_digest)
          OR btrim(endpoint.entity_digest) IS DISTINCT FROM
               btrim(entity_preimage.expected_digest)
          OR endpoint.endpoint_payload->>'entityDigest'
               IS DISTINCT FROM btrim(entity_preimage.expected_digest)
          OR endpoint.endpoint_payload IS DISTINCT FROM
               convert_from(endpoint.endpoint_canonical, 'UTF8')::jsonb
          OR btrim(endpoint.endpoint_digest) IS DISTINCT FROM encode(
               extensions.digest(endpoint.endpoint_canonical, 'sha256'),
               'hex'
             )
          OR btrim(endpoint.source_locator_digest) IS DISTINCT FROM encode(
               extensions.digest(
                 convert_to(endpoint.source_locator, 'UTF8'), 'sha256'
               ), 'hex'
             )
          OR (
            endpoint.endpoint_kind = 'PERSON'
            AND btrim(endpoint.person_node_digest) IS DISTINCT FROM encode(
              extensions.digest(ops.canonical_jsonb_v1(
                jsonb_build_object(
                  'schemaVersion', 'typed-person-node-identity.v2',
                  'identifierDigest', btrim(endpoint.identifier_digest),
                  'sourceKind', endpoint.endpoint_payload->>'sourceKind',
                  'sourceLocatorDigest',
                    btrim(endpoint.source_locator_digest),
                  'sourceDocumentId', endpoint.source_document_id,
                  'sourceAssetId', endpoint.source_asset_id,
                  'sourceAssetRevision', endpoint.source_asset_revision,
                  'sourceContentSha256',
                    btrim(endpoint.source_content_sha256),
                  'parserRunId', endpoint.parser_run_id,
                  'parsedRecordId', endpoint.parsed_record_id,
                  'parserVersion', endpoint.parser_version,
                  'parsedPayloadSha256',
                    btrim(endpoint.parsed_payload_sha256)
                )
              ), 'sha256'), 'hex'
            )
          )
     ) THEN
    RAISE EXCEPTION 'R6c endpoint canonical digest binding invalid';
  END IF;
END $$;
INSERT INTO r6c_graph_endpoint_boundary(before_count)
SELECT count(*) FROM core.relationship_graph_endpoints_v2;
SET LOCAL SESSION AUTHORIZATION gurine_ingest_worker;

DO $$
DECLARE
  v_shape_denied boolean := false;
  v_identity_denied boolean := false;
BEGIN
  BEGIN
    PERFORM core.record_typed_relationship_endpoint_v2(jsonb_build_object(
      'schemaVersion', 'typed-relationship-endpoint.record.request.v2',
      'endpointKind', 'PERSON',
      'contextualName', '테스트 공시 인물',
      'roleTitle', '전직 담당자',
      'sourceKind', 'PUBLIC_OFFICIAL_ETHICS_NOTICE',
      'sourceLocator', 'https://fixture.invalid/ethics/TEST-001#person',
      'identifierDigest', repeat('5', 64),
      'entityId', NULL,
      'entityRevision', NULL,
      'entityDigest', NULL,
      'sourceDocument', jsonb_build_object(
        'id', '31300000-0000-4000-8000-000000000001'::uuid,
        'assetId', '31300000-0000-4000-8000-000000000001'::uuid,
        'assetRevision', 1,
        'contentSha256', repeat('1', 64),
        'parserRunId', '31500000-0000-4000-8000-000000000001'::uuid,
        'parsedRecordId', '31500000-0000-4000-8000-000000000006'::uuid,
        'parserVersion', 'connector-structured-json-v1',
        'parsedPayloadSha256',
          '2c8f9b3674474a255df9f11bc21fb1dfdfe70fc69562a2e9da568b6c5d7d1c17'
      ),
      'operationId', 'recordTypedRelationshipEndpoint',
      'address', 'forbidden'
    ));
  EXCEPTION WHEN SQLSTATE '22023' THEN
    v_shape_denied := SQLERRM =
      'typed_relationship_endpoint_request_shape_invalid';
  END;
  BEGIN
    PERFORM core.record_typed_relationship_endpoint_v2(jsonb_build_object(
      'schemaVersion', 'typed-relationship-endpoint.record.request.v2',
      'endpointKind', 'PERSON',
      'contextualName', '테스트 공시 인물',
      'roleTitle', '전직 담당자',
      'sourceKind', 'PUBLIC_OFFICIAL_ETHICS_NOTICE',
      'sourceLocator', 'https://fixture.invalid/ethics/TEST-001#person',
      'identifierDigest', repeat('5', 64),
      'entityId', '31500000-0000-4000-8000-000000000106'::uuid,
      'entityRevision', 1,
      'entityDigest', repeat('6', 64),
      'sourceDocument', jsonb_build_object(
        'id', '31300000-0000-4000-8000-000000000001'::uuid,
        'assetId', '31300000-0000-4000-8000-000000000001'::uuid,
        'assetRevision', 1,
        'contentSha256', repeat('1', 64),
        'parserRunId', '31500000-0000-4000-8000-000000000001'::uuid,
        'parsedRecordId', '31500000-0000-4000-8000-000000000006'::uuid,
        'parserVersion', 'connector-structured-json-v1',
        'parsedPayloadSha256',
          '2c8f9b3674474a255df9f11bc21fb1dfdfe70fc69562a2e9da568b6c5d7d1c17'
      ),
      'operationId', 'recordTypedRelationshipEndpoint'
    ));
  EXCEPTION WHEN SQLSTATE '23514' THEN
    v_identity_denied := SQLERRM = 'typed_person_endpoint_l4_boundary_invalid';
  END;
  UPDATE r6c_graph_endpoint_boundary
  SET shape_denied = v_shape_denied,
      identity_denied = v_identity_denied;
  IF NOT v_shape_denied OR NOT v_identity_denied THEN
    RAISE EXCEPTION
      'R6c PERSON endpoint closure invalid: shape %, identity %',
      v_shape_denied, v_identity_denied;
  END IF;
END $$;

RESET SESSION AUTHORIZATION;
DO $$
DECLARE
  v_boundary r6c_graph_endpoint_boundary%ROWTYPE;
BEGIN
  SELECT * INTO STRICT v_boundary FROM r6c_graph_endpoint_boundary;
  IF NOT v_boundary.shape_denied OR NOT v_boundary.identity_denied
     OR (SELECT count(*) FROM core.relationship_graph_endpoints_v2) <>
       v_boundary.before_count
     OR EXISTS (
       SELECT 1 FROM information_schema.columns AS column_contract
       WHERE column_contract.table_schema = 'core'
         AND column_contract.table_name = 'relationship_graph_endpoints_v2'
         AND column_contract.column_name ~
           'address|birth|resident|family|kinship|score|rank|probability'
     ) THEN
    RAISE EXCEPTION 'R6c PERSON endpoint admin closure invalid';
  END IF;
END $$;
SET LOCAL SESSION AUTHORIZATION gurine_ingest_worker;

WITH assertion_fixtures(
  fixture_key, assertion_id, relationship_kind, source_kind,
  source_locator, subject_key, object_key,
  valid_from, valid_to, departed_on, coverage, evidence_digest
) AS (
  VALUES
    (
      'bid', '31500000-0000-4000-8000-000000000201'::uuid,
      'BID_PARTICIPATION', 'KONEPS_BID_AWARD',
      'https://fixture.invalid/koneps/opening/TEST-001',
      'bid_supplier', 'notice', '2026-01-01'::date, NULL::date,
      NULL::date, 'COMPLETE',
      (SELECT expected_digest FROM r6c_graph_digest_preimages
       WHERE digest_domain = 'EVIDENCE' AND fixture_key = 'bid')
    ),
    (
      'sanction', '31500000-0000-4000-8000-000000000202'::uuid,
      'SANCTION', 'PPS_SANCTION_CSV',
      'https://fixture.invalid/pps-sanctions/TEST-001',
      'sanction_supplier', 'sanction', '2026-02-01'::date,
      '2026-12-31'::date, NULL::date, 'COMPLETE',
      (SELECT expected_digest FROM r6c_graph_digest_preimages
       WHERE digest_domain = 'EVIDENCE' AND fixture_key = 'sanction')
    ),
    (
      'former', '31500000-0000-4000-8000-000000000203'::uuid,
      'FORMER_OFFICIAL_ROLE', 'PUBLIC_OFFICIAL_ETHICS_NOTICE',
      'https://fixture.invalid/ethics/TEST-001',
      'person', 'agency', '2020-01-01'::date, '2024-12-31'::date,
      '2024-12-31'::date, 'COMPLETE',
      (SELECT expected_digest FROM r6c_graph_digest_preimages
       WHERE digest_domain = 'EVIDENCE' AND fixture_key = 'former')
    ),
    (
      'pending', '31500000-0000-4000-8000-000000000204'::uuid,
      'BID_PARTICIPATION', 'KONEPS_BID_AWARD',
      'https://fixture.invalid/koneps/opening/TEST-001#partial',
      'bid_supplier', 'notice', '2026-01-01'::date, NULL::date,
      NULL::date, 'PARTIAL',
      (SELECT expected_digest FROM r6c_graph_digest_preimages
       WHERE digest_domain = 'EVIDENCE' AND fixture_key = 'pending')
    )
), requests AS (
  SELECT fixture.fixture_key, core.record_typed_relationship_assertion_v2(
    jsonb_build_object(
      'schemaVersion', 'typed-relationship-assertion.record.request.v2',
      'assertionId', fixture.assertion_id,
      'relationshipKind', fixture.relationship_kind,
      'sourceKind', fixture.source_kind,
      'sourceLocator', fixture.source_locator,
      'subjectEndpoint', jsonb_build_object(
        'endpointId', subject.endpoint_id,
        'endpointKind', subject.endpoint_kind,
        'endpointDigest', btrim(subject.endpoint_digest)
      ),
      'objectEndpoint', jsonb_build_object(
        'endpointId', object_endpoint.endpoint_id,
        'endpointKind', object_endpoint.endpoint_kind,
        'endpointDigest', btrim(object_endpoint.endpoint_digest)
      ),
      'validFrom', fixture.valid_from,
      'validTo', fixture.valid_to,
      'departedOn', fixture.departed_on,
      'validityCoverageStatus', fixture.coverage,
      'evidence', jsonb_build_array(jsonb_build_object(
        'evidenceId', fixture.assertion_id,
        'evidenceVersion', 1,
        'evidenceDigest', fixture.evidence_digest,
        'sourceDocument', jsonb_build_object(
          'id', '31300000-0000-4000-8000-000000000001'::uuid,
          'assetId', '31300000-0000-4000-8000-000000000001'::uuid,
          'assetRevision', 1,
          'contentSha256', repeat('1', 64)
        ),
        'sourceUse', NULL,
        'locatorDigest', encode(extensions.digest(
          convert_to(fixture.source_locator, 'UTF8'), 'sha256'
        ), 'hex')
      )),
      'proposedActor', jsonb_build_object(
        'type', 'SERVICE', 'id', 'ingest-worker'
      ),
      'operationId', 'recordTypedRelationshipAssertion'
    )
  ) AS result
  FROM assertion_fixtures AS fixture
  JOIN r6c_graph_endpoints AS subject
    ON subject.fixture_key = fixture.subject_key
  JOIN r6c_graph_endpoints AS object_endpoint
    ON object_endpoint.fixture_key = fixture.object_key
)
INSERT INTO r6c_graph_assertions
SELECT
  request.fixture_key,
  (request.result).assertion_id,
  (request.result).assertion_revision,
  (request.result).assertion_digest,
  (request.result).receipt_sha256,
  (request.result).verification_status,
  (request.result).public_use_status,
  (request.result).disposition,
  (request.result).replayed
FROM requests AS request;

RESET SESSION AUTHORIZATION;
DO $$
BEGIN
  IF (SELECT count(*) FROM r6c_graph_assertions) <> 4
     OR EXISTS (
       SELECT 1
       FROM r6c_graph_assertions AS fixture
       JOIN core.relationship_graph_assertions_v2 AS assertion
         ON assertion.assertion_id = fixture.assertion_id
        AND assertion.assertion_revision = fixture.assertion_revision
       JOIN core.relationship_graph_assertion_evidence_v2 AS evidence
         ON evidence.assertion_id = assertion.assertion_id
        AND evidence.assertion_revision = assertion.assertion_revision
        AND evidence.evidence_ordinal = 0
       JOIN r6c_graph_digest_preimages AS evidence_preimage
         ON evidence_preimage.digest_domain = 'EVIDENCE'
        AND evidence_preimage.fixture_key = fixture.fixture_key
       WHERE btrim(assertion.assertion_digest) IS DISTINCT FROM
               btrim(fixture.assertion_digest)
          OR assertion.assertion_payload IS DISTINCT FROM
               convert_from(assertion.assertion_canonical, 'UTF8')::jsonb
          OR btrim(assertion.assertion_digest) IS DISTINCT FROM encode(
               extensions.digest(assertion.assertion_canonical, 'sha256'),
               'hex'
             )
          OR assertion.receipt_payload IS DISTINCT FROM
               convert_from(assertion.receipt_canonical, 'UTF8')::jsonb
          OR btrim(assertion.receipt_sha256) IS DISTINCT FROM encode(
               extensions.digest(assertion.receipt_canonical, 'sha256'),
               'hex'
             )
          OR assertion.assertion_payload->'proposedActor' IS DISTINCT FROM
               jsonb_build_object('type', 'SERVICE', 'id', 'ingest-worker')
          OR btrim(evidence.evidence_digest) IS DISTINCT FROM
               btrim(evidence_preimage.expected_digest)
          OR convert_from(evidence.evidence_binding_canonical, 'UTF8')::jsonb
               ->>'evidenceDigest' IS DISTINCT FROM
               btrim(evidence_preimage.expected_digest)
          OR btrim(evidence.evidence_member_digest) IS DISTINCT FROM encode(
               extensions.digest(
                 evidence.evidence_binding_canonical, 'sha256'
               ), 'hex'
             )
          OR btrim(assertion.evidence_set_digest) IS DISTINCT FROM encode(
               extensions.digest(ops.canonical_jsonb_v1(
                 jsonb_build_array(btrim(evidence.evidence_member_digest))
               ), 'sha256'), 'hex'
             )
     ) THEN
    RAISE EXCEPTION 'R6c assertion canonical digest binding invalid';
  END IF;
END $$;
INSERT INTO r6c_graph_assertion_boundary(before_count)
SELECT count(*) FROM core.relationship_graph_assertions_v2;
SET LOCAL SESSION AUTHORIZATION gurine_ingest_worker;

DO $$
DECLARE
  v_family_denied boolean := false;
  v_subject r6c_graph_endpoints%ROWTYPE;
  v_object r6c_graph_endpoints%ROWTYPE;
BEGIN
  SELECT * INTO STRICT v_subject FROM r6c_graph_endpoints
  WHERE fixture_key = 'person';
  SELECT * INTO STRICT v_object FROM r6c_graph_endpoints
  WHERE fixture_key = 'agency';
  BEGIN
    PERFORM * FROM core.record_typed_relationship_assertion_v2(
      jsonb_build_object(
        'schemaVersion', 'typed-relationship-assertion.record.request.v2',
        'assertionId', '31500000-0000-4000-8000-000000000209'::uuid,
        'relationshipKind', 'FAMILY',
        'sourceKind', 'PUBLIC_OFFICIAL_ETHICS_NOTICE',
        'sourceLocator', 'https://fixture.invalid/forbidden-family',
        'subjectEndpoint', jsonb_build_object(
          'endpointId', v_subject.endpoint_id,
          'endpointKind', v_subject.endpoint_kind,
          'endpointDigest', btrim(v_subject.endpoint_digest)
        ),
        'objectEndpoint', jsonb_build_object(
          'endpointId', v_object.endpoint_id,
          'endpointKind', v_object.endpoint_kind,
          'endpointDigest', btrim(v_object.endpoint_digest)
        ),
        'validFrom', NULL,
        'validTo', NULL,
        'departedOn', NULL,
        'validityCoverageStatus', 'COMPLETE',
        'evidence', jsonb_build_array(jsonb_build_object(
          'evidenceId', '31500000-0000-4000-8000-000000000209'::uuid,
          'evidenceVersion', 1,
          'evidenceDigest', repeat('9', 64),
          'sourceDocument', jsonb_build_object(
            'id', '31300000-0000-4000-8000-000000000001'::uuid,
            'assetId', '31300000-0000-4000-8000-000000000001'::uuid,
            'assetRevision', 1,
            'contentSha256', repeat('1', 64)
          ),
          'sourceUse', NULL,
          'locatorDigest', repeat('8', 64)
        )),
        'proposedActor', jsonb_build_object(
          'type', 'SERVICE', 'id', 'ingest-worker'
        ),
        'operationId', 'recordTypedRelationshipAssertion'
      )
    );
  EXCEPTION WHEN SQLSTATE '22023' THEN
    v_family_denied := SQLERRM = 'typed_relationship_assertion_value_invalid';
  END;
  UPDATE r6c_graph_assertion_boundary
  SET family_denied = v_family_denied;
  IF NOT v_family_denied THEN
    RAISE EXCEPTION 'R6c family relationship closure invalid';
  END IF;
END $$;

DO $$
DECLARE
  v_subject r6c_graph_endpoints%ROWTYPE;
  v_object r6c_graph_endpoints%ROWTYPE;
  v_base jsonb;
  v_oversized jsonb;
  v_zero_denied boolean := false;
  v_oversized_denied boolean := false;
  v_pair_denied boolean := false;
BEGIN
  SELECT * INTO STRICT v_subject FROM r6c_graph_endpoints
  WHERE fixture_key = 'person';
  SELECT * INTO STRICT v_object FROM r6c_graph_endpoints
  WHERE fixture_key = 'agency';
  v_base := jsonb_build_object(
    'schemaVersion', 'typed-relationship-assertion.record.request.v2',
    'assertionId', '31500000-0000-4000-8000-000000000210'::uuid,
    'relationshipKind', 'BID_PARTICIPATION',
    'sourceKind', 'PUBLIC_OFFICIAL_ETHICS_NOTICE',
    'sourceLocator', 'https://fixture.invalid/negative-relationship',
    'subjectEndpoint', jsonb_build_object(
      'endpointId', v_subject.endpoint_id,
      'endpointKind', v_subject.endpoint_kind,
      'endpointDigest', btrim(v_subject.endpoint_digest)
    ),
    'objectEndpoint', jsonb_build_object(
      'endpointId', v_object.endpoint_id,
      'endpointKind', v_object.endpoint_kind,
      'endpointDigest', btrim(v_object.endpoint_digest)
    ),
    'validFrom', NULL,
    'validTo', NULL,
    'departedOn', NULL,
    'validityCoverageStatus', 'COMPLETE',
    'evidence', jsonb_build_array(jsonb_build_object(
      'evidenceId', '31500000-0000-4000-8000-000000000210'::uuid,
      'evidenceVersion', 1,
      'evidenceDigest', repeat('a', 64),
      'sourceDocument', jsonb_build_object(
        'id', '31300000-0000-4000-8000-000000000001'::uuid,
        'assetId', '31300000-0000-4000-8000-000000000001'::uuid,
        'assetRevision', 1,
        'contentSha256', repeat('1', 64)
      ),
      'sourceUse', NULL,
      'locatorDigest', repeat('b', 64)
    )),
    'proposedActor', jsonb_build_object(
      'type', 'SERVICE', 'id', 'ingest-worker'
    ),
    'operationId', 'recordTypedRelationshipAssertion'
  );
  BEGIN
    PERFORM * FROM core.record_typed_relationship_assertion_v2(
      jsonb_set(v_base, '{evidence}', '[]'::jsonb)
    );
  EXCEPTION WHEN SQLSTATE '22023' THEN
    v_zero_denied := SQLERRM =
      'typed_relationship_assertion_request_invalid';
  END;
  SELECT jsonb_agg('{}'::jsonb ORDER BY ordinal)
  INTO STRICT v_oversized
  FROM generate_series(1, 1001) AS item(ordinal);
  BEGIN
    PERFORM * FROM core.record_typed_relationship_assertion_v2(
      jsonb_set(
        jsonb_set(
          v_base, '{assertionId}',
          to_jsonb('31500000-0000-4000-8000-000000000211'::text)
        ),
        '{evidence}', v_oversized
      )
    );
  EXCEPTION WHEN SQLSTATE '22023' THEN
    v_oversized_denied := SQLERRM =
      'typed_relationship_assertion_request_invalid';
  END;
  BEGIN
    PERFORM * FROM core.record_typed_relationship_assertion_v2(
      jsonb_set(
        v_base, '{assertionId}',
        to_jsonb('31500000-0000-4000-8000-000000000212'::text)
      )
    );
  EXCEPTION WHEN SQLSTATE '23514' THEN
    v_pair_denied := SQLERRM LIKE
      '%relationship_graph_assertions_v2_pair_ck%';
  END;
  UPDATE r6c_graph_assertion_boundary
  SET zero_denied = v_zero_denied,
      oversized_denied = v_oversized_denied,
      pair_denied = v_pair_denied;
  IF NOT v_zero_denied OR NOT v_oversized_denied OR NOT v_pair_denied THEN
    RAISE EXCEPTION
      'R6c assertion boundary invalid: zero %, oversized %, pair %',
      v_zero_denied, v_oversized_denied, v_pair_denied;
  END IF;
END $$;

RESET SESSION AUTHORIZATION;
DO $$
DECLARE
  v_boundary r6c_graph_assertion_boundary%ROWTYPE;
BEGIN
  SELECT * INTO STRICT v_boundary FROM r6c_graph_assertion_boundary;
  IF NOT v_boundary.family_denied OR NOT v_boundary.zero_denied
     OR NOT v_boundary.oversized_denied OR NOT v_boundary.pair_denied
     OR (SELECT count(*) FROM core.relationship_graph_assertions_v2) <>
       v_boundary.before_count
     OR EXISTS (
       SELECT 1 FROM pg_constraint AS contract
       WHERE contract.conrelid =
         'core.relationship_graph_assertions_v2'::regclass
         AND pg_get_constraintdef(contract.oid) ~* 'family|kinship|relative'
     ) THEN
    RAISE EXCEPTION 'R6c relationship assertion admin closure invalid';
  END IF;
END $$;
SET LOCAL SESSION AUTHORIZATION gurine_identity_api;
DO $$
BEGIN
  IF session_user <> 'gurine_identity_api'
     OR current_user <> 'gurine_identity_api' THEN
    RAISE EXCEPTION 'R6c identity session authorization boundary invalid';
  END IF;
END $$;

DO $$
DECLARE
  v_assertion_id constant uuid :=
    '31500000-0000-4000-8000-000000000205';
  v_actor_id constant uuid :=
    '31000000-0000-4000-8000-000000000001';
  v_subject r6c_graph_endpoints%ROWTYPE;
  v_object r6c_graph_endpoints%ROWTYPE;
  v_request jsonb;
  v_result record;
  v_missing_denied boolean := false;
  v_mismatch_denied boolean := false;
BEGIN
  SELECT * INTO STRICT v_subject
  FROM r6c_graph_endpoints WHERE fixture_key = 'bid_supplier';
  SELECT * INTO STRICT v_object
  FROM r6c_graph_endpoints WHERE fixture_key = 'notice';
  v_request := jsonb_build_object(
    'schemaVersion', 'typed-relationship-assertion.record.request.v2',
    'assertionId', v_assertion_id,
    'relationshipKind', 'BID_PARTICIPATION',
    'sourceKind', 'KONEPS_BID_AWARD',
    'sourceLocator',
      'https://fixture.invalid/koneps/opening/TEST-HUMAN-PROPOSAL',
    'subjectEndpoint', jsonb_build_object(
      'endpointId', v_subject.endpoint_id,
      'endpointKind', v_subject.endpoint_kind,
      'endpointDigest', btrim(v_subject.endpoint_digest)
    ),
    'objectEndpoint', jsonb_build_object(
      'endpointId', v_object.endpoint_id,
      'endpointKind', v_object.endpoint_kind,
      'endpointDigest', btrim(v_object.endpoint_digest)
    ),
    'validFrom', '2026-01-01'::date,
    'validTo', NULL,
    'departedOn', NULL,
    'validityCoverageStatus', 'COMPLETE',
    'evidence', jsonb_build_array(jsonb_build_object(
      'evidenceId', v_assertion_id,
      'evidenceVersion', 1,
      'evidenceDigest', (
        SELECT expected_digest FROM r6c_graph_digest_preimages
        WHERE digest_domain = 'EVIDENCE'
          AND fixture_key = 'human_proposal'
      ),
      'sourceDocument', jsonb_build_object(
        'id', '31300000-0000-4000-8000-000000000001'::uuid,
        'assetId', '31300000-0000-4000-8000-000000000001'::uuid,
        'assetRevision', 1,
        'contentSha256', repeat('1', 64)
      ),
      'sourceUse', NULL,
      'locatorDigest', encode(extensions.digest(
        convert_to(
          'https://fixture.invalid/koneps/opening/TEST-HUMAN-PROPOSAL',
          'UTF8'
        ), 'sha256'
      ), 'hex')
    )),
    'proposedActor', jsonb_build_object(
      'type', 'HUMAN', 'id', v_actor_id
    ),
    'operationId', 'recordTypedRelationshipAssertion'
  );

  PERFORM set_config('gurine.actor_user_id', '', true);
  BEGIN
    PERFORM * FROM core.record_typed_relationship_assertion_v2(v_request);
  EXCEPTION WHEN SQLSTATE '28000' THEN
    v_missing_denied := SQLERRM =
      'typed_relationship_human_proposer_mismatch';
  END;

  PERFORM set_config(
    'gurine.actor_user_id',
    '31000000-0000-4000-8000-000000000002',
    true
  );
  BEGIN
    PERFORM * FROM core.record_typed_relationship_assertion_v2(v_request);
  EXCEPTION WHEN SQLSTATE '28000' THEN
    v_mismatch_denied := SQLERRM =
      'typed_relationship_human_proposer_mismatch';
  END;

  PERFORM set_config('gurine.actor_user_id', v_actor_id::text, true);
  SELECT * INTO STRICT v_result
  FROM core.record_typed_relationship_assertion_v2(v_request);
  IF NOT v_missing_denied OR NOT v_mismatch_denied
     OR v_result.assertion_id IS DISTINCT FROM v_assertion_id
     OR v_result.assertion_revision IS DISTINCT FROM 1
     OR v_result.verification_status IS DISTINCT FROM 'PENDING_HUMAN'
     OR v_result.public_use_status IS DISTINCT FROM 'NOT_REVIEWED'
     OR v_result.disposition IS DISTINCT FROM 'PENDING_HUMAN'
     OR v_result.replayed IS DISTINCT FROM false THEN
    RAISE EXCEPTION
      'R6c human proposer actor binding invalid: missing %, mismatch %',
      v_missing_denied, v_mismatch_denied;
  END IF;
END $$;

RESET SESSION AUTHORIZATION;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM core.relationship_graph_assertions_v2 AS assertion
    JOIN core.relationship_graph_assertion_evidence_v2 AS evidence
      ON evidence.assertion_id = assertion.assertion_id
     AND evidence.assertion_revision = assertion.assertion_revision
     AND evidence.evidence_ordinal = 0
    JOIN r6c_graph_digest_preimages AS evidence_preimage
      ON evidence_preimage.digest_domain = 'EVIDENCE'
     AND evidence_preimage.fixture_key = 'human_proposal'
    WHERE assertion.assertion_id =
            '31500000-0000-4000-8000-000000000205'
      AND assertion.assertion_revision = 1
      AND assertion.proposed_actor_type = 'HUMAN'
      AND assertion.proposed_actor_id =
            '31000000-0000-4000-8000-000000000001'
      AND assertion.proposed_by =
            '31000000-0000-4000-8000-000000000001'
      AND assertion.verification_status = 'PENDING_HUMAN'
      AND assertion.public_use_status = 'NOT_REVIEWED'
      AND assertion.verified_by IS NULL
      AND assertion.assertion_payload->'proposedActor' =
            jsonb_build_object(
              'type', 'HUMAN',
              'id', '31000000-0000-4000-8000-000000000001'::uuid
            )
      AND assertion.assertion_payload =
            convert_from(assertion.assertion_canonical, 'UTF8')::jsonb
      AND btrim(assertion.assertion_digest) = encode(
            extensions.digest(assertion.assertion_canonical, 'sha256'),
            'hex'
          )
      AND assertion.receipt_payload =
            convert_from(assertion.receipt_canonical, 'UTF8')::jsonb
      AND btrim(assertion.receipt_sha256) = encode(
            extensions.digest(assertion.receipt_canonical, 'sha256'),
            'hex'
          )
      AND btrim(evidence.evidence_digest) =
            btrim(evidence_preimage.expected_digest)
      AND convert_from(evidence.evidence_binding_canonical, 'UTF8')::jsonb
            ->>'evidenceDigest' = btrim(evidence_preimage.expected_digest)
      AND btrim(evidence.evidence_member_digest) = encode(
            extensions.digest(evidence.evidence_binding_canonical, 'sha256'),
            'hex'
          )
  ) THEN
    RAISE EXCEPTION 'R6c human proposer persisted binding invalid';
  END IF;
END $$;
SET LOCAL SESSION AUTHORIZATION gurine_identity_api;

DO $$
DECLARE
  v_assertion_id uuid;
  v_missing_denied boolean := false;
  v_mismatch_denied boolean := false;
BEGIN
  SELECT assertion_id INTO STRICT v_assertion_id
  FROM r6c_graph_assertions WHERE fixture_key = 'bid';
  PERFORM set_config('gurine.actor_user_id', '', true);
  BEGIN
    PERFORM * FROM core.decide_typed_relationship_assertion_v2(
      v_assertion_id,
      jsonb_build_object(
        'schemaVersion', 'typed-relationship-assertion.decision.request.v2',
        'decision', 'VERIFY',
        'reasonCode', 'TEST_FIXTURE_ONLY_MISSING_ACTOR',
        'reason', 'Missing session actor must fail closed',
        'actorUserId', '31000000-0000-4000-8000-000000000002'::uuid,
        'operationId', 'decideTypedRelationshipAssertion'
      )
    );
  EXCEPTION WHEN SQLSTATE '28000' THEN
    v_missing_denied := SQLERRM =
      'typed_relationship_reviewer_mismatch';
  END;
  PERFORM set_config(
    'gurine.actor_user_id',
    '31000000-0000-4000-8000-000000000001',
    true
  );
  BEGIN
    PERFORM * FROM core.decide_typed_relationship_assertion_v2(
      v_assertion_id,
      jsonb_build_object(
        'schemaVersion', 'typed-relationship-assertion.decision.request.v2',
        'decision', 'VERIFY',
        'reasonCode', 'TEST_FIXTURE_ONLY_MISMATCHED_ACTOR',
        'reason', 'Mismatched session actor must fail closed',
        'actorUserId', '31000000-0000-4000-8000-000000000002'::uuid,
        'operationId', 'decideTypedRelationshipAssertion'
      )
    );
  EXCEPTION WHEN SQLSTATE '28000' THEN
    v_mismatch_denied := SQLERRM =
      'typed_relationship_reviewer_mismatch';
  END;
  IF NOT v_missing_denied OR NOT v_mismatch_denied THEN
    RAISE EXCEPTION
      'R6c reviewer actor binding invalid: missing %, mismatch %',
      v_missing_denied, v_mismatch_denied;
  END IF;
END $$;

SET LOCAL gurine.actor_user_id = '31000000-0000-4000-8000-000000000002';

WITH decisions AS (
  SELECT assertion.fixture_key,
         core.decide_typed_relationship_assertion_v2(
           assertion.assertion_id,
           jsonb_build_object(
             'schemaVersion',
               'typed-relationship-assertion.decision.request.v2',
             'decision', 'VERIFY',
             'reasonCode', 'TEST_FIXTURE_ONLY_VERIFIED',
             'reason', 'R6c typed graph runtime fixture independent review',
             'actorUserId',
               '31000000-0000-4000-8000-000000000002'::uuid,
             'operationId', 'decideTypedRelationshipAssertion'
           )
         ) AS result
  FROM r6c_graph_assertions AS assertion
  WHERE assertion.fixture_key IN ('bid', 'sanction', 'former')
)
INSERT INTO r6c_graph_decisions
SELECT
  decision.fixture_key,
  (decision.result).decision_id,
  (decision.result).assertion_id,
  (decision.result).assertion_revision,
  (decision.result).assertion_digest,
  (decision.result).verification_status,
  (decision.result).public_use_status,
  (decision.result).receipt_sha256,
  (decision.result).replayed
FROM decisions AS decision;

DO $$
DECLARE
  v_pending uuid;
  v_denied boolean := false;
BEGIN
  SELECT assertion_id INTO STRICT v_pending
  FROM r6c_graph_assertions WHERE fixture_key = 'pending';
  BEGIN
    PERFORM * FROM core.decide_typed_relationship_assertion_v2(
      v_pending,
      jsonb_build_object(
        'schemaVersion', 'typed-relationship-assertion.decision.request.v2',
        'decision', 'VERIFY',
        'reasonCode', 'TEST_FIXTURE_ONLY_PARTIAL',
        'reason', 'Partial coverage must not become verified',
        'actorUserId', '31000000-0000-4000-8000-000000000002'::uuid,
        'operationId', 'decideTypedRelationshipAssertion'
      )
    );
  EXCEPTION WHEN SQLSTATE '23514' THEN
    v_denied := SQLERRM =
      'typed_relationship_verify_requires_complete_coverage';
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'R6c partial relationship verification was not denied';
  END IF;
END $$;

RESET SESSION AUTHORIZATION;

CREATE TEMP TABLE r6c_graph_snapshot(
  snapshot_id uuid PRIMARY KEY,
  producer_generation bigint NOT NULL,
  snapshot_sha256 char(64),
  member_count bigint NOT NULL
);
GRANT SELECT ON r6c_graph_snapshot TO gurine_analysis_worker;

DO $$
DECLARE
  v_snapshot_id constant uuid :=
    '31500000-0000-4000-8000-000000000300';
  v_job_id constant uuid :=
    '31500000-0000-4000-8000-000000000301';
  v_selection jsonb := jsonb_build_object(
    'fixtureAuthority', 'TEST_FIXTURE_ONLY',
    'purpose', 'R6c typed graph v3 runtime proof'
  );
  v_watermarks jsonb := jsonb_build_object(
    'sourceDocumentId', '31300000-0000-4000-8000-000000000001'::uuid
  );
  v_normalization jsonb := jsonb_build_object(
    'parserVersion', 'connector-structured-json-v1'
  );
  v_producer_digest char(64);
  v_build_digest char(64);
  v_build_audit uuid;
BEGIN
  v_producer_digest := encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion', 'r6c-typed-graph-snapshot-producer.v1',
      'fixtureAuthority', 'TEST_FIXTURE_ONLY'
    )), 'sha256'
  ), 'hex');
  v_build_digest := encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'snapshotId', v_snapshot_id,
      'snapshotKind', 'AGENT_CASE',
      'producerJobId', v_job_id,
      'producerKey', 'r6c-typed-graph-runtime',
      'producerDigest', btrim(v_producer_digest)
    )), 'sha256'
  ), 'hex');
  INSERT INTO ops.jobs(
    id, job_type, queue, status, payload, dedupe_key
  ) VALUES (
    v_job_id, 'SNAPSHOT_BUILD', 'analysis-worker', 'RUNNING',
    jsonb_build_object(
      'fixtureAuthority', 'TEST_FIXTURE_ONLY',
      'snapshotId', v_snapshot_id
    ), 'r6c-typed-graph-snapshot-runtime'
  );
  v_build_audit := ops.append_audit_event(
    'r6c-typed-graph-snapshot:' || v_snapshot_id::text,
    'SERVICE', 'analysis-worker', NULL,
    'DATASET_SNAPSHOT_BUILD_STARTED', 'DatasetSnapshot',
    v_snapshot_id::text, 'jobs.operate', 'SUCCESS', NULL, v_job_id,
    jsonb_build_object(
      'snapshotId', v_snapshot_id,
      'snapshotKind', 'AGENT_CASE',
      'producerJobId', v_job_id,
      'buildRequestSha256', btrim(v_build_digest),
      'fixtureAuthority', 'TEST_FIXTURE_ONLY'
    )
  );
  INSERT INTO r6c_graph_snapshot(
    snapshot_id, producer_generation, snapshot_sha256, member_count
  )
  SELECT begun.snapshot_id, begun.producer_generation,
         begun.snapshot_sha256, 4
  FROM core.begin_dataset_snapshot(
    'AGENT_CASE', v_job_id, 'r6c-typed-graph-runtime',
    v_producer_digest, 'dataset-snapshot.v1',
    v_selection, ops.canonical_jsonb_v1(v_selection),
    v_watermarks, ops.canonical_jsonb_v1(v_watermarks),
    v_normalization, ops.canonical_jsonb_v1(v_normalization),
    v_build_digest, v_build_audit
  ) AS begun;
END $$;

DO $$
DECLARE
  v_snapshot r6c_graph_snapshot%ROWTYPE;
  v_assertion record;
  v_member_id uuid;
  v_member_ordinal bigint := 0;
  v_member_binding bytea;
  v_member_digest char(64);
  v_source_zero_id uuid;
  v_source_one_id uuid;
  v_source_zero bytea;
  v_source_one bytea;
  v_source_zero_digest char(64);
  v_source_one_digest char(64);
  v_source_set_digest char(64);
  v_subject_record_id uuid;
  v_object_record_id uuid;
BEGIN
  SELECT * INTO STRICT v_snapshot FROM r6c_graph_snapshot;
  FOR v_assertion IN
    SELECT
      frozen.fixture_key,
      assertion.assertion_id,
      assertion.assertion_revision,
      assertion.assertion_digest,
      assertion.assertion_payload,
      assertion.assertion_canonical,
      subject_endpoint.parsed_record_id AS subject_record_id,
      object_endpoint.parsed_record_id AS object_record_id
    FROM (
      SELECT fixture_key, assertion_id, assertion_revision
      FROM r6c_graph_decisions
      UNION ALL
      SELECT fixture_key, assertion_id, assertion_revision
      FROM r6c_graph_assertions WHERE fixture_key = 'pending'
    ) AS frozen
    JOIN core.relationship_graph_assertions_v2 AS assertion
      ON assertion.assertion_id = frozen.assertion_id
     AND assertion.assertion_revision = frozen.assertion_revision
    JOIN core.relationship_graph_endpoints_v2 AS subject_endpoint
      ON subject_endpoint.endpoint_id = assertion.subject_endpoint_id
    JOIN core.relationship_graph_endpoints_v2 AS object_endpoint
      ON object_endpoint.endpoint_id = assertion.object_endpoint_id
    ORDER BY CASE frozen.fixture_key
      WHEN 'bid' THEN 0 WHEN 'sanction' THEN 1
      WHEN 'former' THEN 2 ELSE 3 END
  LOOP
    v_member_id := (
      '31500000-0000-4000-8000-' ||
      lpad((400 + v_member_ordinal)::text, 12, '0')
    )::uuid;
    v_source_zero_id := (
      '31500000-0000-4000-8000-' ||
      lpad((410 + v_member_ordinal * 2)::text, 12, '0')
    )::uuid;
    v_source_one_id := (
      '31500000-0000-4000-8000-' ||
      lpad((411 + v_member_ordinal * 2)::text, 12, '0')
    )::uuid;
    v_subject_record_id := v_assertion.subject_record_id;
    v_object_record_id := v_assertion.object_record_id;
    v_source_zero := ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion', 'dataset-snapshot-member-source.v1',
      'snapshotId', v_snapshot.snapshot_id,
      'snapshotMemberId', v_member_id,
      'memberOrdinal', v_member_ordinal,
      'sourceOrdinal', 0,
      'lineageKind', 'PARSED_RECORD',
      'sourceKind', 'SOURCE_DOCUMENT',
      'sourceDocumentId', '31300000-0000-4000-8000-000000000001'::uuid,
      'sourceAssetId', '31300000-0000-4000-8000-000000000001'::uuid,
      'sourceAssetRevision', 1,
      'sourceContentSha256', repeat('1', 64),
      'parserRunId', '31500000-0000-4000-8000-000000000001'::uuid,
      'parsedRecordId', v_subject_record_id
    ));
    v_source_one := ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion', 'dataset-snapshot-member-source.v1',
      'snapshotId', v_snapshot.snapshot_id,
      'snapshotMemberId', v_member_id,
      'memberOrdinal', v_member_ordinal,
      'sourceOrdinal', 1,
      'lineageKind', 'PARSED_RECORD',
      'sourceKind', 'SOURCE_DOCUMENT',
      'sourceDocumentId', '31300000-0000-4000-8000-000000000001'::uuid,
      'sourceAssetId', '31300000-0000-4000-8000-000000000001'::uuid,
      'sourceAssetRevision', 1,
      'sourceContentSha256', repeat('1', 64),
      'parserRunId', '31500000-0000-4000-8000-000000000001'::uuid,
      'parsedRecordId', v_object_record_id
    ));
    v_source_zero_digest := encode(
      extensions.digest(v_source_zero, 'sha256'), 'hex'
    );
    v_source_one_digest := encode(
      extensions.digest(v_source_one, 'sha256'), 'hex'
    );
    v_source_set_digest := encode(extensions.digest(
      ops.canonical_jsonb_v1(jsonb_build_array(
        btrim(v_source_zero_digest), btrim(v_source_one_digest)
      )), 'sha256'
    ), 'hex');
    v_member_binding := ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion', 'dataset-snapshot-member-binding.v1',
      'snapshotId', v_snapshot.snapshot_id,
      'snapshotMemberId', v_member_id,
      'snapshotKind', 'AGENT_CASE',
      'producerGeneration', v_snapshot.producer_generation,
      'snapshotContractVersion', 1,
      'memberOrdinal', v_member_ordinal,
      'objectType', 'TYPED_RELATIONSHIP_ASSERTION',
      'objectId', v_assertion.assertion_id,
      'objectVersion', v_assertion.assertion_revision,
      'objectSchemaVersion', 'typed-relationship-assertion.v2',
      'objectContentSha256', btrim(v_assertion.assertion_digest),
      'payloadSha256', btrim(v_assertion.assertion_digest),
      'normalizationRunId', NULL,
      'normalizationVersion', NULL,
      'normalizationSha256', NULL,
      'evidenceSegmentId', NULL,
      'responseId', NULL,
      'sourceCount', 2,
      'sourceSetSha256', btrim(v_source_set_digest)
    ));
    v_member_digest := encode(
      extensions.digest(v_member_binding, 'sha256'), 'hex'
    );
    INSERT INTO core.dataset_snapshot_members(
      id, dataset_snapshot_id, snapshot_kind, producer_generation,
      snapshot_contract_version, member_ordinal, object_type, object_id,
      object_version, object_schema_version, object_content_sha256,
      canonical_payload, canonical_payload_bytes, payload_sha256,
      normalization_run_id, normalization_version, normalization_sha256,
      evidence_segment_id, response_id, source_count, source_set_sha256,
      member_binding_canonical, member_digest
    ) VALUES (
      v_member_id, v_snapshot.snapshot_id, 'AGENT_CASE',
      v_snapshot.producer_generation, 1, v_member_ordinal,
      'TYPED_RELATIONSHIP_ASSERTION', v_assertion.assertion_id,
      v_assertion.assertion_revision, 'typed-relationship-assertion.v2',
      v_assertion.assertion_digest, v_assertion.assertion_payload,
      v_assertion.assertion_canonical, v_assertion.assertion_digest,
      NULL, NULL, NULL, NULL, NULL, 2, v_source_set_digest,
      v_member_binding, v_member_digest
    );
    INSERT INTO core.dataset_snapshot_member_sources(
      id, dataset_snapshot_id, snapshot_member_id, member_ordinal,
      snapshot_member_digest, source_ordinal, lineage_kind, source_kind,
      source_document_id, source_asset_id, source_asset_revision,
      source_content_sha256, parser_run_id, parsed_record_id, source_digest
    ) VALUES
      (
        v_source_zero_id, v_snapshot.snapshot_id, v_member_id,
        v_member_ordinal, v_member_digest, 0, 'PARSED_RECORD',
        'SOURCE_DOCUMENT',
        '31300000-0000-4000-8000-000000000001',
        '31300000-0000-4000-8000-000000000001', 1, repeat('1', 64),
        '31500000-0000-4000-8000-000000000001',
        v_subject_record_id, v_source_zero_digest
      ),
      (
        v_source_one_id, v_snapshot.snapshot_id, v_member_id,
        v_member_ordinal, v_member_digest, 1, 'PARSED_RECORD',
        'SOURCE_DOCUMENT',
        '31300000-0000-4000-8000-000000000001',
        '31300000-0000-4000-8000-000000000001', 1, repeat('1', 64),
        '31500000-0000-4000-8000-000000000001',
        v_object_record_id, v_source_one_digest
      );
    v_member_ordinal := v_member_ordinal + 1;
  END LOOP;
END $$;

DO $$
BEGIN
  IF (SELECT count(*) FROM core.dataset_snapshot_members AS member
      JOIN r6c_graph_snapshot AS snapshot
        ON snapshot.snapshot_id = member.dataset_snapshot_id) <> 4
     OR EXISTS (
       SELECT 1
       FROM core.dataset_snapshot_members AS member
       JOIN r6c_graph_snapshot AS snapshot
         ON snapshot.snapshot_id = member.dataset_snapshot_id
       WHERE member.canonical_payload_bytes IS DISTINCT FROM
               ops.canonical_jsonb_v1(member.canonical_payload)
          OR btrim(member.payload_sha256) IS DISTINCT FROM encode(
               extensions.digest(member.canonical_payload_bytes, 'sha256'),
               'hex'
             )
          OR member.payload_sha256 IS DISTINCT FROM
               member.object_content_sha256
     ) THEN
    RAISE EXCEPTION 'R6c graph snapshot canonical payload digest invalid';
  END IF;
END $$;

DO $$
DECLARE
  v_snapshot r6c_graph_snapshot%ROWTYPE;
  v_job_id constant uuid :=
    '31500000-0000-4000-8000-000000000301';
  v_member_set char(64);
  v_manifest jsonb;
  v_manifest_canonical bytea;
  v_terminal_payload jsonb;
  v_terminal_receipt char(64);
  v_terminal_audit uuid;
  v_final record;
BEGIN
  SELECT * INTO STRICT v_snapshot FROM r6c_graph_snapshot;
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
    'memberCount', 4,
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
    'memberCount', 4,
    'memberSetSha256', btrim(v_member_set),
    'fixtureAuthority', 'TEST_FIXTURE_ONLY'
  );
  v_terminal_receipt := encode(extensions.digest(
    ops.canonical_jsonb_v1(v_terminal_payload), 'sha256'
  ), 'hex');
  v_terminal_audit := ops.append_audit_event(
    'r6c-typed-graph-snapshot:' || v_snapshot.snapshot_id::text,
    'SERVICE', 'analysis-worker', NULL,
    'DATASET_SNAPSHOT_READY', 'DatasetSnapshot',
    v_snapshot.snapshot_id::text, 'jobs.operate', 'SUCCESS', NULL, v_job_id,
    jsonb_build_object(
      'snapshotId', v_snapshot.snapshot_id,
      'state', 'READY',
      'terminalReceiptDigest', btrim(v_terminal_receipt),
      'fixtureAuthority', 'TEST_FIXTURE_ONLY'
    )
  );
  SELECT * INTO STRICT v_final FROM core.finalize_dataset_snapshot(
    v_snapshot.snapshot_id, 1, 'READY', 4, v_member_set,
    v_manifest, v_manifest_canonical, v_terminal_receipt,
    v_terminal_audit, NULL, NULL
  );
  UPDATE r6c_graph_snapshot
  SET snapshot_sha256 = v_final.snapshot_sha256
  WHERE snapshot_id = v_snapshot.snapshot_id;
END $$;

INSERT INTO core.dataset_snapshot_relationship_assertions_v2(
  dataset_snapshot_id, snapshot_sha256, snapshot_generation,
  assertion_ordinal, assertion_id, assertion_revision, assertion_digest,
  binding_canonical, binding_digest
)
SELECT
  snapshot.snapshot_id, snapshot.snapshot_sha256,
  snapshot.producer_generation, member.member_ordinal,
  member.object_id, member.object_version, member.object_content_sha256,
  binding.canonical,
  encode(extensions.digest(binding.canonical, 'sha256'), 'hex')
FROM r6c_graph_snapshot AS snapshot
JOIN core.dataset_snapshot_members AS member
  ON member.dataset_snapshot_id = snapshot.snapshot_id
CROSS JOIN LATERAL (
  SELECT ops.canonical_jsonb_v1(jsonb_build_object(
    'schemaVersion', 'dataset-snapshot-relationship-binding.v2',
    'snapshotId', snapshot.snapshot_id,
    'snapshotSha256', btrim(snapshot.snapshot_sha256),
    'snapshotGeneration', snapshot.producer_generation,
    'assertionOrdinal', member.member_ordinal,
    'assertionId', member.object_id,
    'assertionRevision', member.object_version,
    'assertionDigest', btrim(member.object_content_sha256)
  )) AS canonical
) AS binding;

CREATE TEMP TABLE r6c_graph_runs(
  ordinal integer PRIMARY KEY,
  run_id uuid NOT NULL,
  job_id uuid NOT NULL,
  lease_token uuid NOT NULL
);
INSERT INTO r6c_graph_runs VALUES
  (
    1, '31500000-0000-4000-8000-000000000501',
    '31500000-0000-4000-8000-000000000511',
    '31500000-0000-4000-8000-000000000521'
  ),
  (
    2, '31500000-0000-4000-8000-000000000502',
    '31500000-0000-4000-8000-000000000512',
    '31500000-0000-4000-8000-000000000522'
  );
GRANT SELECT ON r6c_graph_runs TO gurine_analysis_worker;

DO $$
DECLARE
  v_source ops.agent_runs%ROWTYPE;
  v_fixture r6c_graph_runs%ROWTYPE;
  v_snapshot r6c_graph_snapshot%ROWTYPE;
  v_payload jsonb;
BEGIN
  SELECT run.* INTO STRICT v_source
  FROM ops.agent_runs AS run
  JOIN ops.signal_investigation_initiation_receipts AS receipt
    ON receipt.agent_run_id = run.id
  WHERE receipt.disposition = 'STARTED'
    AND run.run_contract_version = 2
  ORDER BY receipt.created_at DESC
  LIMIT 1;
  SELECT * INTO STRICT v_snapshot FROM r6c_graph_snapshot;
  FOR v_fixture IN SELECT * FROM r6c_graph_runs ORDER BY ordinal LOOP
    v_payload := to_jsonb(v_source) || jsonb_build_object(
      'id', v_fixture.run_id,
      'objective', 'TEST_FIXTURE_ONLY R6c typed graph runtime query',
      'status', 'QUEUED',
      'input_snapshot_hash', btrim(v_snapshot.snapshot_sha256),
      'output_payload', NULL,
      'output_schema_version', NULL,
      'actual_cost', NULL,
      'started_at', NULL,
      'completed_at', NULL,
      'version', 1,
      'dataset_snapshot_id', v_snapshot.snapshot_id,
      'initial_transcript_sha256', encode(extensions.digest(
        ops.canonical_jsonb_v1(jsonb_build_object(
          'schemaVersion', 'r6c-typed-graph-initial-transcript.v1',
          'runId', v_fixture.run_id,
          'snapshotSha256', btrim(v_snapshot.snapshot_sha256)
        )), 'sha256'
      ), 'hex'),
      'control_state', 'NONE',
      'settled_micros_krw', 0,
      'remaining_micros_krw', v_source.max_micros_krw,
      'budget_reservation_state', 'RESERVED',
      'completed_provider_turns', 0,
      'completed_tool_calls', 0,
      'next_turn_sequence', 1,
      'deadline_at', clock_timestamp() + interval '1 hour',
      'output_validation_id', NULL,
      'failure_code', NULL,
      'terminal_receipt_sha256', NULL,
      'created_actor_type', 'SERVICE',
      'created_service', 'workflow-worker',
      'created_by', NULL,
      'created_at', clock_timestamp(),
      'updated_at', clock_timestamp()
    );
    INSERT INTO ops.agent_runs
    SELECT (jsonb_populate_record(NULL::ops.agent_runs, v_payload)).*;
    INSERT INTO ops.jobs(
      id, job_type, queue, status, payload, dedupe_key,
      lease_owner, lease_token, lease_expires_at,
      fencing_token, attempt_count
    ) VALUES (
      v_fixture.job_id, 'AGENT_RUN', 'analysis-worker', 'RUNNING',
      jsonb_build_object(
        'agentRunId', v_fixture.run_id,
        'fixtureAuthority', 'TEST_FIXTURE_ONLY'
      ), 'r6c-typed-graph-run:' || v_fixture.run_id::text,
      'r6c-typed-graph-runtime', v_fixture.lease_token,
      clock_timestamp() + interval '10 minutes', 1, 1
    );
    INSERT INTO ops.job_attempts(
      job_id, attempt, worker_id, fencing_token, started_at
    ) VALUES (
      v_fixture.job_id, 1, 'r6c-typed-graph-runtime', 1,
      clock_timestamp()
    );
  END LOOP;
END $$;

SET LOCAL SESSION AUTHORIZATION gurine_analysis_worker;
DO $$
BEGIN
  IF session_user <> 'gurine_analysis_worker'
     OR current_user <> 'gurine_analysis_worker' THEN
    RAISE EXCEPTION 'R6c analysis session authorization boundary invalid';
  END IF;
END $$;
DO $$
DECLARE v_fixture r6c_graph_runs%ROWTYPE;
BEGIN
  FOR v_fixture IN SELECT * FROM r6c_graph_runs ORDER BY ordinal LOOP
    PERFORM * FROM ops.claim_agent_run_worker_v2(
      v_fixture.run_id, v_fixture.job_id, v_fixture.lease_token, 1
    );
  END LOOP;
END $$;
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
  v_fixture r6c_graph_runs%ROWTYPE;
  v_source record;
  v_unsigned jsonb;
  v_source_use_id uuid;
  v_source_use_sha char(64);
  v_counter bigint := 0;
  v_occurred_at timestamptz := '2026-08-01T02:00:00Z';
BEGIN
  FOR v_fixture IN SELECT * FROM r6c_graph_runs ORDER BY ordinal LOOP
    FOR v_source IN
      SELECT member.id AS member_id,
             member.member_ordinal,
             member.member_digest,
             member.object_type,
             member.object_id,
             member.object_version,
             member.object_content_sha256,
             source.id AS member_source_id,
             source.source_ordinal,
             source.source_digest AS member_source_digest,
             source.source_document_id,
             source.source_asset_id,
             source.source_asset_revision,
             source.source_content_sha256,
             rights.id AS rights_id,
             rights.decision_version AS rights_version,
             rights.decision_sha256 AS rights_sha,
             rights.effective_at,
             rights.expires_at,
             rights.access_right,
             rights.private_storage_right,
             rights.model_egress_right,
             rights.model_use_right,
             rights.derivative_creation_right,
             rights.excerpt_right,
             rights.redistribution_right,
             rights.commercial_use_right,
             rights.public_display_right,
             rights.policy_version,
             rights.policy_sha256
      FROM r6c_graph_snapshot AS snapshot
      JOIN core.dataset_snapshot_members AS member
        ON member.dataset_snapshot_id = snapshot.snapshot_id
      JOIN core.dataset_snapshot_member_sources AS source
        ON source.snapshot_member_id = member.id
      JOIN raw.asset_rights_decisions AS rights
        ON rights.id = '31300000-0000-4000-8000-000000000002'
      WHERE NOT (
        v_fixture.ordinal = 2
        AND member.member_ordinal = 0
        AND source.source_ordinal = 1
      )
      ORDER BY member.member_ordinal, source.source_ordinal
    LOOP
      v_counter := v_counter + 1;
      v_source_use_id := (
        '31500000-0000-4000-8000-' ||
        lpad((600 + v_fixture.ordinal * 100 + v_counter)::text, 12, '0')
      )::uuid;
      v_unsigned := jsonb_build_object(
        'schemaVersion', 'source-use.v2',
        'sourceUseId', v_source_use_id,
        'agentRunId', v_fixture.run_id,
        'providerTurnId', NULL,
        'toolCallId', NULL,
        'parentSourceUseId', NULL,
        'parentSourceUseSha256', NULL,
        'useKind', 'TOOL_QUERY',
        'sourceKind', 'DATASET_MEMBER',
        'sourceIdentity', jsonb_build_object(
          'kind', 'DATASET_MEMBER',
          'datasetSnapshotId',
            (SELECT snapshot_id FROM r6c_graph_snapshot),
          'snapshotMemberId', v_source.member_id,
          'snapshotMemberDigest', btrim(v_source.member_digest),
          'objectType', v_source.object_type,
          'objectId', v_source.object_id,
          'objectVersion', v_source.object_version,
          'objectContentSha256', btrim(v_source.object_content_sha256)
        ),
        'locator', jsonb_build_object(
          'kind', NULL, 'value', NULL, 'locatorSha256', NULL
        ),
        'selectedContentSha256', NULL,
        'classification', 'PUBLIC',
        'rightsDecision', jsonb_build_object(
          'decisionId', v_source.rights_id,
          'decisionVersion', v_source.rights_version,
          'decisionSha256', btrim(v_source.rights_sha),
          'effectiveAt', v_source.effective_at,
          'expiresAt', v_source.expires_at,
          'accessRight', v_source.access_right,
          'privateStorageRight', v_source.private_storage_right,
          'modelEgressRight', v_source.model_egress_right,
          'modelUseRight', v_source.model_use_right,
          'derivativeCreationRight', v_source.derivative_creation_right,
          'excerptRight', v_source.excerpt_right,
          'redistributionRight', v_source.redistribution_right,
          'commercialUseRight', v_source.commercial_use_right,
          'publicDisplayRight', v_source.public_display_right
        ),
        'providerReceiptId', NULL,
        'occurredAt', v_occurred_at
      );
      v_source_use_sha := encode(extensions.digest(
        ops.canonical_jsonb_v1(v_unsigned), 'sha256'
      ), 'hex');
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
        commercial_use_right, public_display_right,
        rights_policy_version, rights_policy_sha256, occurred_at,
        source_use_canonical, source_use_sha256
      ) VALUES (
        v_source_use_id, 2, v_fixture.run_id,
        'TOOL_QUERY', 'DATASET_MEMBER',
        (SELECT snapshot_id FROM r6c_graph_snapshot),
        v_source.member_id, v_source.member_digest,
        v_source.member_source_id, v_source.member_source_digest,
        'SOURCE_DOCUMENT', v_source.object_type, v_source.object_id,
        v_source.object_version, v_source.object_content_sha256,
        v_source.source_document_id, v_source.source_asset_id,
        v_source.source_asset_revision, v_source.source_content_sha256,
        NULL, 'PUBLIC', 'ASSET_RIGHTS', v_source.source_asset_id,
        v_source.source_asset_revision, v_source.source_content_sha256,
        v_source.rights_id, v_source.rights_version, v_source.rights_sha,
        v_source.effective_at, v_source.expires_at,
        v_source.access_right, v_source.private_storage_right,
        v_source.model_egress_right, v_source.model_use_right,
        v_source.derivative_creation_right, v_source.excerpt_right,
        v_source.redistribution_right, v_source.commercial_use_right,
        v_source.public_display_right, v_source.policy_version,
        v_source.policy_sha256, v_occurred_at,
        ops.canonical_jsonb_v1(
          v_unsigned || jsonb_build_object(
            'sourceUseSha256', btrim(v_source_use_sha)
          )
        ), v_source_use_sha
      );
    END LOOP;
    v_counter := 0;
  END LOOP;
END $$;

CREATE TEMP TABLE r6c_graph_neighbor_results(
  scenario text NOT NULL,
  run_ordinal integer NOT NULL,
  query_digest char(64),
  relationship_kind text,
  subject jsonb,
  object jsonb,
  assertion_id uuid,
  assertion_revision bigint,
  assertion_digest char(64),
  valid_from date,
  valid_to date,
  evidence_count integer,
  evidence_set_digest char(64),
  subject_source_use_id uuid,
  subject_source_use_sha256 char(64),
  object_source_use_id uuid,
  object_source_use_sha256 char(64),
  verification_status text,
  public_use_status text,
  proposed_actor_type text,
  proposed_actor_id text,
  verified_by uuid,
  verified_at timestamptz,
  verification_reason_digest char(64)
);
GRANT INSERT, SELECT ON r6c_graph_neighbor_results
  TO gurine_analysis_worker;

DO $$
BEGIN
  IF has_table_privilege(
       'gurine_analysis_worker',
       'core.relationship_graph_endpoints_v2', 'SELECT'
     )
     OR has_table_privilege(
       'gurine_analysis_worker',
       'core.relationship_graph_assertions_v2', 'SELECT'
     )
     OR has_table_privilege(
       'gurine_analysis_worker',
       'core.relationship_graph_assertion_evidence_v2', 'SELECT'
     )
     OR has_table_privilege(
       'gurine_analysis_worker',
       'core.relationship_graph_verification_decisions_v2', 'SELECT'
     )
     OR has_table_privilege(
       'gurine_analysis_worker',
       'core.dataset_snapshot_relationship_assertions_v2', 'SELECT'
     )
     OR (
       SELECT count(*)
       FROM pg_proc AS routine
       JOIN pg_namespace AS namespace ON namespace.oid = routine.pronamespace
       WHERE namespace.nspname = 'core'
         AND routine.proname = 'list_typed_relationship_neighbors_v3'
         AND has_function_privilege(
           'gurine_analysis_worker', routine.oid, 'EXECUTE'
         )
     ) <> 1
     OR EXISTS (
       SELECT 1
       FROM pg_proc AS routine
       JOIN pg_namespace AS namespace ON namespace.oid = routine.pronamespace
       WHERE namespace.nspname = 'core'
         AND routine.proname = 'typed_person_node_ref_v3'
         AND has_function_privilege(
           'gurine_analysis_worker', routine.oid, 'EXECUTE'
         )
     ) THEN
    RAISE EXCEPTION 'R6c typed graph least-privilege closure invalid';
  END IF;
END $$;

SET LOCAL SESSION AUTHORIZATION gurine_analysis_worker;
DO $$
DECLARE
  v_snapshot r6c_graph_snapshot%ROWTYPE;
  v_run_one uuid;
  v_run_two uuid;
  v_fixture record;
  v_request jsonb;
  v_request_canonical bytea;
  v_person_ref_one char(64);
  v_person_ref_two char(64);
  v_cross_snapshot_denied boolean := false;
BEGIN
  SELECT * INTO STRICT v_snapshot FROM r6c_graph_snapshot;
  SELECT run_id INTO STRICT v_run_one FROM r6c_graph_runs WHERE ordinal = 1;
  SELECT run_id INTO STRICT v_run_two FROM r6c_graph_runs WHERE ordinal = 2;

  FOR v_fixture IN
    SELECT * FROM (VALUES
      (
        'bid'::text, 'PROCUREMENT_NOTICE'::text, 'notice'::text,
        jsonb_build_array('BID_PARTICIPATION'), '2026-06-01'::text
      ),
      (
        'sanction'::text, 'SANCTION'::text, 'sanction'::text,
        jsonb_build_array('SANCTION'), '2026-06-01'::text
      ),
      (
        'former'::text, 'AGENCY'::text, 'agency'::text,
        jsonb_build_array('FORMER_OFFICIAL_ROLE'), '2024-06-01'::text
      )
    ) AS fixture(
      scenario, selector_kind, endpoint_key, relationship_kinds, as_of
    )
  LOOP
    v_request := jsonb_build_object(
      'schemaVersion', 'relationship.neighbors.request.v3',
      'runId', v_run_one,
      'inputSnapshotId', v_snapshot.snapshot_id,
      'inputSnapshotSha256', btrim(v_snapshot.snapshot_sha256),
      'selector', jsonb_build_object(
        'kind', v_fixture.selector_kind,
        'endpointId', (
          SELECT endpoint_id FROM r6c_graph_endpoints
          WHERE fixture_key = v_fixture.endpoint_key
        )
      ),
      'relationshipKinds', v_fixture.relationship_kinds,
      'asOf', v_fixture.as_of,
      'limit', 20
    );
    v_request_canonical := ops.canonical_jsonb_v1(v_request);
    INSERT INTO r6c_graph_neighbor_results
    SELECT v_fixture.scenario, 1, neighbor.*
    FROM core.list_typed_relationship_neighbors_v3(
      v_run_one, v_snapshot.snapshot_id, v_snapshot.producer_generation,
      v_snapshot.snapshot_sha256, v_request_canonical, 20
    ) AS neighbor;
  END LOOP;

  v_request := jsonb_build_object(
    'schemaVersion', 'relationship.neighbors.request.v3',
    'runId', v_run_two,
    'inputSnapshotId', v_snapshot.snapshot_id,
    'inputSnapshotSha256', btrim(v_snapshot.snapshot_sha256),
    'selector', jsonb_build_object(
      'kind', 'AGENCY',
      'endpointId', (
        SELECT endpoint_id FROM r6c_graph_endpoints
        WHERE fixture_key = 'agency'
      )
    ),
    'relationshipKinds', jsonb_build_array('FORMER_OFFICIAL_ROLE'),
    'asOf', '2024-06-01',
    'limit', 20
  );
  INSERT INTO r6c_graph_neighbor_results
  SELECT 'former-run-2-anchor', 2, neighbor.*
  FROM core.list_typed_relationship_neighbors_v3(
    v_run_two, v_snapshot.snapshot_id, v_snapshot.producer_generation,
    v_snapshot.snapshot_sha256, ops.canonical_jsonb_v1(v_request), 20
  ) AS neighbor;

  SELECT subject->>'personNodeRef' INTO STRICT v_person_ref_one
  FROM r6c_graph_neighbor_results WHERE scenario = 'former';
  SELECT subject->>'personNodeRef' INTO STRICT v_person_ref_two
  FROM r6c_graph_neighbor_results WHERE scenario = 'former-run-2-anchor';
  IF v_person_ref_one = v_person_ref_two THEN
    RAISE EXCEPTION 'R6c PERSON ref was not run-scoped';
  END IF;

  FOR v_fixture IN
    SELECT * FROM (VALUES
      (1, v_run_one, v_person_ref_one, 'person-own-run-1'::text),
      (2, v_run_two, v_person_ref_two, 'person-own-run-2'::text),
      (2, v_run_two, v_person_ref_one, 'person-cross-run'::text)
    ) AS fixture(run_ordinal, run_id, person_ref, scenario)
  LOOP
    v_request := jsonb_build_object(
      'schemaVersion', 'relationship.neighbors.request.v3',
      'runId', v_fixture.run_id,
      'inputSnapshotId', v_snapshot.snapshot_id,
      'inputSnapshotSha256', btrim(v_snapshot.snapshot_sha256),
      'selector', jsonb_build_object(
        'kind', 'PERSON', 'personNodeRef', btrim(v_fixture.person_ref)
      ),
      'relationshipKinds', jsonb_build_array('FORMER_OFFICIAL_ROLE'),
      'asOf', '2024-06-01',
      'limit', 20
    );
    v_request_canonical := ops.canonical_jsonb_v1(v_request);
    INSERT INTO r6c_graph_neighbor_results
    SELECT v_fixture.scenario, v_fixture.run_ordinal, neighbor.*
    FROM core.list_typed_relationship_neighbors_v3(
      v_fixture.run_id, v_snapshot.snapshot_id,
      v_snapshot.producer_generation, v_snapshot.snapshot_sha256,
      v_request_canonical, 20
    ) AS neighbor;
  END LOOP;

  v_request := jsonb_build_object(
    'schemaVersion', 'relationship.neighbors.request.v3',
    'runId', v_run_two,
    'inputSnapshotId', v_snapshot.snapshot_id,
    'inputSnapshotSha256', btrim(v_snapshot.snapshot_sha256),
    'selector', jsonb_build_object(
      'kind', 'PROCUREMENT_NOTICE',
      'endpointId', (
        SELECT endpoint_id FROM r6c_graph_endpoints
        WHERE fixture_key = 'notice'
      )
    ),
    'relationshipKinds', jsonb_build_array('BID_PARTICIPATION'),
    'asOf', '2026-06-01',
    'limit', 20
  );
  INSERT INTO r6c_graph_neighbor_results
  SELECT 'missing-source-use', 2, neighbor.*
  FROM core.list_typed_relationship_neighbors_v3(
    v_run_two, v_snapshot.snapshot_id, v_snapshot.producer_generation,
    v_snapshot.snapshot_sha256, ops.canonical_jsonb_v1(v_request), 20
  ) AS neighbor;

  v_request := jsonb_build_object(
    'schemaVersion', 'relationship.neighbors.request.v3',
    'runId', v_run_one,
    'inputSnapshotId',
      '00000000-0000-4000-8000-000000000001'::uuid,
    'inputSnapshotSha256', repeat('0', 64),
    'selector', jsonb_build_object(
      'kind', 'AGENCY',
      'endpointId', (
        SELECT endpoint_id FROM r6c_graph_endpoints
        WHERE fixture_key = 'agency'
      )
    ),
    'relationshipKinds', jsonb_build_array('FORMER_OFFICIAL_ROLE'),
    'asOf', '2024-06-01',
    'limit', 20
  );
  BEGIN
    PERFORM * FROM core.list_typed_relationship_neighbors_v3(
      v_run_one, '00000000-0000-4000-8000-000000000001'::uuid,
      v_snapshot.producer_generation, repeat('0', 64),
      ops.canonical_jsonb_v1(v_request), 20
    );
  EXCEPTION WHEN SQLSTATE '23514' THEN
    v_cross_snapshot_denied := SQLERRM =
      'typed_relationship_neighbors_ready_snapshot_required';
  END;
  IF NOT v_cross_snapshot_denied THEN
    RAISE EXCEPTION 'R6c cross-snapshot graph query was not denied';
  END IF;
END $$;
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
  v_snapshot r6c_graph_snapshot%ROWTYPE;
  v_run_one uuid;
  v_neighbor r6c_graph_neighbor_results%ROWTYPE;
  v_request jsonb;
  v_response jsonb;
  v_mutated_request jsonb;
  v_mutated_response jsonb;
BEGIN
  SELECT * INTO STRICT v_snapshot FROM r6c_graph_snapshot;
  SELECT run_id INTO STRICT v_run_one
  FROM r6c_graph_runs WHERE ordinal = 1;
  SELECT * INTO STRICT v_neighbor
  FROM r6c_graph_neighbor_results WHERE scenario = 'former';
  v_request := jsonb_build_object(
    'schemaVersion', 'relationship.neighbors.request.v3',
    'runId', v_run_one,
    'inputSnapshotId', v_snapshot.snapshot_id,
    'inputSnapshotSha256', btrim(v_snapshot.snapshot_sha256),
    'selector', jsonb_build_object(
      'kind', 'AGENCY',
      'endpointId', (
        SELECT endpoint_id FROM r6c_graph_endpoints
        WHERE fixture_key = 'agency'
      )
    ),
    'relationshipKinds', jsonb_build_array('FORMER_OFFICIAL_ROLE'),
    'asOf', '2024-06-01',
    'limit', 20
  );
  v_response := jsonb_build_object(
    'schemaVersion', 'relationship.neighbors.response.v3',
    'queryDigest', btrim(v_neighbor.query_digest),
    'neighbors', jsonb_build_array(jsonb_build_object(
      'subject', v_neighbor.subject,
      'object', v_neighbor.object,
      'relationshipKind', v_neighbor.relationship_kind,
      'assertionId', v_neighbor.assertion_id,
      'assertionRevision', v_neighbor.assertion_revision,
      'assertionDigest', btrim(v_neighbor.assertion_digest),
      'validFrom', v_neighbor.valid_from,
      'validTo', v_neighbor.valid_to,
      'evidenceSetDigest', btrim(v_neighbor.evidence_set_digest),
      'subjectSourceUseId', v_neighbor.subject_source_use_id,
      'objectSourceUseId', v_neighbor.object_source_use_id
    ))
  );
  IF NOT ops.relationship_neighbors_payload_is_valid_v2_v3(
       v_request, v_response
     )
     OR ops.relationship_neighbors_payload_is_valid_v2_v3(
       v_request,
       jsonb_set(v_response, '{queryDigest}', to_jsonb(repeat('0', 64)))
     ) THEN
    RAISE EXCEPTION 'R6c v3 exact query digest validation invalid';
  END IF;

  v_mutated_response := jsonb_set(
    v_response, '{neighbors,0,relationshipKind}',
    to_jsonb('BID_PARTICIPATION'::text)
  );
  IF ops.relationship_neighbors_payload_is_valid_v2_v3(
       v_request, v_mutated_response
     ) THEN
    RAISE EXCEPTION 'R6c v3 invalid endpoint pair was accepted';
  END IF;

  v_mutated_request := jsonb_set(
    v_request, '{selector,endpointId}',
    to_jsonb('31500000-0000-4000-8000-000000000999'::text)
  );
  v_mutated_response := jsonb_set(
    v_response, '{queryDigest}', to_jsonb(encode(extensions.digest(
      ops.canonical_jsonb_v1(v_mutated_request), 'sha256'
    ), 'hex'))
  );
  IF ops.relationship_neighbors_payload_is_valid_v2_v3(
       v_mutated_request, v_mutated_response
     ) THEN
    RAISE EXCEPTION 'R6c v3 unrelated selector result was accepted';
  END IF;

  v_mutated_request := jsonb_set(
    v_request, '{relationshipKinds}', jsonb_build_array('SANCTION')
  );
  v_mutated_response := jsonb_set(
    v_response, '{queryDigest}', to_jsonb(encode(extensions.digest(
      ops.canonical_jsonb_v1(v_mutated_request), 'sha256'
    ), 'hex'))
  );
  IF ops.relationship_neighbors_payload_is_valid_v2_v3(
       v_mutated_request, v_mutated_response
     ) THEN
    RAISE EXCEPTION 'R6c v3 unrequested relationship kind was accepted';
  END IF;

  v_mutated_request := jsonb_set(
    v_request, '{asOf}', to_jsonb('2030-01-01'::text)
  );
  v_mutated_response := jsonb_set(
    v_response, '{queryDigest}', to_jsonb(encode(extensions.digest(
      ops.canonical_jsonb_v1(v_mutated_request), 'sha256'
    ), 'hex'))
  );
  IF ops.relationship_neighbors_payload_is_valid_v2_v3(
       v_mutated_request, v_mutated_response
     ) THEN
    RAISE EXCEPTION 'R6c v3 out-of-window result was accepted';
  END IF;

  v_mutated_response := jsonb_set(
    jsonb_set(
      v_response, '{neighbors,0,validFrom}', to_jsonb('2025-01-01'::text)
    ),
    '{neighbors,0,validTo}', to_jsonb('2024-01-01'::text)
  );
  IF ops.relationship_neighbors_payload_is_valid_v2_v3(
       v_request, v_mutated_response
     ) THEN
    RAISE EXCEPTION 'R6c v3 inverted validity interval was accepted';
  END IF;
END $$;

DO $$
DECLARE
  v_pending_id uuid;
BEGIN
  SELECT assertion_id INTO STRICT v_pending_id
  FROM r6c_graph_assertions WHERE fixture_key = 'pending';
  IF (SELECT count(*) FROM r6c_graph_neighbor_results
      WHERE scenario IN ('bid', 'sanction', 'former')) <> 3
     OR EXISTS (
       SELECT 1 FROM r6c_graph_neighbor_results
       WHERE scenario IN ('bid', 'sanction', 'former')
         AND (
           assertion_revision <> 2
           OR verification_status <> 'VERIFIED'
           OR public_use_status <> 'APPROVED'
           OR evidence_count <> 1
           OR subject_source_use_id = object_source_use_id
           OR query_digest <> encode(extensions.digest(
             ops.canonical_jsonb_v1(jsonb_build_object(
               'schemaVersion', 'relationship.neighbors.request.v3',
               'runId', (SELECT run_id FROM r6c_graph_runs WHERE ordinal = 1),
               'inputSnapshotId',
                 (SELECT snapshot_id FROM r6c_graph_snapshot),
               'inputSnapshotSha256', btrim((
                 SELECT snapshot_sha256 FROM r6c_graph_snapshot
               )),
               'selector', CASE scenario
                 WHEN 'bid' THEN jsonb_build_object(
                   'kind', 'PROCUREMENT_NOTICE',
                   'endpointId', (SELECT endpoint_id
                     FROM r6c_graph_endpoints WHERE fixture_key = 'notice')
                 )
                 WHEN 'sanction' THEN jsonb_build_object(
                   'kind', 'SANCTION',
                   'endpointId', (SELECT endpoint_id
                     FROM r6c_graph_endpoints WHERE fixture_key = 'sanction')
                 )
                 ELSE jsonb_build_object(
                   'kind', 'AGENCY',
                   'endpointId', (SELECT endpoint_id
                     FROM r6c_graph_endpoints WHERE fixture_key = 'agency')
                 ) END,
               'relationshipKinds', CASE scenario
                 WHEN 'bid' THEN jsonb_build_array('BID_PARTICIPATION')
                 WHEN 'sanction' THEN jsonb_build_array('SANCTION')
                 ELSE jsonb_build_array('FORMER_OFFICIAL_ROLE') END,
               'asOf', CASE scenario
                 WHEN 'former' THEN '2024-06-01' ELSE '2026-06-01' END,
               'limit', 20
             )), 'sha256'), 'hex')
         )
     )
     OR EXISTS (
       SELECT 1 FROM r6c_graph_neighbor_results
       WHERE assertion_id = v_pending_id
     )
     OR NOT EXISTS (
       SELECT 1
       FROM core.relationship_graph_assertions_v2 AS assertion
       JOIN core.dataset_snapshot_relationship_assertions_v2 AS frozen
         ON frozen.assertion_id = assertion.assertion_id
        AND frozen.assertion_revision = assertion.assertion_revision
       WHERE assertion.assertion_id = v_pending_id
         AND assertion.assertion_revision = 1
         AND assertion.verification_status = 'PENDING_HUMAN'
         AND assertion.public_use_status = 'NOT_REVIEWED'
         AND assertion.validity_coverage_status = 'PARTIAL'
         AND frozen.dataset_snapshot_id =
           (SELECT snapshot_id FROM r6c_graph_snapshot)
     )
     OR (SELECT count(*) FROM r6c_graph_neighbor_results
         WHERE scenario IN ('person-own-run-1', 'person-own-run-2')) <> 2
     OR EXISTS (
       SELECT 1 FROM r6c_graph_neighbor_results
       WHERE scenario IN ('person-own-run-1', 'person-own-run-2')
         AND (
           subject <> jsonb_build_object(
             'kind', 'PERSON',
             'personNodeRef', subject->>'personNodeRef'
           )
           OR subject->>'personNodeRef' !~ '^[0-9a-f]{64}$'
           OR subject ?| ARRAY[
             'endpointId', 'contextualName', 'roleTitle',
             'sourceLocator', 'identifierDigest'
           ]
         )
     )
     OR EXISTS (
       SELECT 1 FROM r6c_graph_neighbor_results
       WHERE scenario IN ('person-cross-run', 'missing-source-use')
     )
     OR (SELECT count(*) FROM r6c_graph_neighbor_results
         WHERE scenario = 'former-run-2-anchor') <> 1
     OR (SELECT count(*) FROM ops.agent_source_uses AS source_use
         WHERE source_use.agent_run_id IN (
           SELECT run_id FROM r6c_graph_runs
         )
           AND source_use.use_kind = 'TOOL_QUERY'
           AND source_use.source_kind = 'DATASET_MEMBER') <> 15
     OR EXISTS (
       SELECT 1 FROM ops.agent_source_uses AS source_use
       WHERE source_use.agent_run_id IN (
         SELECT run_id FROM r6c_graph_runs
       )
         AND source_use.source_use_sha256 <> encode(
           extensions.digest(
             ops.canonical_jsonb_v1(
               convert_from(source_use.source_use_canonical, 'UTF8')::jsonb
                 - 'sourceUseSha256'
             ), 'sha256'
           ), 'hex'
         )
     ) THEN
    RAISE EXCEPTION 'R6c typed graph v3 runtime proof invalid';
  END IF;
END $$;

ROLLBACK;
