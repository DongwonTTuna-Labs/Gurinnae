#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="gurine-provider-control-proposal-${BASHPID}"
database="gurine_provider_control_proposal"
postgres_image="postgres:18.4-bookworm@sha256:d9c83446333daec3f0588cc709adb80c26090b7f9f0f7ec8d43c243385d79818"
build_target="${GURINE_TEST_TARGET_DIR:-/home/dongwonttuna/.cache/gurinnae-codex-target}"

cleanup() {
  status=$?
  trap - EXIT
  if [[ "$status" -ne 0 ]]; then
    docker logs "$container" >&2 2>/dev/null || true
  fi
  docker rm -f "$container" >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT

cd "$root"
mapfile -t migrations < <(printf '%s\n' db/migrations/*.sql | LC_ALL=C sort)
if [[ "${#migrations[@]}" -eq 0 ]]; then
  printf 'no migrations found\n' >&2
  exit 1
fi
for index in "${!migrations[@]}"; do
  ordinal=$((index + 1))
  printf -v expected_prefix '%04d_' "$ordinal"
  migration_name="$(basename "${migrations[$index]}")"
  if [[ "$migration_name" != "$expected_prefix"* ]]; then
    printf 'migration order mismatch at %s: expected %s*, found %s\n' \
      "$ordinal" "$expected_prefix" "$migration_name" >&2
    exit 1
  fi
done

CARGO_TARGET_DIR="$build_target" cargo build --locked -p gurine-migrator >/dev/null
docker run --rm --detach --name "$container" \
  --env POSTGRES_DB="$database" \
  --env POSTGRES_USER=postgres \
  --env POSTGRES_PASSWORD=postgres \
  --publish 127.0.0.1::5432 \
  "$postgres_image" >/dev/null
bash scripts/wait-postgres-container.sh "$container" "$database"
postgres_port="$(docker port "$container" 5432/tcp | sed -n '1s/.*://p')"
GURINE_ENV=test \
  MIGRATOR_DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${postgres_port}/${database}" \
  "$build_target/debug/gurine-migrator" >/dev/null

applied_migrations="$(docker exec "$container" psql -X -At -v ON_ERROR_STOP=1 \
  -U postgres -d "$database" \
  -c 'SELECT count(*) FROM _sqlx_migrations WHERE success')"
if [[ "$applied_migrations" -ne "${#migrations[@]}" ]]; then
  printf 'migration count mismatch: files=%s applied=%s\n' \
    "${#migrations[@]}" "$applied_migrations" >&2
  exit 1
fi

docker exec -i "$container" psql -X -At -v ON_ERROR_STOP=1 \
  -U postgres -d "$database" <<'SQL'
INSERT INTO ops.users(id,oidc_subject,email,display_name,status) VALUES
  ('51000000-0000-4000-8000-000000000001','provider-control-creator',
   'provider-control-creator@gurine.test','Provider control creator','ACTIVE'),
  ('52000000-0000-4000-8000-000000000001','provider-control-executive-reviewer',
   'provider-control-executive-reviewer@gurine.test','Executive reviewer','ACTIVE'),
  ('53000000-0000-4000-8000-000000000001','provider-control-operations-reviewer',
   'provider-control-operations-reviewer@gurine.test','Operations reviewer','ACTIVE');

INSERT INTO ops.user_roles(user_id,role_id,granted_by,reason)
SELECT membership.user_id,role.id,
       '51000000-0000-4000-8000-000000000001'::uuid,
       'OPS-005 provider proposal PostgreSQL runtime fixture'
FROM (VALUES
  ('51000000-0000-4000-8000-000000000001'::uuid,'OPERATIONS'),
  ('52000000-0000-4000-8000-000000000001'::uuid,'EXECUTIVE_APPROVER'),
  ('53000000-0000-4000-8000-000000000001'::uuid,'OPERATIONS')
) AS membership(user_id,role_code)
JOIN ops.roles AS role ON role.code=membership.role_code;

INSERT INTO ops.relay_model_catalog(
  model_id,family,track,created_at,first_seen_at,last_seen_at,active,raw
) VALUES (
  'relay-runtime-fixture-v2','relay-runtime-fixture','stable',
  '2026-08-05T00:00:00Z','2026-08-05T00:00:00Z','2026-08-05T00:00:00Z',true,
  jsonb_build_object(
    'id','relay-runtime-fixture-v2',
    'family','relay-runtime-fixture',
    'track','stable',
    'created','2026-08-05T00:00:00Z'
  )
);

CREATE TEMP TABLE provider_control_cases(
  operation_id text PRIMARY KEY,
  proposal_id uuid NOT NULL UNIQUE,
  content_digest char(64) NOT NULL,
  preview_id uuid NOT NULL,
  preview_digest char(64) NOT NULL,
  submitted_state text,
  reviewer_id uuid,
  reviewer_role text
);

DO $prepare$
DECLARE
  creator_id constant uuid := '51000000-0000-4000-8000-000000000001';
  provider ops.provider_configs%ROWTYPE;
  operation_id text;
  rationale text;
  control jsonb;
  draft jsonb;
  created jsonb;
  previewed jsonb;
  proposal_id uuid;
BEGIN
  SELECT config.* INTO STRICT provider
  FROM ops.provider_configs AS config
  WHERE config.provider_type='relay';

  FOREACH operation_id IN ARRAY ARRAY[
    'disableProviderRouting','testProviderConnection',
    'upgradeProviderModel','setModelAutoUpgrade'
  ] LOOP
    rationale:=CASE operation_id
      WHEN 'disableProviderRouting' THEN 'Runtime proof for governed relay routing disable'
      WHEN 'testProviderConnection' THEN 'Runtime proof for governed relay connection test'
      WHEN 'upgradeProviderModel' THEN 'Runtime proof for governed relay model upgrade'
      ELSE 'Runtime proof for governed relay auto-upgrade configuration'
    END;
    control:=CASE operation_id
      WHEN 'disableProviderRouting' THEN jsonb_build_object(
        'operationId',operation_id,'providerId',provider.id,
        'reason',rationale,'expectedVersion',provider.version)
      WHEN 'testProviderConnection' THEN jsonb_build_object(
        'operationId',operation_id,'providerId',provider.id,
        'testModel','relay-runtime-fixture-v2','reason',rationale,
        'expectedVersion',provider.version)
      WHEN 'upgradeProviderModel' THEN jsonb_build_object(
        'operationId',operation_id,'providerId',provider.id,
        'modelId','relay-runtime-fixture-v2','reason',rationale,
        'expectedVersion',provider.version,
        'dataPolicy',jsonb_build_object(
          'processingRegion','KR','retentionMode','ZERO_RETENTION',
          'policyVersion','runtime-fixture-v1'))
      ELSE jsonb_build_object(
        'operationId',operation_id,'providerId',provider.id,
        'enabled',false,'reason',rationale,'expectedVersion',provider.version)
    END;
    draft:=jsonb_build_object(
      'schemaVersion','action-payload.v1','kind','PROVIDER_CONTROL',
      'target',jsonb_build_object(
        'type','CAPABILITY','id',provider.id,'version',provider.version),
      'objectScope',jsonb_build_object(
        'providerId',provider.id,'operationId',operation_id),
      'rationale',rationale,
      'effect',jsonb_build_object(
        'kind','PROVIDER_CONTROL','operationId',operation_id),
      'providerControl',control);
    proposal_id:=gen_random_uuid();
    created:=ops.execute_action_approval_v1(
      'createActionProposal',jsonb_build_object(
        '_proposalId',proposal_id,
        '_payloadEncryptedBase64',encode(ops.canonical_jsonb_v1(draft),'base64'),
        '_rationaleEncryptedBase64',encode(convert_to(rationale,'UTF8'),'base64'),
        'actionKind','PROVIDER_CONTROL',
        'origin',jsonb_build_object('kind','HUMAN','id',creator_id),
        'rationale',rationale,'draft',draft,
        'expiresAt',clock_timestamp()+interval '1 hour'),
      creator_id);
    previewed:=ops.execute_action_approval_v1(
      'previewActionDraft',jsonb_build_object(
        'proposalId',proposal_id,'expectedVersion',1,
        'expectedContentDigest',created->>'contentDigest'),creator_id);
    INSERT INTO provider_control_cases(
      operation_id,proposal_id,content_digest,preview_id,preview_digest
    ) VALUES (
      operation_id,proposal_id,created->>'contentDigest',
      (previewed->>'previewId')::uuid,previewed->>'previewDigest'
    );
  END LOOP;
END
$prepare$;

CREATE TEMP VIEW final_candidate_role_allowed AS
WITH target_constraint AS (
  SELECT constraint_row.oid,
         pg_get_constraintdef(constraint_row.oid,true) AS definition
  FROM pg_catalog.pg_constraint AS constraint_row
  WHERE constraint_row.conrelid='editorial.conflict_snapshots'::regclass
    AND constraint_row.conname='conflict_snapshots_candidate_role_ck'
    AND constraint_row.contype='c'
    AND constraint_row.convalidated
), captured_role AS (
  SELECT captured.value[1] AS role_code
  FROM target_constraint
  CROSS JOIN LATERAL regexp_matches(
    target_constraint.definition,
    $role_regex$'([A-Z][A-Z0-9_]*)'$role_regex$,
    'g'
  ) AS captured(value)
)
SELECT DISTINCT role_code
FROM captured_role;

CREATE TEMP VIEW provider_control_capability_reachable_roles AS
SELECT DISTINCT runtime_case.operation_id,
       version.review_detail->>'requiredCapability' AS required_capability,
       role.code AS role_code
FROM provider_control_cases AS runtime_case
JOIN ops.action_proposal_versions AS version
  ON version.proposal_id=runtime_case.proposal_id
 AND version.version=1
JOIN ops.action_approval_provider_control_details AS detail
  ON detail.proposal_id=runtime_case.proposal_id
 AND detail.proposal_version=1
 AND detail.operation_id=runtime_case.operation_id
 AND detail.required_creator_capability=
       version.review_detail->>'requiredCapability'
CROSS JOIN ops.roles AS role
JOIN ops.role_capabilities AS review_capability
  ON review_capability.role_id=role.id
 AND review_capability.capability_code='actions.review'
JOIN ops.role_capabilities AS provider_capability
  ON provider_capability.role_id=role.id
 AND provider_capability.capability_code=
       version.review_detail->>'requiredCapability'
WHERE version.review_detail->>'operationId'=runtime_case.operation_id;

CREATE TEMP VIEW provider_control_reachable_roles AS
SELECT DISTINCT capability_role.operation_id,
       capability_role.required_capability,
       capability_role.role_code
FROM provider_control_capability_reachable_roles AS capability_role
JOIN ops.roles AS role ON role.code=capability_role.role_code
JOIN ops.user_roles AS membership
  ON membership.role_id=role.id
 AND membership.revoked_at IS NULL
 AND (membership.expires_at IS NULL OR membership.expires_at>clock_timestamp())
JOIN ops.users AS reviewer
  ON reviewer.id=membership.user_id
 AND reviewer.status='ACTIVE'
 AND reviewer.id<>'51000000-0000-4000-8000-000000000001'::uuid;

CREATE OR REPLACE FUNCTION pg_temp.assert_provider_reviewer_roles_allowed()
RETURNS void
LANGUAGE plpgsql
AS $assertion$
DECLARE
  constraint_count bigint;
  missing_operations text[];
  missing_roles text[];
BEGIN
  SELECT count(*) INTO constraint_count
  FROM pg_catalog.pg_constraint AS constraint_row
  WHERE constraint_row.conrelid='editorial.conflict_snapshots'::regclass
    AND constraint_row.conname='conflict_snapshots_candidate_role_ck'
    AND constraint_row.contype='c'
    AND constraint_row.convalidated;
  IF constraint_count<>1 OR NOT EXISTS(SELECT 1 FROM final_candidate_role_allowed) THEN
    RAISE EXCEPTION 'candidate_role final CHECK is missing, unvalidated, or unreadable'
      USING ERRCODE='23514';
  END IF;

  SELECT array_agg(runtime_case.operation_id ORDER BY runtime_case.operation_id)
    INTO missing_operations
  FROM provider_control_cases AS runtime_case
  WHERE NOT EXISTS (
    SELECT 1 FROM provider_control_capability_reachable_roles AS reachable
    WHERE reachable.operation_id=runtime_case.operation_id
  );
  IF missing_operations IS NOT NULL THEN
    RAISE EXCEPTION 'provider reviewer role set is empty for operations: %',
      missing_operations USING ERRCODE='55000';
  END IF;

  SELECT array_agg(
           reachable.operation_id||':'||reachable.role_code
           ORDER BY reachable.operation_id,reachable.role_code
         ) INTO missing_roles
  FROM provider_control_capability_reachable_roles AS reachable
  WHERE NOT EXISTS (
    SELECT 1 FROM final_candidate_role_allowed AS allowed
    WHERE allowed.role_code=reachable.role_code
  );
  IF missing_roles IS NOT NULL THEN
    RAISE EXCEPTION 'provider reviewer role not allowed by final CHECK: %',missing_roles
      USING ERRCODE='23514';
  END IF;
END
$assertion$;

SELECT pg_temp.assert_provider_reviewer_roles_allowed();
SELECT 'D2_ALLOWED_ROLES='||string_agg(role_code,',' ORDER BY role_code)
FROM final_candidate_role_allowed;
SELECT 'D2_REACHABLE='||string_agg(
  operation_id||'['||required_capability||']='||role_codes,
  ';' ORDER BY operation_id
)
FROM (
  SELECT operation_id,required_capability,
         string_agg(role_code,',' ORDER BY role_code) AS role_codes
  FROM provider_control_capability_reachable_roles
  GROUP BY operation_id,required_capability
) AS per_operation;
SELECT 'D2_FIXTURE_REACHABLE='||string_agg(
  operation_id||'['||required_capability||']='||role_codes,
  ';' ORDER BY operation_id
)
FROM (
  SELECT operation_id,required_capability,
         string_agg(role_code,',' ORDER BY role_code) AS role_codes
  FROM provider_control_reachable_roles
  GROUP BY operation_id,required_capability
) AS per_operation;

BEGIN;
DO $negative_canary$
DECLARE
  removed_role text;
  remaining_allowed text;
  observed_message text;
BEGIN
  SELECT role_code INTO STRICT removed_role
  FROM provider_control_reachable_roles
  ORDER BY role_code,operation_id
  LIMIT 1;
  SELECT string_agg(quote_literal(role_code),',' ORDER BY role_code)
    INTO remaining_allowed
  FROM final_candidate_role_allowed
  WHERE role_code<>removed_role;
  IF remaining_allowed IS NULL THEN
    RAISE EXCEPTION 'negative canary cannot construct a non-empty CHECK';
  END IF;

  ALTER TABLE editorial.conflict_snapshots
    DROP CONSTRAINT conflict_snapshots_candidate_role_ck;
  EXECUTE format(
    'ALTER TABLE editorial.conflict_snapshots ADD CONSTRAINT '
    'conflict_snapshots_candidate_role_ck CHECK (candidate_role IN (%s))',
    remaining_allowed
  );

  BEGIN
    PERFORM pg_temp.assert_provider_reviewer_roles_allowed();
    RAISE EXCEPTION 'negative canary did not detect omitted reachable role %',removed_role;
  EXCEPTION WHEN check_violation THEN
    GET STACKED DIAGNOSTICS observed_message=MESSAGE_TEXT;
    IF observed_message NOT LIKE 'provider reviewer role not allowed by final CHECK:%' THEN
      RAISE;
    END IF;
  END;
END
$negative_canary$;
ROLLBACK;

SELECT 'D2_NEGATIVE_CANARY=PASS removed='||role_code||' observed_sqlstate=23514'
FROM provider_control_reachable_roles
ORDER BY role_code,operation_id
LIMIT 1;
SELECT pg_temp.assert_provider_reviewer_roles_allowed();

DO $submit$
DECLARE
  creator_id constant uuid := '51000000-0000-4000-8000-000000000001';
  runtime_case provider_control_cases%ROWTYPE;
  submitted jsonb;
  assignment ops.action_review_assignments%ROWTYPE;
  candidate_role text;
BEGIN
  FOR runtime_case IN
    SELECT * FROM provider_control_cases
    ORDER BY array_position(ARRAY[
      'disableProviderRouting','testProviderConnection',
      'upgradeProviderModel','setModelAutoUpgrade'
    ],operation_id)
  LOOP
    submitted:=ops.execute_action_approval_v1(
      'submitActionForReview',jsonb_build_object(
        'proposalId',runtime_case.proposal_id,'expectedVersion',1,
        'expectedContentDigest',btrim(runtime_case.content_digest::text),
        'previewId',runtime_case.preview_id,
        'previewDigest',btrim(runtime_case.preview_digest::text)),creator_id);
    IF submitted->>'state'<>'PENDING_QUORUM' THEN
      RAISE EXCEPTION '% did not enter PENDING_QUORUM: %',
        runtime_case.operation_id,submitted;
    END IF;
    SELECT assignment_row.* INTO STRICT assignment
    FROM ops.action_review_assignments AS assignment_row
    WHERE assignment_row.proposal_id=runtime_case.proposal_id;
    SELECT snapshot.candidate_role INTO STRICT candidate_role
    FROM editorial.conflict_snapshots AS snapshot
    WHERE snapshot.id=assignment.conflict_snapshot_id;
    IF candidate_role IS DISTINCT FROM assignment.allowed_role_codes[1]
       OR NOT EXISTS(
         SELECT 1 FROM final_candidate_role_allowed AS allowed
         WHERE allowed.role_code=candidate_role
       )
       OR NOT EXISTS(
         SELECT 1
         FROM ops.action_proposal_versions AS version
         JOIN ops.users AS reviewer
           ON reviewer.id=assignment.reviewer_id
          AND reviewer.status='ACTIVE'
          AND reviewer.id<>creator_id
         JOIN ops.user_roles AS membership
           ON membership.user_id=reviewer.id
          AND membership.revoked_at IS NULL
          AND (membership.expires_at IS NULL
               OR membership.expires_at>clock_timestamp())
         JOIN ops.roles AS role
           ON role.id=membership.role_id
          AND role.code=candidate_role
         JOIN ops.role_capabilities AS review_capability
           ON review_capability.role_id=role.id
          AND review_capability.capability_code='actions.review'
         JOIN ops.role_capabilities AS provider_capability
           ON provider_capability.role_id=role.id
          AND provider_capability.capability_code=
                version.review_detail->>'requiredCapability'
         WHERE version.proposal_id=runtime_case.proposal_id
           AND version.version=1
           AND version.review_detail->>'operationId'=runtime_case.operation_id
       ) THEN
      RAISE EXCEPTION '% persisted inconsistent reviewer role %',
        runtime_case.operation_id,candidate_role USING ERRCODE='23514';
    END IF;
    UPDATE provider_control_cases
    SET submitted_state=submitted->>'state',
        reviewer_id=assignment.reviewer_id,
        reviewer_role=candidate_role
    WHERE operation_id=runtime_case.operation_id;
  END LOOP;
END
$submit$;

SELECT 'T2_ACTION='||operation_id||' state='||submitted_state
       ||' reviewer_role='||reviewer_role
FROM provider_control_cases
ORDER BY array_position(ARRAY[
  'disableProviderRouting','testProviderConnection',
  'upgradeProviderModel','setModelAutoUpgrade'
],operation_id);
SELECT 'provider control proposal runtime: PASS';
SQL
