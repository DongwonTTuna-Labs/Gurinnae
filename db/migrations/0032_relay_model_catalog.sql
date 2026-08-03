ALTER TABLE ops.provider_configs
  ADD CONSTRAINT provider_configs_relay_shape_ck CHECK (
    provider_type <> 'relay'
    OR (
      secret_reference = 'env:AI_RELAY_API_KEY'
      AND data_retention_policy IN (
        'UNCONFIGURED',
        'ZERO_RETENTION',
        'BOUNDED_PROVIDER_RETENTION',
        'LOCAL_ONLY'
      )
      AND jsonb_typeof(routing_policy) = 'object'
      AND routing_policy ?& ARRAY['targetUrl', 'autoUpgrade', 'dataPolicy', 'pricing']
      AND routing_policy - ARRAY[
        'targetUrl',
        'model',
        'track',
        'autoUpgrade',
        'autoUpgradeOwnerUserId',
        'dataPolicy',
        'pricing'
      ] = '{}'::jsonb
      AND routing_policy->>'targetUrl'
        ~ '^https://[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?(?::[0-9]{1,5})?/v1/chat/completions$'
      AND jsonb_typeof(routing_policy->'autoUpgrade') = 'boolean'
      AND (
        NOT routing_policy ? 'autoUpgradeOwnerUserId'
        OR routing_policy->'autoUpgradeOwnerUserId' = 'null'::jsonb
        OR routing_policy->>'autoUpgradeOwnerUserId'
          ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      )
      AND jsonb_typeof(routing_policy->'pricing') = 'object'
      AND routing_policy->'pricing' ?& ARRAY[
        'pricingVersion',
        'pricingSha256',
        'currency',
        'inputMicrosKrwPerUnit',
        'outputMicrosKrwPerUnit'
      ]
      AND (routing_policy->'pricing') - ARRAY[
        'pricingVersion',
        'pricingSha256',
        'currency',
        'inputMicrosKrwPerUnit',
        'outputMicrosKrwPerUnit'
      ] = '{}'::jsonb
      AND length(routing_policy#>>'{pricing,pricingVersion}') BETWEEN 1 AND 64
      AND ops.is_lower_sha256(routing_policy#>>'{pricing,pricingSha256}')
      AND routing_policy#>>'{pricing,currency}' = 'KRW'
      AND jsonb_typeof(routing_policy#>'{pricing,inputMicrosKrwPerUnit}') = 'number'
      AND (routing_policy#>>'{pricing,inputMicrosKrwPerUnit}')::numeric
        BETWEEN 0 AND 9223372036854775807
      AND jsonb_typeof(routing_policy#>'{pricing,outputMicrosKrwPerUnit}') = 'number'
      AND (routing_policy#>>'{pricing,outputMicrosKrwPerUnit}')::numeric
        BETWEEN 0 AND 9223372036854775807
      AND jsonb_typeof(routing_policy->'dataPolicy') = 'object'
      AND (
        (
          routing_policy->'dataPolicy' = '{"state":"UNCONFIGURED"}'::jsonb
          AND data_retention_policy = 'UNCONFIGURED'
          AND enabled = false
          AND NOT routing_policy ? 'model'
          AND NOT routing_policy ? 'track'
          AND (routing_policy->>'autoUpgrade')::boolean = false
        )
        OR (
          routing_policy->'dataPolicy' ?& ARRAY[
            'state',
            'processingRegion',
            'retentionMode',
            'trainingUse',
            'policyVersion',
            'policySha256'
          ]
          AND (routing_policy->'dataPolicy') - ARRAY[
            'state',
            'processingRegion',
            'retentionMode',
            'trainingUse',
            'policyVersion',
            'policySha256'
          ] = '{}'::jsonb
          AND routing_policy#>>'{dataPolicy,state}' = 'CONFIGURED'
          AND routing_policy#>>'{dataPolicy,processingRegion}'
            ~ '^[A-Z]{2}(?:-[A-Z0-9]{1,12})?$'
          AND routing_policy#>>'{dataPolicy,retentionMode}' IN (
            'ZERO_RETENTION',
            'BOUNDED_PROVIDER_RETENTION',
            'LOCAL_ONLY'
          )
          AND routing_policy#>>'{dataPolicy,trainingUse}' = 'PROHIBITED'
          AND length(routing_policy#>>'{dataPolicy,policyVersion}') BETWEEN 1 AND 64
          AND ops.is_lower_sha256(routing_policy#>>'{dataPolicy,policySha256}')
          AND data_retention_policy = routing_policy#>>'{dataPolicy,retentionMode}'
          AND (
            NOT enabled
            OR (
              routing_policy->>'model'
                ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,254}$'
              AND routing_policy->>'track'
                ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
            )
          )
          AND (
            (routing_policy->>'autoUpgrade')::boolean = false
            OR (
              enabled
              AND routing_policy->>'autoUpgradeOwnerUserId'
                ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
              AND routing_policy->>'track'
                ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
            )
          )
        )
      )
    )
  );

CREATE UNIQUE INDEX provider_configs_relay_singleton_uq
  ON ops.provider_configs (provider_type)
  WHERE provider_type = 'relay';

CREATE TABLE ops.relay_model_catalog (
  model_id text PRIMARY KEY,
  family text,
  track text,
  created_at timestamptz,
  first_seen_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  last_seen_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  active boolean NOT NULL DEFAULT true,
  raw jsonb NOT NULL,
  CONSTRAINT relay_model_catalog_model_id_ck CHECK (
    model_id ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,254}$'
  ),
  CONSTRAINT relay_model_catalog_family_ck CHECK (
    family IS NULL OR family ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
  ),
  CONSTRAINT relay_model_catalog_track_ck CHECK (
    track IS NULL OR track ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
  ),
  CONSTRAINT relay_model_catalog_seen_ck CHECK (last_seen_at >= first_seen_at),
  CONSTRAINT relay_model_catalog_raw_ck CHECK (
    jsonb_typeof(raw) = 'object'
    AND raw ? 'id'
    AND raw->>'id' = model_id
  )
);
ALTER TABLE ops.relay_model_catalog OWNER TO gurine_migrator;
CREATE INDEX relay_model_catalog_active_track_created_idx
  ON ops.relay_model_catalog (track, created_at DESC NULLS LAST, model_id)
  WHERE active;
CREATE INDEX relay_model_catalog_first_seen_idx
  ON ops.relay_model_catalog (first_seen_at DESC, model_id);

CREATE TABLE ops.relay_model_catalog_sync_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scheduled_bucket timestamptz NOT NULL UNIQUE,
  status text NOT NULL DEFAULT 'QUEUED',
  model_count bigint NOT NULL DEFAULT 0,
  gateway_receipt_sha256 char(64),
  payload_sha256 char(64),
  error_code text,
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT relay_model_catalog_sync_runs_bucket_ck CHECK (
    mod(extract(epoch FROM scheduled_bucket)::bigint, 21600) = 0
  ),
  CONSTRAINT relay_model_catalog_sync_runs_status_ck CHECK (
    status IN ('QUEUED', 'RUNNING', 'SUCCEEDED', 'FAILED')
  ),
  CONSTRAINT relay_model_catalog_sync_runs_count_ck CHECK (model_count >= 0),
  CONSTRAINT relay_model_catalog_sync_runs_digest_ck CHECK (
    (gateway_receipt_sha256 IS NULL OR ops.is_lower_sha256(gateway_receipt_sha256))
    AND (payload_sha256 IS NULL OR ops.is_lower_sha256(payload_sha256))
  ),
  CONSTRAINT relay_model_catalog_sync_runs_error_ck CHECK (
    error_code IS NULL OR error_code ~ '^[A-Z][A-Z0-9_]{0,127}$'
  ),
  CONSTRAINT relay_model_catalog_sync_runs_lifecycle_ck CHECK (
    (
      status = 'QUEUED'
      AND model_count = 0
      AND gateway_receipt_sha256 IS NULL
      AND payload_sha256 IS NULL
      AND error_code IS NULL
      AND started_at IS NULL
      AND completed_at IS NULL
    )
    OR (
      status = 'RUNNING'
      AND error_code IS NULL
      AND started_at IS NOT NULL
      AND completed_at IS NULL
    )
    OR (
      status = 'SUCCEEDED'
      AND gateway_receipt_sha256 IS NOT NULL
      AND payload_sha256 IS NOT NULL
      AND error_code IS NULL
      AND started_at IS NOT NULL
      AND completed_at >= started_at
    )
    OR (
      status = 'FAILED'
      AND error_code IS NOT NULL
      AND started_at IS NOT NULL
      AND completed_at >= started_at
    )
  )
);
ALTER TABLE ops.relay_model_catalog_sync_runs OWNER TO gurine_migrator;
CREATE INDEX relay_model_catalog_sync_runs_status_idx
  ON ops.relay_model_catalog_sync_runs (status, scheduled_bucket, id);

CREATE TABLE ops.provider_model_upgrade_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_id uuid NOT NULL REFERENCES ops.provider_configs(id) ON DELETE RESTRICT,
  target_model_id text NOT NULL REFERENCES ops.relay_model_catalog(model_id) ON DELETE RESTRICT,
  attempt_kind text NOT NULL,
  requested_by uuid REFERENCES ops.users(id) ON DELETE RESTRICT,
  owner_user_id uuid NOT NULL REFERENCES ops.users(id) ON DELETE RESTRICT,
  expected_provider_version bigint NOT NULL,
  requested_data_policy jsonb,
  catalog_sync_run_id uuid REFERENCES ops.relay_model_catalog_sync_runs(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'QUEUED',
  connection_test_id uuid REFERENCES ops.provider_connection_tests(id) ON DELETE RESTRICT,
  gateway_receipt_sha256 char(64),
  usage_evidence_sha256 char(64),
  last_error_code text,
  cooldown_until timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT provider_model_upgrade_attempts_kind_ck CHECK (
    attempt_kind IN ('MANUAL', 'AUTO')
  ),
  CONSTRAINT provider_model_upgrade_attempts_version_ck CHECK (
    expected_provider_version > 0
  ),
  CONSTRAINT provider_model_upgrade_attempts_actor_ck CHECK (
    (attempt_kind = 'MANUAL' AND requested_by IS NOT NULL)
    OR (attempt_kind = 'AUTO' AND requested_by IS NULL AND catalog_sync_run_id IS NOT NULL)
  ),
  CONSTRAINT provider_model_upgrade_attempts_policy_ck CHECK (
    attempt_kind = 'AUTO' AND requested_data_policy IS NULL
    OR attempt_kind = 'MANUAL' AND (
      requested_data_policy IS NULL
      OR (
        jsonb_typeof(requested_data_policy) = 'object'
        AND requested_data_policy ?& ARRAY[
          'processingRegion', 'retentionMode', 'policyVersion'
        ]
        AND requested_data_policy - ARRAY[
          'processingRegion', 'retentionMode', 'policyVersion'
        ] = '{}'::jsonb
        AND requested_data_policy->>'processingRegion'
          ~ '^[A-Z]{2}(?:-[A-Z0-9]{1,12})?$'
        AND requested_data_policy->>'retentionMode' IN (
          'ZERO_RETENTION',
          'BOUNDED_PROVIDER_RETENTION',
          'LOCAL_ONLY'
        )
        AND length(requested_data_policy->>'policyVersion') BETWEEN 1 AND 64
      )
    )
  ),
  CONSTRAINT provider_model_upgrade_attempts_status_ck CHECK (
    status IN ('QUEUED', 'RUNNING', 'SUCCEEDED', 'FAILED', 'SUPPRESSED')
  ),
  CONSTRAINT provider_model_upgrade_attempts_digest_ck CHECK (
    (gateway_receipt_sha256 IS NULL OR ops.is_lower_sha256(gateway_receipt_sha256))
    AND (usage_evidence_sha256 IS NULL OR ops.is_lower_sha256(usage_evidence_sha256))
  ),
  CONSTRAINT provider_model_upgrade_attempts_error_ck CHECK (
    last_error_code IS NULL OR last_error_code ~ '^[A-Z][A-Z0-9_]{0,127}$'
  ),
  CONSTRAINT provider_model_upgrade_attempts_lifecycle_ck CHECK (
    (
      status = 'QUEUED'
      AND connection_test_id IS NOT NULL
      AND gateway_receipt_sha256 IS NULL
      AND usage_evidence_sha256 IS NULL
      AND last_error_code IS NULL
      AND cooldown_until IS NULL
      AND started_at IS NULL
      AND completed_at IS NULL
    )
    OR (
      status = 'RUNNING'
      AND connection_test_id IS NOT NULL
      AND last_error_code IS NULL
      AND cooldown_until IS NULL
      AND started_at IS NOT NULL
      AND completed_at IS NULL
    )
    OR (
      status = 'SUCCEEDED'
      AND connection_test_id IS NOT NULL
      AND gateway_receipt_sha256 IS NOT NULL
      AND usage_evidence_sha256 IS NOT NULL
      AND last_error_code IS NULL
      AND cooldown_until IS NULL
      AND started_at IS NOT NULL
      AND completed_at >= started_at
    )
    OR (
      status = 'FAILED'
      AND connection_test_id IS NOT NULL
      AND last_error_code IS NOT NULL
      AND started_at IS NOT NULL
      AND completed_at >= started_at
      AND (
        (attempt_kind = 'MANUAL' AND cooldown_until IS NULL)
        OR (attempt_kind = 'AUTO' AND cooldown_until = completed_at + interval '6 hours')
      )
    )
    OR (
      status = 'SUPPRESSED'
      AND connection_test_id IS NULL
      AND gateway_receipt_sha256 IS NULL
      AND usage_evidence_sha256 IS NULL
      AND last_error_code IS NOT NULL
      AND completed_at IS NOT NULL
      AND (
        (attempt_kind = 'MANUAL' AND cooldown_until IS NULL)
        OR (attempt_kind = 'AUTO' AND cooldown_until = completed_at + interval '6 hours')
      )
    )
  )
);
ALTER TABLE ops.provider_model_upgrade_attempts OWNER TO gurine_migrator;
CREATE UNIQUE INDEX provider_model_upgrade_attempts_active_uq
  ON ops.provider_model_upgrade_attempts (provider_id)
  WHERE status IN ('QUEUED', 'RUNNING');
CREATE INDEX provider_model_upgrade_attempts_cooldown_idx
  ON ops.provider_model_upgrade_attempts (
    provider_id, target_model_id, completed_at DESC, id DESC
  )
  WHERE attempt_kind = 'AUTO' AND status IN ('FAILED', 'SUPPRESSED');

CREATE TABLE ops.provider_model_upgrade_receipts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  attempt_id uuid NOT NULL UNIQUE
    REFERENCES ops.provider_model_upgrade_attempts(id) ON DELETE RESTRICT,
  provider_id uuid NOT NULL REFERENCES ops.provider_configs(id) ON DELETE RESTRICT,
  target_model_id text NOT NULL REFERENCES ops.relay_model_catalog(model_id) ON DELETE RESTRICT,
  attempt_kind text NOT NULL,
  outcome text NOT NULL,
  before_provider_version bigint NOT NULL,
  after_provider_version bigint NOT NULL,
  before_model_id text,
  after_model_id text,
  policy_sha256 char(64),
  gateway_receipt_sha256 char(64),
  usage_evidence_sha256 char(64),
  audit_event_id uuid REFERENCES ops.audit_events(id) ON DELETE RESTRICT,
  incident_event_id uuid REFERENCES ops.incident_events(id) ON DELETE RESTRICT,
  cost_event_id uuid REFERENCES ops.cost_events(id) ON DELETE RESTRICT,
  receipt_canonical bytea NOT NULL,
  canonical_receipt jsonb NOT NULL,
  receipt_sha256 char(64) NOT NULL UNIQUE,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT provider_model_upgrade_receipts_outcome_ck CHECK (
    outcome IN ('APPLIED', 'FAILED', 'SUPPRESSED')
  ),
  CONSTRAINT provider_model_upgrade_receipts_attempt_kind_ck CHECK (
    attempt_kind IN ('MANUAL', 'AUTO')
  ),
  CONSTRAINT provider_model_upgrade_receipts_version_ck CHECK (
    before_provider_version > 0
    AND after_provider_version >= before_provider_version
  ),
  CONSTRAINT provider_model_upgrade_receipts_model_ck CHECK (
    (before_model_id IS NULL OR before_model_id ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,254}$')
    AND (after_model_id IS NULL OR after_model_id ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,254}$')
  ),
  CONSTRAINT provider_model_upgrade_receipts_digest_ck CHECK (
    (policy_sha256 IS NULL OR ops.is_lower_sha256(policy_sha256))
    AND (gateway_receipt_sha256 IS NULL OR ops.is_lower_sha256(gateway_receipt_sha256))
    AND (usage_evidence_sha256 IS NULL OR ops.is_lower_sha256(usage_evidence_sha256))
    AND ops.is_lower_sha256(receipt_sha256)
  ),
  CONSTRAINT provider_model_upgrade_receipts_result_ck CHECK (
    (
      outcome = 'APPLIED'
      AND after_provider_version = before_provider_version + 1
      AND after_model_id = target_model_id
      AND policy_sha256 IS NOT NULL
      AND gateway_receipt_sha256 IS NOT NULL
      AND usage_evidence_sha256 IS NOT NULL
      AND audit_event_id IS NOT NULL
      AND incident_event_id IS NULL
    )
    OR (
      outcome = 'FAILED'
      AND after_provider_version = before_provider_version
      AND after_model_id IS NOT DISTINCT FROM before_model_id
      AND (
        (
          attempt_kind = 'AUTO'
          AND audit_event_id IS NOT NULL
          AND incident_event_id IS NOT NULL
        )
        OR (
          attempt_kind = 'MANUAL'
          AND audit_event_id IS NULL
          AND incident_event_id IS NULL
        )
      )
    )
    OR (
      outcome = 'SUPPRESSED'
      AND attempt_kind = 'AUTO'
      AND after_provider_version = before_provider_version
      AND after_model_id IS NOT DISTINCT FROM before_model_id
      AND audit_event_id IS NULL
      AND incident_event_id IS NULL
      AND cost_event_id IS NULL
      AND gateway_receipt_sha256 IS NULL
      AND usage_evidence_sha256 IS NULL
    )
  ),
  CONSTRAINT provider_model_upgrade_receipts_canonical_ck CHECK (
    convert_from(receipt_canonical, 'UTF8')::jsonb = canonical_receipt
    AND receipt_sha256 = encode(
      extensions.digest(receipt_canonical, 'sha256'),
      'hex'
    )
    AND jsonb_typeof(canonical_receipt) = 'object'
    AND canonical_receipt ?& ARRAY[
      'schemaVersion',
      'receiptId',
      'attemptId',
      'providerId',
      'targetModelId',
      'attemptKind',
      'outcome',
      'beforeProviderVersion',
      'afterProviderVersion',
      'beforeModelId',
      'afterModelId',
      'policySha256',
      'gatewayReceiptSha256',
      'usageEvidenceSha256',
      'auditEventId',
      'incidentEventId',
      'costEventId',
      'recordedAt'
    ]
    AND canonical_receipt - ARRAY[
      'schemaVersion',
      'receiptId',
      'attemptId',
      'providerId',
      'targetModelId',
      'attemptKind',
      'outcome',
      'beforeProviderVersion',
      'afterProviderVersion',
      'beforeModelId',
      'afterModelId',
      'policySha256',
      'gatewayReceiptSha256',
      'usageEvidenceSha256',
      'auditEventId',
      'incidentEventId',
      'costEventId',
      'recordedAt'
    ] = '{}'::jsonb
    AND canonical_receipt->>'schemaVersion' = 'provider-model-upgrade-receipt.v1'
    AND canonical_receipt->>'receiptId' = id::text
    AND canonical_receipt->>'attemptId' = attempt_id::text
    AND canonical_receipt->>'providerId' = provider_id::text
    AND canonical_receipt->>'targetModelId' = target_model_id
    AND canonical_receipt->>'attemptKind' = attempt_kind
    AND canonical_receipt->>'outcome' = outcome
    AND (canonical_receipt->>'beforeProviderVersion')::bigint = before_provider_version
    AND (canonical_receipt->>'afterProviderVersion')::bigint = after_provider_version
    AND canonical_receipt->'beforeModelId'
      = COALESCE(to_jsonb(before_model_id), 'null'::jsonb)
    AND canonical_receipt->'afterModelId'
      = COALESCE(to_jsonb(after_model_id), 'null'::jsonb)
    AND canonical_receipt->'policySha256'
      = COALESCE(to_jsonb(btrim(policy_sha256::text)), 'null'::jsonb)
    AND canonical_receipt->'gatewayReceiptSha256'
      = COALESCE(to_jsonb(btrim(gateway_receipt_sha256::text)), 'null'::jsonb)
    AND canonical_receipt->'usageEvidenceSha256'
      = COALESCE(to_jsonb(btrim(usage_evidence_sha256::text)), 'null'::jsonb)
    AND canonical_receipt->'auditEventId'
      = COALESCE(to_jsonb(audit_event_id::text), 'null'::jsonb)
    AND canonical_receipt->'incidentEventId'
      = COALESCE(to_jsonb(incident_event_id::text), 'null'::jsonb)
    AND canonical_receipt->'costEventId'
      = COALESCE(to_jsonb(cost_event_id::text), 'null'::jsonb)
    AND (canonical_receipt->>'recordedAt')::timestamptz = recorded_at
  )
);
ALTER TABLE ops.provider_model_upgrade_receipts OWNER TO gurine_migrator;

CREATE FUNCTION ops.guard_provider_model_upgrade_receipt_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp
AS $$
DECLARE
  v_attempt ops.provider_model_upgrade_attempts%ROWTYPE;
  v_provider ops.provider_configs%ROWTYPE;
  v_audit ops.audit_events%ROWTYPE;
  v_incident ops.incident_events%ROWTYPE;
BEGIN
  SELECT * INTO v_attempt
  FROM ops.provider_model_upgrade_attempts
  WHERE id = NEW.attempt_id
  FOR SHARE;

  IF NOT FOUND
     OR NEW.provider_id <> v_attempt.provider_id
     OR NEW.target_model_id <> v_attempt.target_model_id
     OR NEW.attempt_kind <> v_attempt.attempt_kind
     OR NEW.before_provider_version <> v_attempt.expected_provider_version
     OR NEW.gateway_receipt_sha256 IS DISTINCT FROM v_attempt.gateway_receipt_sha256
     OR NEW.usage_evidence_sha256 IS DISTINCT FROM v_attempt.usage_evidence_sha256
     OR NOT (
       (NEW.outcome = 'APPLIED' AND v_attempt.status = 'SUCCEEDED')
       OR (NEW.outcome = 'FAILED' AND v_attempt.status = 'FAILED')
       OR (NEW.outcome = 'SUPPRESSED' AND v_attempt.status = 'SUPPRESSED')
     ) THEN
    RAISE EXCEPTION 'provider_model_upgrade_receipt_binding_invalid'
      USING ERRCODE = '23514';
  END IF;

  IF NEW.outcome = 'APPLIED' THEN
    SELECT * INTO v_provider
    FROM ops.provider_configs
    WHERE id = v_attempt.provider_id;
    IF NOT FOUND
       OR v_provider.version <> v_attempt.expected_provider_version + 1
       OR v_provider.version <> NEW.after_provider_version
       OR v_provider.routing_policy->>'model' IS DISTINCT FROM v_attempt.target_model_id
       OR v_provider.routing_policy#>>'{dataPolicy,state}' IS DISTINCT FROM 'CONFIGURED'
       OR v_provider.routing_policy#>>'{dataPolicy,policySha256}'
         IS DISTINCT FROM btrim(NEW.policy_sha256::text) THEN
      RAISE EXCEPTION 'provider_model_upgrade_receipt_applied_policy_invalid'
        USING ERRCODE = '23514';
    END IF;

    SELECT * INTO v_audit
    FROM ops.audit_events
    WHERE id = NEW.audit_event_id;
    IF NOT FOUND
       OR v_audit.actor_type <> 'SERVICE'
       OR v_audit.action <> 'provider.model_upgrade.applied'
       OR v_audit.object_type IS DISTINCT FROM 'ProviderModelUpgradeAttempt'
       OR v_audit.object_id IS DISTINCT FROM v_attempt.id::text
       OR v_audit.capability IS DISTINCT FROM 'jobs.operate'
       OR v_audit.outcome <> 'SUCCESS'
       OR v_audit.reason IS NOT NULL
       OR v_audit.request_id <> v_attempt.id
       OR v_audit.details <> jsonb_build_object(
         'attemptId', v_attempt.id,
         'providerId', v_attempt.provider_id,
         'targetModelId', v_attempt.target_model_id,
         'providerVersion', v_provider.version,
         'policySha256', btrim(NEW.policy_sha256::text),
         'gatewayReceiptSha256', btrim(NEW.gateway_receipt_sha256::text),
         'usageEvidenceSha256', btrim(NEW.usage_evidence_sha256::text)
       ) THEN
      RAISE EXCEPTION 'provider_model_upgrade_receipt_applied_audit_invalid'
        USING ERRCODE = '23514';
    END IF;
  ELSIF NEW.outcome = 'FAILED' AND NEW.attempt_kind = 'AUTO' THEN
    SELECT * INTO v_incident
    FROM ops.incident_events
    WHERE id = NEW.incident_event_id;
    IF NOT FOUND
       OR v_incident.incident_id <> v_attempt.id
       OR v_incident.event_sequence <> 1
       OR v_incident.prior_version <> 0
       OR v_incident.version <> 1
       OR v_incident.prior_state IS NOT NULL
       OR v_incident.state <> 'DETECTED'
       OR v_incident.transition_kind <> 'DETECTED'
       OR v_incident.severity <> 'SEV3'
       OR v_incident.affected_capabilities <> ARRAY['jobs.operate']::text[]
       OR v_incident.owner_user_id <> v_attempt.owner_user_id
       OR v_incident.reason_code <> v_attempt.last_error_code
       OR v_incident.audit_event_id <> NEW.audit_event_id THEN
      RAISE EXCEPTION 'provider_model_upgrade_receipt_failure_incident_invalid'
        USING ERRCODE = '23514';
    END IF;

    SELECT * INTO v_audit
    FROM ops.audit_events
    WHERE id = NEW.audit_event_id;
    IF NOT FOUND
       OR v_audit.actor_type <> 'SERVICE'
       OR v_audit.action <> 'provider.model_upgrade.failed'
       OR v_audit.object_type IS DISTINCT FROM 'ProviderModelUpgradeAttempt'
       OR v_audit.object_id IS DISTINCT FROM v_attempt.id::text
       OR v_audit.capability IS DISTINCT FROM 'jobs.operate'
       OR v_audit.outcome <> 'FAILED'
       OR v_audit.reason IS DISTINCT FROM v_attempt.last_error_code
       OR v_audit.request_id <> v_incident.request_id
       OR v_audit.details->>'attemptId' IS DISTINCT FROM v_attempt.id::text
       OR v_audit.details->>'providerId' IS DISTINCT FROM v_attempt.provider_id::text
       OR v_audit.details->>'targetModelId' IS DISTINCT FROM v_attempt.target_model_id
       OR ops.is_lower_sha256(v_audit.details->>'evidenceDigest') IS NOT TRUE
       OR v_incident.transition_detail->>'detectionSignalDigest'
         IS DISTINCT FROM v_audit.details->>'evidenceDigest'
       OR v_incident.evidence_refs->0->>'refId' IS DISTINCT FROM v_attempt.id::text
       OR (v_incident.evidence_refs->0->>'refVersion')::bigint
         IS DISTINCT FROM v_attempt.expected_provider_version
       OR v_incident.evidence_refs->0->>'refDigest'
         IS DISTINCT FROM v_audit.details->>'evidenceDigest' THEN
      RAISE EXCEPTION 'provider_model_upgrade_receipt_failure_audit_invalid'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END
$$;
ALTER FUNCTION ops.guard_provider_model_upgrade_receipt_v1()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.guard_provider_model_upgrade_receipt_v1()
  FROM PUBLIC;
CREATE TRIGGER provider_model_upgrade_receipts_binding
  BEFORE INSERT ON ops.provider_model_upgrade_receipts
  FOR EACH ROW EXECUTE FUNCTION ops.guard_provider_model_upgrade_receipt_v1();
CREATE TRIGGER provider_model_upgrade_receipts_immutable
  BEFORE UPDATE OR DELETE ON ops.provider_model_upgrade_receipts
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

CREATE FUNCTION ops.record_relay_model_upgrade_success_audit_v1(
  p_attempt_id uuid,
  p_policy_sha256 char(64),
  p_gateway_receipt_sha256 char(64),
  p_usage_evidence_sha256 char(64)
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp
AS $$
DECLARE
  v_attempt ops.provider_model_upgrade_attempts%ROWTYPE;
  v_provider ops.provider_configs%ROWTYPE;
  v_existing_audit_event_id uuid;
  v_audit_event_id uuid;
BEGIN
  IF NOT ops.is_lower_sha256(p_policy_sha256)
     OR NOT ops.is_lower_sha256(p_gateway_receipt_sha256)
     OR NOT ops.is_lower_sha256(p_usage_evidence_sha256) THEN
    RAISE EXCEPTION 'relay_model_upgrade_success_proof_invalid'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_attempt
  FROM ops.provider_model_upgrade_attempts
  WHERE id = p_attempt_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'relay_model_upgrade_attempt_not_found'
      USING ERRCODE = 'P0002';
  END IF;

  SELECT * INTO v_provider
  FROM ops.provider_configs
  WHERE id = v_attempt.provider_id;
  IF NOT FOUND
     OR v_attempt.status <> 'SUCCEEDED'
     OR v_attempt.gateway_receipt_sha256 IS DISTINCT FROM p_gateway_receipt_sha256
     OR v_attempt.usage_evidence_sha256 IS DISTINCT FROM p_usage_evidence_sha256
     OR v_provider.version <> v_attempt.expected_provider_version + 1
     OR v_provider.routing_policy->>'model' IS DISTINCT FROM v_attempt.target_model_id
     OR v_provider.routing_policy#>>'{dataPolicy,policySha256}'
       IS DISTINCT FROM p_policy_sha256 THEN
    RAISE EXCEPTION 'relay_model_upgrade_success_binding_invalid'
      USING ERRCODE = '23514';
  END IF;

  SELECT id INTO v_existing_audit_event_id
  FROM ops.audit_events
  WHERE request_id = p_attempt_id
    AND action = 'provider.model_upgrade.applied'
    AND object_type = 'ProviderModelUpgradeAttempt'
    AND object_id = p_attempt_id::text
  ORDER BY occurred_at, id
  LIMIT 1;
  IF FOUND THEN
    RETURN v_existing_audit_event_id;
  END IF;

  v_audit_event_id := ops.append_audit_event(
    'worker:relay-model-upgrade:' || p_attempt_id::text,
    'SERVICE',
    session_user,
    NULL::uuid,
    'provider.model_upgrade.applied',
    'ProviderModelUpgradeAttempt',
    p_attempt_id::text,
    'jobs.operate',
    'SUCCESS',
    NULL,
    p_attempt_id,
    jsonb_build_object(
      'attemptId', p_attempt_id,
      'providerId', v_attempt.provider_id,
      'targetModelId', v_attempt.target_model_id,
      'providerVersion', v_provider.version,
      'policySha256', p_policy_sha256,
      'gatewayReceiptSha256', p_gateway_receipt_sha256,
      'usageEvidenceSha256', p_usage_evidence_sha256
    )
  );
  RETURN v_audit_event_id;
END
$$;
ALTER FUNCTION ops.record_relay_model_upgrade_success_audit_v1(
  uuid, char(64), char(64), char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.record_relay_model_upgrade_success_audit_v1(
  uuid, char(64), char(64), char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.record_relay_model_upgrade_success_audit_v1(
  uuid, char(64), char(64), char(64)
) TO gurine_analysis_worker;

CREATE FUNCTION ops.record_relay_model_upgrade_failure_incident_v1(
  p_attempt_id uuid,
  p_owner_user_id uuid,
  p_error_code text,
  p_evidence_digest char(64)
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ops, extensions, pg_temp
AS $$
DECLARE
  v_attempt ops.provider_model_upgrade_attempts%ROWTYPE;
  v_incident_event_id uuid;
  v_audit_event_id uuid;
  v_request_id uuid := gen_random_uuid();
  v_occurred_at timestamptz := clock_timestamp();
  v_evidence_refs jsonb;
  v_evidence_set_digest char(64);
  v_receipt_digest char(64);
BEGIN
  IF NOT ops.is_lower_sha256(p_evidence_digest) THEN
    RAISE EXCEPTION 'relay_model_upgrade_failure_evidence_invalid'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_attempt
  FROM ops.provider_model_upgrade_attempts
  WHERE id = p_attempt_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'relay_model_upgrade_attempt_not_found'
      USING ERRCODE = 'P0002';
  END IF;
  IF v_attempt.attempt_kind <> 'AUTO'
     OR v_attempt.status <> 'FAILED'
     OR v_attempt.owner_user_id <> p_owner_user_id
     OR v_attempt.last_error_code IS DISTINCT FROM p_error_code THEN
    RAISE EXCEPTION 'relay_model_upgrade_failure_binding_invalid'
      USING ERRCODE = '23514';
  END IF;

  SELECT id INTO v_incident_event_id
  FROM ops.incident_events
  WHERE incident_id = p_attempt_id
    AND event_sequence = 1;
  IF FOUND THEN
    RETURN v_incident_event_id;
  END IF;

  v_evidence_refs := jsonb_build_array(jsonb_build_object(
    'kind', 'PROVIDER_RECEIPT',
    'refId', p_attempt_id::text,
    'refVersion', v_attempt.expected_provider_version,
    'refDigest', p_evidence_digest,
    'observedAt', v_occurred_at
  ));
  v_evidence_set_digest := encode(
    extensions.digest(convert_to(v_evidence_refs::text, 'UTF8'), 'sha256'),
    'hex'
  );

  BEGIN
  v_audit_event_id := ops.append_audit_event(
    'worker:relay-model-upgrade:' || p_attempt_id::text,
    'SERVICE',
    session_user,
    NULL::uuid,
    'provider.model_upgrade.failed',
    'ProviderModelUpgradeAttempt',
    p_attempt_id::text,
    'jobs.operate',
    'FAILED',
    p_error_code,
    v_request_id,
    jsonb_build_object(
      'attemptId', p_attempt_id,
      'providerId', v_attempt.provider_id,
      'targetModelId', v_attempt.target_model_id,
      'evidenceDigest', p_evidence_digest
    )
  );

  v_receipt_digest := encode(
    extensions.digest(
      convert_to(
        jsonb_build_object(
          'incidentId', p_attempt_id,
          'attemptId', p_attempt_id,
          'providerId', v_attempt.provider_id,
          'targetModelId', v_attempt.target_model_id,
          'ownerUserId', p_owner_user_id,
          'errorCode', p_error_code,
          'evidenceSetDigest', v_evidence_set_digest,
          'auditEventId', v_audit_event_id,
          'requestId', v_request_id,
          'occurredAt', v_occurred_at
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  INSERT INTO ops.incident_events (
    incident_id,
    event_sequence,
    prior_version,
    version,
    prior_state,
    state,
    transition_kind,
    severity,
    affected_capabilities,
    owner_user_id,
    commander_user_id,
    next_update_at,
    transition_detail,
    evidence_refs,
    evidence_set_digest,
    reason_code,
    reason,
    actor_type,
    actor_id,
    idempotency_key_sha256,
    actor_assertion_jti,
    request_id,
    audit_event_id,
    receipt_digest,
    occurred_at
  ) VALUES (
    p_attempt_id,
    1,
    0,
    1,
    NULL,
    'DETECTED',
    'DETECTED',
    'SEV3',
    ARRAY['jobs.operate']::text[],
    p_owner_user_id,
    NULL,
    v_occurred_at + interval '1 hour',
    jsonb_build_object(
      'transitionKind', 'DETECTED',
      'detectionSignalType', 'PROVIDER_OUTAGE',
      'detectionSignalDigest', p_evidence_digest,
      'impact', 'Relay model auto-upgrade failed'
    ),
    v_evidence_refs,
    v_evidence_set_digest,
    p_error_code,
    'Relay model auto-upgrade failed',
    'SERVICE',
    session_user,
    NULL,
    NULL,
    v_request_id,
    v_audit_event_id,
    v_receipt_digest,
    v_occurred_at
  )
  RETURNING id INTO v_incident_event_id;
  EXCEPTION WHEN unique_violation THEN
    SELECT id INTO v_incident_event_id
    FROM ops.incident_events
    WHERE incident_id = p_attempt_id
      AND event_sequence = 1;
    IF FOUND THEN
      RETURN v_incident_event_id;
    END IF;
    RAISE;
  END;

  RETURN v_incident_event_id;
END
$$;
ALTER FUNCTION ops.record_relay_model_upgrade_failure_incident_v1(
  uuid, uuid, text, char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.record_relay_model_upgrade_failure_incident_v1(
  uuid, uuid, text, char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.record_relay_model_upgrade_failure_incident_v1(
  uuid, uuid, text, char(64)
) TO gurine_analysis_worker;

REVOKE ALL ON ops.relay_model_catalog,
  ops.relay_model_catalog_sync_runs,
  ops.provider_model_upgrade_attempts,
  ops.provider_model_upgrade_receipts
FROM PUBLIC;

GRANT SELECT ON ops.relay_model_catalog,
  ops.relay_model_catalog_sync_runs,
  ops.provider_model_upgrade_attempts,
  ops.provider_model_upgrade_receipts
TO gurine_control_api, gurine_auditor;
GRANT SELECT, INSERT, UPDATE ON ops.relay_model_catalog,
  ops.relay_model_catalog_sync_runs,
  ops.provider_model_upgrade_attempts
TO gurine_analysis_worker;
GRANT SELECT, INSERT ON ops.provider_model_upgrade_receipts
TO gurine_analysis_worker;
GRANT INSERT ON ops.provider_connection_tests, ops.jobs, ops.cost_events
TO gurine_analysis_worker;
GRANT INSERT ON ops.provider_model_upgrade_attempts
TO gurine_control_api;
GRANT SELECT, INSERT ON ops.relay_model_catalog_sync_runs
TO gurine_scheduler;

-- Provider lineage may only reference a receipt accepted on the completed
-- provider turn. Pre-dispatch identities are not provider receipts.
CREATE OR REPLACE FUNCTION ops.enforce_agent_source_use_provider_receipt_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp
AS $$
BEGIN
  IF NEW.use_kind IN ('MODEL_INPUT', 'MODEL_OUTPUT_DERIVATION') THEN
    IF NOT EXISTS (
      SELECT 1
      FROM ops.agent_provider_turns turn
      WHERE turn.agent_run_id = NEW.agent_run_id
        AND turn.provider_turn_id = NEW.provider_turn_id
        AND turn.status = 'COMPLETED'
        AND turn.provider_receipt_id = NEW.provider_receipt_id
        AND turn.provider_receipt_sha256 = NEW.provider_receipt_sha256
    ) THEN
      RAISE EXCEPTION 'SOURCE_USE_PROVIDER_RECEIPT_MISMATCH'
        USING ERRCODE = '23503';
    END IF;
  END IF;
  RETURN NEW;
END
$$;
ALTER FUNCTION ops.enforce_agent_source_use_provider_receipt_v1()
  OWNER TO gurine_migrator;

INSERT INTO ops.provider_configs (
  id,
  provider_type,
  name,
  enabled,
  routing_policy,
  secret_reference,
  data_retention_policy,
  version
) VALUES (
  '3df98ddb-a9a6-5d61-8cce-63976b5cb21a',
  'relay',
  'Gurinnae Relay AI',
  false,
  jsonb_build_object(
    'targetUrl', 'https://relay-ai.dongwontuna.net/v1/chat/completions',
    'autoUpgrade', false,
    'dataPolicy', jsonb_build_object('state', 'UNCONFIGURED'),
    'pricing', jsonb_build_object(
      'pricingVersion', 'relay-unpriced-v1',
      'pricingSha256', 'c37a15d1b3c6bfe5ab0a96d593d277592808673c5bae5799c45a36370fc33581',
      'currency', 'KRW',
      'inputMicrosKrwPerUnit', 0,
      'outputMicrosKrwPerUnit', 0
    )
  ),
  'env:AI_RELAY_API_KEY',
  'UNCONFIGURED',
  1
)
ON CONFLICT DO NOTHING;
