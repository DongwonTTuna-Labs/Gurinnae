-- Q8 extends the governed action catalogue by one outer kind.  The four
-- provider commands remain a closed discriminator inside its typed detail.
ALTER TABLE ops.action_proposals
  DROP CONSTRAINT action_proposals_action_kind_check;
ALTER TABLE ops.action_proposals
  ADD CONSTRAINT action_proposals_action_kind_check CHECK (action_kind IN (
    'HYPOTHESIS','CLAIM','TASK','COMPARABLE','COMMUNICATION','PUBLICATION',
    'RETRACTION','RULE_ACTIVATION','ROLE_GRANT','KILL_SWITCH',
    'COMMUNICATION_AUTHORIZATION','ASSET_RIGHTS_DECISION','RETENTION_SCHEDULE',
    'FUNDING_DISCLOSURE','CAPABILITY_ACTIVATION','RESPONSE_POLICY_CALENDAR',
    'COMMERCIAL_CONTROL','PROVIDER_CONTROL'
  ));

ALTER TABLE ops.action_proposal_versions
  DROP CONSTRAINT action_proposal_versions_detail_kind_check;
ALTER TABLE ops.action_proposal_versions
  ADD CONSTRAINT action_proposal_versions_detail_kind_check CHECK (
    action_detail_kind IS NULL OR action_detail_kind IN (
      'HYPOTHESIS','CLAIM','TASK','COMPARABLE','COMMUNICATION','PUBLICATION',
      'RETRACTION','RULE_ACTIVATION','ROLE_GRANT','KILL_SWITCH',
      'COMMUNICATION_AUTHORIZATION','ASSET_RIGHTS_DECISION','RETENTION_SCHEDULE',
      'FUNDING_DISCLOSURE','CAPABILITY_ACTIVATION','RESPONSE_POLICY_CALENDAR',
      'COMMERCIAL_CONTROL','PROVIDER_CONTROL'
    )
  );

ALTER TABLE ops.in_flight_effects
  DROP CONSTRAINT in_flight_effects_action_kind_check;
ALTER TABLE ops.in_flight_effects
  ADD CONSTRAINT in_flight_effects_action_kind_check CHECK (
    action_kind IS NULL OR action_kind IN (
      'HYPOTHESIS','CLAIM','TASK','COMPARABLE','COMMUNICATION','PUBLICATION',
      'RETRACTION','RULE_ACTIVATION','ROLE_GRANT','KILL_SWITCH',
      'COMMUNICATION_AUTHORIZATION','ASSET_RIGHTS_DECISION','RETENTION_SCHEDULE',
      'FUNDING_DISCLOSURE','CAPABILITY_ACTIVATION','RESPONSE_POLICY_CALENDAR',
      'COMMERCIAL_CONTROL','PROVIDER_CONTROL'
    )
  );

ALTER TABLE ops.execution_authorizations
  DROP CONSTRAINT execution_authorizations_action_kind_check;
ALTER TABLE ops.execution_authorizations
  ADD CONSTRAINT execution_authorizations_action_kind_check CHECK (action_kind IN (
    'HYPOTHESIS','CLAIM','TASK','COMPARABLE','COMMUNICATION','PUBLICATION',
    'RETRACTION','RULE_ACTIVATION','ROLE_GRANT','KILL_SWITCH',
    'COMMUNICATION_AUTHORIZATION','ASSET_RIGHTS_DECISION','RETENTION_SCHEDULE',
    'FUNDING_DISCLOSURE','CAPABILITY_ACTIVATION','RESPONSE_POLICY_CALENDAR',
    'COMMERCIAL_CONTROL','PROVIDER_CONTROL'
  ));

-- The shared reviewer conflict snapshot stores the governed ActionKind and
-- the actual eligible reviewer role selected by submitActionForReview.
ALTER TABLE editorial.conflict_snapshots
  DROP CONSTRAINT conflict_snapshots_action_kind_ck;
ALTER TABLE editorial.conflict_snapshots
  ADD CONSTRAINT conflict_snapshots_action_kind_ck CHECK (
    action_kind IS NULL OR action_kind IN (
      'HYPOTHESIS','CLAIM','TASK','COMPARABLE','COMMUNICATION','PUBLICATION',
      'RETRACTION','RULE_ACTIVATION','ROLE_GRANT','KILL_SWITCH',
      'COMMUNICATION_AUTHORIZATION','ASSET_RIGHTS_DECISION','RETENTION_SCHEDULE',
      'FUNDING_DISCLOSURE','CAPABILITY_ACTIVATION','RESPONSE_POLICY_CALENDAR',
      'PROVIDER_CONTROL'
    )
  );
ALTER TABLE editorial.conflict_snapshots
  DROP CONSTRAINT conflict_snapshots_candidate_role_ck;
ALTER TABLE editorial.conflict_snapshots
  ADD CONSTRAINT conflict_snapshots_candidate_role_ck CHECK (candidate_role IN (
    'AUTHOR','EDITOR','LEGAL_REVIEWER','PUBLISHER','APPROVER','EXECUTOR','OPERATIONS'
  ));

-- Match the existing typed-detail validator catalogue: canonical byte
-- structure is bound by the parent ActionApprovalDetailBindingV1 digest and
-- the typed columns below, while the per-kind validator rejects empty bytes.
CREATE FUNCTION ops.action_approval_provider_control_detail_v1_is_valid(bytea)
RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,pg_temp
AS $$ SELECT $1 IS NOT NULL AND octet_length($1)>0 $$;
ALTER FUNCTION ops.action_approval_provider_control_detail_v1_is_valid(bytea)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.action_approval_provider_control_detail_v1_is_valid(bytea)
  FROM PUBLIC;

CREATE TABLE ops.action_approval_provider_control_details (
  proposal_id uuid NOT NULL,
  proposal_version bigint NOT NULL,
  detail_kind text NOT NULL,
  detail_binding_canonical bytea NOT NULL,
  action_detail_digest char(64) NOT NULL,
  approval_digest char(64) NOT NULL,
  content_digest char(64) NOT NULL,
  operation_id text NOT NULL,
  provider_reference text NOT NULL,
  provider_id uuid NOT NULL REFERENCES ops.provider_configs(id) ON DELETE RESTRICT,
  expected_provider_version bigint NOT NULL,
  reason_digest char(64),
  creator_actor_id uuid NOT NULL REFERENCES ops.users(id) ON DELETE RESTRICT,
  required_creator_capability text NOT NULL,
  provider_configuration_digest char(64) NOT NULL,
  provider_idempotency_key_sha256 char(64) NOT NULL,
  test_model text,
  target_model_id text,
  requested_processing_region text,
  requested_retention_mode text,
  requested_policy_version text,
  requested_policy_sha256 char(64),
  auto_upgrade_enabled boolean,
  auto_upgrade_track text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT action_approval_provider_control_details_pk
    PRIMARY KEY (proposal_id, proposal_version),
  CONSTRAINT action_approval_provider_control_details_binding_uq UNIQUE (
    proposal_id, proposal_version, detail_kind, action_detail_digest
  ),
  CONSTRAINT action_approval_provider_control_details_approval_uq UNIQUE (
    proposal_id, proposal_version, approval_digest, operation_id,
    provider_id, expected_provider_version
  ),
  CONSTRAINT action_approval_provider_control_details_kind_ck
    CHECK (detail_kind='PROVIDER_CONTROL'),
  CONSTRAINT action_approval_provider_control_details_operation_ck CHECK (
    operation_id IN (
      'disableProviderRouting','testProviderConnection',
      'upgradeProviderModel','setModelAutoUpgrade'
    )
  ),
  CONSTRAINT action_approval_provider_control_details_scalar_ck CHECK (
    expected_provider_version>0
    AND length(btrim(provider_reference)) BETWEEN 1 AND 100
    AND provider_configuration_digest ~ '^[0-9a-f]{64}$'
    AND provider_idempotency_key_sha256 ~ '^[0-9a-f]{64}$'
    AND action_detail_digest ~ '^[0-9a-f]{64}$'
    AND approval_digest ~ '^[0-9a-f]{64}$'
    AND content_digest ~ '^[0-9a-f]{64}$'
    AND (reason_digest IS NULL OR reason_digest ~ '^[0-9a-f]{64}$')
  ),
  CONSTRAINT action_approval_provider_control_details_capability_ck CHECK (
    (operation_id='testProviderConnection' AND required_creator_capability='jobs.operate')
    OR (operation_id<>'testProviderConnection'
        AND required_creator_capability='kill_switch.execute')
  ),
  CONSTRAINT action_approval_provider_control_details_policy_all_or_none_ck CHECK (
    num_nonnulls(
      requested_processing_region,requested_retention_mode,
      requested_policy_version,requested_policy_sha256
    ) IN (0,4)
  ),
  CONSTRAINT action_approval_provider_control_details_policy_ck CHECK (
    requested_processing_region IS NULL OR (
      requested_processing_region ~ '^[A-Z]{2}(?:-[A-Z0-9]{1,12})?$'
      AND requested_retention_mode IN (
        'ZERO_RETENTION','BOUNDED_PROVIDER_RETENTION','LOCAL_ONLY'
      )
      AND length(btrim(requested_policy_version)) BETWEEN 1 AND 64
      AND requested_policy_sha256 ~ '^[0-9a-f]{64}$'
    )
  ),
  CONSTRAINT action_approval_provider_control_details_branch_ck CHECK (
    (
      operation_id='disableProviderRouting'
      AND reason_digest IS NOT NULL
      AND test_model IS NULL AND target_model_id IS NULL
      AND requested_processing_region IS NULL
      AND auto_upgrade_enabled IS NULL AND auto_upgrade_track IS NULL
    ) OR (
      operation_id='testProviderConnection'
      AND test_model IS NOT NULL
      AND length(btrim(test_model)) BETWEEN 1 AND 255
      AND target_model_id IS NULL AND requested_processing_region IS NULL
      AND auto_upgrade_enabled IS NULL AND auto_upgrade_track IS NULL
    ) OR (
      operation_id='upgradeProviderModel'
      AND reason_digest IS NOT NULL
      AND target_model_id IS NOT NULL
      AND length(btrim(target_model_id)) BETWEEN 1 AND 255
      AND test_model IS NULL
      AND auto_upgrade_enabled IS NULL AND auto_upgrade_track IS NULL
    ) OR (
      operation_id='setModelAutoUpgrade'
      AND reason_digest IS NOT NULL
      AND test_model IS NULL AND target_model_id IS NULL
      AND requested_processing_region IS NULL
      AND auto_upgrade_enabled IS NOT NULL
      AND (
        (NOT auto_upgrade_enabled AND (
          auto_upgrade_track IS NULL
          OR length(btrim(auto_upgrade_track)) BETWEEN 1 AND 128
        ))
        OR (
          auto_upgrade_enabled
          AND auto_upgrade_track IS NOT NULL
          AND length(btrim(auto_upgrade_track)) BETWEEN 1 AND 128
        )
      )
    )
  ),
  CONSTRAINT action_approval_provider_control_details_canonical_ck CHECK (
    octet_length(detail_binding_canonical)>0
  ),
  CONSTRAINT action_approval_provider_control_details_version_fk FOREIGN KEY (
    proposal_id,proposal_version,detail_kind,action_detail_digest
  ) REFERENCES ops.action_proposal_versions(
    proposal_id,version,action_detail_kind,action_detail_digest
  ) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  CONSTRAINT action_approval_provider_control_details_approval_fk FOREIGN KEY (
    proposal_id,proposal_version,approval_digest
  ) REFERENCES ops.action_proposal_versions(
    proposal_id,version,approval_digest
  ) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED
);
ALTER TABLE ops.action_approval_provider_control_details OWNER TO gurine_migrator;
REVOKE ALL ON ops.action_approval_provider_control_details FROM PUBLIC;
REVOKE ALL ON ops.action_approval_provider_control_details
  FROM gurine_control_api,gurine_analysis_worker,gurine_workflow_worker,
       gurine_public_projector,gurine_notification_worker,gurine_submission_api,
       gurine_auditor;
CREATE TRIGGER ops_action_approval_provider_control_details_immutable
  BEFORE UPDATE OR DELETE ON ops.action_approval_provider_control_details
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

-- These NOLOGIN owner privileges are consumed only through the fixed-path
-- SECURITY DEFINER proposal and execution routines below.  Keep the runtime
-- worker on EXECUTE-only access while allowing the owner to lock the exact
-- provider snapshot, read its inbox event and append measured test evidence.
GRANT SELECT ON ops.inbox TO gurine_migrator;
GRANT UPDATE (
  enabled,routing_policy,data_retention_policy,last_connection_test_at,
  last_connection_test_status,version
) ON ops.provider_configs TO gurine_migrator;
GRANT INSERT ON ops.provider_connection_tests TO gurine_migrator;

CREATE FUNCTION ops.claim_provider_control_execution_v1(
  p_event_id uuid,
  p_execution_id uuid,
  p_generation bigint,
  p_execution_digest char(64),
  p_target_request_sha256 char(64),
  p_worker_id text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_now timestamptz:=clock_timestamp();
  v_auth ops.execution_authorizations%ROWTYPE;
  v_detail ops.action_approval_provider_control_details%ROWTYPE;
  v_attempt ops.execution_attempts%ROWTYPE;
  v_effect ops.in_flight_effects%ROWTYPE;
  v_provider ops.provider_configs%ROWTYPE;
  v_routing_snapshot jsonb;
  v_routing_digest char(64);
  v_lease_token uuid:=gen_random_uuid();
  v_fencing_token bigint;
  v_sequence bigint;
  v_receipt_id uuid:=gen_random_uuid();
  v_receipt_payload jsonb;
  v_receipt_canonical bytea;
  v_receipt_digest char(64);
  v_claim jsonb;
BEGIN
  IF session_user<>'gurine_analysis_worker'
     OR p_event_id IS NULL OR p_execution_id IS NULL OR p_generation<1
     OR p_execution_digest !~ '^[0-9a-f]{64}$'
     OR p_target_request_sha256 !~ '^[0-9a-f]{64}$'
     OR length(btrim(COALESCE(p_worker_id,''))) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'provider_control_claim_invalid' USING ERRCODE='22023';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM ops.inbox i
     WHERE i.consumer='provider-control-execution-worker' AND i.event_id=p_event_id
       AND i.processed_at IS NULL
  ) THEN
    RAISE EXCEPTION 'provider_control_event_not_claimable' USING ERRCODE='40001';
  END IF;

  SELECT * INTO v_auth FROM ops.execution_authorizations a
   WHERE a.execution_id=p_execution_id AND a.generation=p_generation
   FOR SHARE;
  IF NOT FOUND OR v_auth.action_kind<>'PROVIDER_CONTROL'
     OR v_auth.executor_id<>'private.ExecuteProviderControl'
     OR v_auth.transport<>'PRIVATE_APPLICATION_COMMAND'
     OR v_auth.outbox_id<>p_event_id
     OR btrim(v_auth.execution_digest::text)<>btrim(p_execution_digest::text)
     OR btrim(v_auth.target_request_sha256::text)<>btrim(p_target_request_sha256::text)
     OR v_auth.expires_at<=v_now THEN
    RAISE EXCEPTION 'provider_control_authorization_invalid' USING ERRCODE='40001';
  END IF;

  SELECT * INTO v_detail
    FROM ops.action_approval_provider_control_details d
   WHERE d.proposal_id=v_auth.proposal_id
     AND d.proposal_version=v_auth.proposal_version
     AND d.approval_digest=v_auth.approval_digest
   FOR SHARE;
  IF NOT FOUND OR v_detail.detail_kind<>'PROVIDER_CONTROL'
     OR v_detail.content_digest<>v_auth.target_request_sha256
     OR v_detail.required_creator_capability<>v_auth.required_capability THEN
    RAISE EXCEPTION 'provider_control_detail_binding_invalid' USING ERRCODE='23514';
  END IF;

  SELECT * INTO v_provider FROM ops.provider_configs p
   WHERE p.id=v_detail.provider_id FOR SHARE;
  IF NOT FOUND OR v_provider.version<>v_detail.expected_provider_version THEN
    RAISE EXCEPTION 'provider_control_provider_version_stale' USING ERRCODE='40001';
  END IF;
  v_routing_snapshot:=jsonb_build_object(
    'providerType',v_provider.provider_type,'enabled',v_provider.enabled,
    'routingPolicy',v_provider.routing_policy,
    'dataRetentionPolicy',v_provider.data_retention_policy,
    'version',v_provider.version);
  v_routing_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_routing_snapshot),'sha256'),'hex');
  IF v_routing_digest<>v_detail.provider_configuration_digest THEN
    RAISE EXCEPTION 'provider_control_provider_configuration_stale' USING ERRCODE='40001';
  END IF;
  IF (
       v_detail.operation_id IN ('testProviderConnection','upgradeProviderModel')
       AND (
         v_auth.effect_boundary<>'PROVIDER'
         OR v_auth.provider_config_id IS DISTINCT FROM v_detail.provider_id
         OR v_auth.provider_config_version IS DISTINCT FROM v_detail.expected_provider_version
         OR v_auth.provider_configuration_digest<>v_detail.provider_configuration_digest
         OR v_auth.provider_idempotency_key_sha256<>v_detail.provider_idempotency_key_sha256
       )
     ) OR (
       v_detail.operation_id IN ('disableProviderRouting','setModelAutoUpgrade')
       AND (
         v_auth.effect_boundary<>'DATABASE_ONLY'
         OR v_auth.provider_config_id IS NOT NULL OR v_auth.provider_config_version IS NOT NULL
         OR v_auth.provider_configuration_digest<>
           '8682eb9449f61b9d8c9e36d481638e3ffafcd9e66b490d42afde6fc847560fde'
         OR v_auth.provider_idempotency_key_sha256<>
           '36e6cda205ff7692fef24261d22e17e282ecc3bba7f5d04f41310839d90e3e74'
       )
     ) THEN
    RAISE EXCEPTION 'provider_control_effect_boundary_invalid' USING ERRCODE='23514';
  END IF;

  SELECT * INTO v_effect FROM ops.in_flight_effects e
   WHERE e.id=p_execution_id AND e.action_kind='PROVIDER_CONTROL' FOR UPDATE;
  SELECT * INTO v_attempt FROM ops.execution_attempts a
   WHERE a.execution_id=p_execution_id AND a.generation=p_generation FOR UPDATE;
  IF v_effect.id IS NULL OR v_attempt.id IS NULL
     OR v_effect.current_generation<>p_generation
     OR v_effect.last_receipt_sequence<>v_attempt.last_receipt_sequence
     OR v_effect.last_receipt_digest<>v_attempt.last_receipt_digest THEN
    RAISE EXCEPTION 'provider_control_execution_chain_invalid' USING ERRCODE='23514';
  END IF;

  IF v_attempt.attempt_state='DISPATCHING'
     AND v_attempt.lease_expires_at>v_now
     AND v_attempt.lease_owner=p_worker_id THEN
    v_fencing_token:=v_attempt.fencing_token;
  ELSE
    IF NOT (
      v_attempt.attempt_state='QUEUED'
      OR (v_attempt.attempt_state='DISPATCHING'
          AND v_attempt.lease_expires_at<=v_now)
    ) OR v_effect.state NOT IN ('QUEUED','RUNNING')
       OR v_effect.dispatch_attempt_count>=3 THEN
      RAISE EXCEPTION 'provider_control_execution_not_claimable' USING ERRCODE='40001';
    END IF;
    v_fencing_token:=v_attempt.fencing_token+1;
    v_sequence:=v_effect.last_receipt_sequence+1;
    v_receipt_payload:=jsonb_build_object(
      'schemaVersion','action-execution-receipt.v1',
      'receiptKind','DISPATCH_STARTED','executionId',p_execution_id,
      'generation',p_generation,'aggregateState','RUNNING',
      'aggregateStateVersion',v_effect.state_version+1,
      'attemptState','DISPATCHING','attemptStateVersion',v_attempt.state_version+1,
      'cancellationGeneration',v_effect.cancellation_generation,
      'effectCertainty','DEFINITIVE_NOT_ACCEPTED',
      'executionDigest',v_auth.execution_digest,
      'targetRequestSha256',v_auth.target_request_sha256,
      'providerOperationId',v_detail.operation_id,
      'fencingToken',v_fencing_token,'requestId',v_auth.request_id,
      'occurredAt',v_now);
    v_receipt_canonical:=ops.canonical_jsonb_v1(v_receipt_payload);
    v_receipt_digest:=encode(extensions.digest(v_receipt_canonical,'sha256'),'hex');
    INSERT INTO ops.execution_receipts(
      id,execution_id,generation,attempt_id,receipt_sequence,receipt_kind,
      mutates_aggregate_state,prior_aggregate_state,aggregate_state,
      aggregate_state_version,prior_attempt_state,attempt_state,fencing_token,
      cancellation_generation,proof_kind,proof_digest,receipt_payload,
      receipt_payload_canonical,budget_reservation_digest,request_id,
      audit_event_id,outbox_id,observed_at,prior_receipt_digest,receipt_digest)
    VALUES(
      v_receipt_id,p_execution_id,p_generation,v_attempt.id,v_sequence,
      'DISPATCH_STARTED',true,v_effect.state,'RUNNING',v_effect.state_version+1,
      v_attempt.attempt_state,'DISPATCHING',v_fencing_token,
      v_effect.cancellation_generation,'DEFINITIVE_NOT_ACCEPTED',
      v_detail.action_detail_digest,v_receipt_payload,v_receipt_canonical,
      v_auth.budget_reservation_digest,v_auth.request_id,v_auth.audit_event_id,
      NULL,v_now,v_effect.last_receipt_digest,v_receipt_digest);
    UPDATE ops.execution_attempts SET
      attempt_state='DISPATCHING',state_version=state_version+1,
      dispatch_ordinal=COALESCE(dispatch_ordinal,0)+1,
      lease_owner=p_worker_id,lease_token=v_lease_token,
      lease_expires_at=v_now+interval '15 minutes',fencing_token=v_fencing_token,
      claimed_at=COALESCE(claimed_at,v_now),dispatch_started_at=v_now,
      last_receipt_sequence=v_sequence,last_receipt_digest=v_receipt_digest,
      updated_at=v_now
     WHERE id=v_attempt.id;
    UPDATE ops.in_flight_effects SET
      state='RUNNING',state_version=state_version+1,
      dispatch_attempt_count=dispatch_attempt_count+1,
      last_receipt_sequence=v_sequence,last_receipt_digest=v_receipt_digest,
      updated_at=v_now
     WHERE id=p_execution_id;
  END IF;

  v_claim:=jsonb_build_object(
    'schemaVersion','provider-control-execution-claim.v1',
    'executionId',p_execution_id,'generation',p_generation,
    'attemptId',v_attempt.id,'fencingToken',v_fencing_token,
    'executionDigest',v_auth.execution_digest,
    'approvalDigest',v_auth.approval_digest,
    'actionDetailDigest',v_detail.action_detail_digest,
    'targetRequestSha256',v_auth.target_request_sha256,
    'operationId',v_detail.operation_id,
    'providerReference',v_detail.provider_reference,
    'providerId',v_detail.provider_id,
    'expectedProviderVersion',v_detail.expected_provider_version,
    'creatorActorId',v_detail.creator_actor_id,
    'providerRoutingSnapshot',v_routing_snapshot,
    'providerConfigurationDigest',v_detail.provider_configuration_digest,
    'providerIdempotencyKeySha256',v_detail.provider_idempotency_key_sha256,
    'expiresAt',v_auth.expires_at);
  IF v_detail.reason_digest IS NOT NULL THEN
    v_claim:=v_claim||jsonb_build_object('reasonDigest',v_detail.reason_digest);
  END IF;
  IF v_detail.operation_id='testProviderConnection' THEN
    v_claim:=v_claim||jsonb_build_object('testModel',v_detail.test_model);
  ELSIF v_detail.operation_id='upgradeProviderModel' THEN
    v_claim:=v_claim||jsonb_build_object(
      'targetModelId',v_detail.target_model_id,
      'requestedDataPolicy',CASE
      WHEN v_detail.requested_processing_region IS NOT NULL THEN jsonb_build_object(
        'processingRegion',v_detail.requested_processing_region,
        'retentionMode',v_detail.requested_retention_mode,
        'policyVersion',v_detail.requested_policy_version,
        'policySha256',v_detail.requested_policy_sha256)
      ELSE 'null'::jsonb END);
  ELSIF v_detail.operation_id='setModelAutoUpgrade' THEN
    v_claim:=v_claim||jsonb_build_object(
      'autoUpgradeEnabled',v_detail.auto_upgrade_enabled,
      'autoUpgradeTrack',COALESCE(to_jsonb(v_detail.auto_upgrade_track),'null'::jsonb));
  END IF;
  RETURN v_claim;
END $$;
ALTER FUNCTION ops.claim_provider_control_execution_v1(
  uuid,uuid,bigint,char(64),char(64),text
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.claim_provider_control_execution_v1(
  uuid,uuid,bigint,char(64),char(64),text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.claim_provider_control_execution_v1(
  uuid,uuid,bigint,char(64),char(64),text
) TO gurine_analysis_worker;

CREATE FUNCTION ops.provider_control_execution_result_v1_is_valid(
  p_result jsonb,
  p_expected_operation text
) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,ops,pg_temp
AS $$
DECLARE
  v_usage jsonb;
  v_input numeric;
  v_output numeric;
  v_cached numeric;
  v_billable numeric;
BEGIN
  IF p_result IS NULL OR jsonb_typeof(p_result)<>'object'
     OR p_result->>'schemaVersion'<>'provider-control-execution-result.v1'
     OR p_result->>'operationId' IS DISTINCT FROM p_expected_operation THEN
    RETURN false;
  END IF;
  IF p_result->>'outcome'='NO_EGRESS' THEN
    RETURN p_expected_operation IN (
      'disableProviderRouting','setModelAutoUpgrade'
    ) AND p_result ?& ARRAY['schemaVersion','outcome','operationId']
      AND p_result-ARRAY['schemaVersion','outcome','operationId']='{}'::jsonb;
  END IF;
  IF p_result->>'outcome'<>'PROVIDER_SUCCESS'
     OR p_expected_operation NOT IN (
       'testProviderConnection','upgradeProviderModel'
     )
     OR NOT p_result ?& ARRAY[
       'schemaVersion','outcome','operationId','gatewayReceiptSha256',
       'providerRequestIdHash','providerPayloadSha256',
       'usageCanonicalSha256','usage'
     ]
     OR p_result-ARRAY[
       'schemaVersion','outcome','operationId','gatewayReceiptSha256',
       'providerRequestIdHash','providerPayloadSha256',
       'usageCanonicalSha256','usage'
     ]<>'{}'::jsonb
     OR p_result->>'gatewayReceiptSha256' !~ '^[0-9a-f]{64}$'
     OR p_result->>'providerRequestIdHash' !~ '^[0-9a-f]{64}$'
     OR p_result->>'providerPayloadSha256' !~ '^[0-9a-f]{64}$'
     OR p_result->>'usageCanonicalSha256' !~ '^[0-9a-f]{64}$' THEN
    RETURN false;
  END IF;
  v_usage:=p_result->'usage';
  IF jsonb_typeof(v_usage)<>'object'
     OR NOT v_usage ?& ARRAY[
       'inputUnits','outputUnits','cachedInputUnits','billableUnits'
     ]
     OR v_usage-ARRAY[
       'inputUnits','outputUnits','cachedInputUnits','billableUnits'
     ]<>'{}'::jsonb
     OR jsonb_typeof(v_usage->'inputUnits')<>'number'
     OR jsonb_typeof(v_usage->'outputUnits')<>'number'
     OR jsonb_typeof(v_usage->'billableUnits')<>'number'
     OR jsonb_typeof(v_usage->'cachedInputUnits') NOT IN ('number','null') THEN
    RETURN false;
  END IF;
  v_input:=(v_usage->>'inputUnits')::numeric;
  v_output:=(v_usage->>'outputUnits')::numeric;
  v_billable:=(v_usage->>'billableUnits')::numeric;
  v_cached:=CASE WHEN jsonb_typeof(v_usage->'cachedInputUnits')='number'
    THEN (v_usage->>'cachedInputUnits')::numeric ELSE NULL END;
  RETURN v_input=trunc(v_input) AND v_input BETWEEN 0 AND 9223372036854775807
    AND v_output=trunc(v_output) AND v_output BETWEEN 0 AND 9223372036854775807
    AND v_billable=trunc(v_billable)
    AND v_billable BETWEEN 0 AND 9223372036854775807
    AND (v_cached IS NULL OR (
      v_cached=trunc(v_cached) AND v_cached BETWEEN 0 AND 9223372036854775807
    ))
    AND v_billable=v_input+v_output;
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
  RETURN false;
END $$;
ALTER FUNCTION ops.provider_control_execution_result_v1_is_valid(jsonb,text)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.provider_control_execution_result_v1_is_valid(jsonb,text)
  FROM PUBLIC;

CREATE FUNCTION ops.complete_provider_control_execution_v1(
  p_execution_id uuid,
  p_generation bigint,
  p_fencing_token bigint,
  p_result jsonb,
  p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_now timestamptz:=clock_timestamp();
  v_auth ops.execution_authorizations%ROWTYPE;
  v_detail ops.action_approval_provider_control_details%ROWTYPE;
  v_attempt ops.execution_attempts%ROWTYPE;
  v_effect ops.in_flight_effects%ROWTYPE;
  v_provider ops.provider_configs%ROWTYPE;
  v_model ops.relay_model_catalog%ROWTYPE;
  v_snapshot jsonb;
  v_snapshot_digest char(64);
  v_result_canonical bytea;
  v_result_digest char(64);
  v_usage jsonb;
  v_input_units bigint;
  v_output_units bigint;
  v_cached_input_units bigint;
  v_billable_units bigint;
  v_actual_amount numeric(18,6);
  v_connection_test_id uuid;
  v_upgrade_attempt_id uuid;
  v_upgrade_receipt_id uuid;
  v_upgrade_receipt jsonb;
  v_upgrade_receipt_canonical bytea;
  v_upgrade_receipt_digest char(64);
  v_upgrade_audit_id uuid;
  v_cost_event_id uuid;
  v_cost_event_ids uuid[]:='{}'::uuid[];
  v_requested_policy jsonb;
  v_policy_material jsonb;
  v_configured_policy jsonb;
  v_policy_sha256 char(64);
  v_new_routing jsonb;
  v_before_model text;
  v_after_provider_version bigint;
  v_provider_acknowledgement_digest char(64);
  v_provider_observation_digest char(64);
  v_provider_lookup_digest char(64);
  v_proof_kind text;
  v_sequence bigint;
  v_receipt_id uuid:=gen_random_uuid();
  v_receipt_payload jsonb;
  v_receipt_canonical bytea;
  v_receipt_digest char(64);
  v_outbox_id uuid;
  v_audit_id uuid;
  v_existing ops.execution_receipts%ROWTYPE;
BEGIN
  IF session_user<>'gurine_analysis_worker'
     OR p_execution_id IS NULL OR p_generation<1 OR p_fencing_token<1
     OR p_request_id IS NULL THEN
    RAISE EXCEPTION 'provider_control_completion_invalid' USING ERRCODE='22023';
  END IF;

  SELECT * INTO v_auth FROM ops.execution_authorizations a
   WHERE a.execution_id=p_execution_id AND a.generation=p_generation
   FOR SHARE;
  IF NOT FOUND OR v_auth.action_kind<>'PROVIDER_CONTROL'
     OR v_auth.executor_id<>'private.ExecuteProviderControl'
     OR v_auth.transport<>'PRIVATE_APPLICATION_COMMAND' THEN
    RAISE EXCEPTION 'provider_control_authorization_invalid' USING ERRCODE='23514';
  END IF;
  SELECT * INTO v_detail FROM ops.action_approval_provider_control_details d
   WHERE d.proposal_id=v_auth.proposal_id
     AND d.proposal_version=v_auth.proposal_version
     AND d.approval_digest=v_auth.approval_digest
   FOR SHARE;
  IF NOT FOUND OR v_detail.content_digest<>v_auth.target_request_sha256
     OR NOT ops.provider_control_execution_result_v1_is_valid(
       p_result,v_detail.operation_id
     ) THEN
    RAISE EXCEPTION 'provider_control_result_invalid' USING ERRCODE='22023';
  END IF;
  v_result_canonical:=ops.canonical_jsonb_v1(p_result);
  v_result_digest:=encode(extensions.digest(v_result_canonical,'sha256'),'hex');

  SELECT * INTO v_effect FROM ops.in_flight_effects e
   WHERE e.id=p_execution_id AND e.action_kind='PROVIDER_CONTROL' FOR UPDATE;
  SELECT * INTO v_attempt FROM ops.execution_attempts a
   WHERE a.execution_id=p_execution_id AND a.generation=p_generation FOR UPDATE;
  IF v_effect.id IS NULL OR v_attempt.id IS NULL
     OR v_effect.current_generation<>p_generation
     OR v_effect.last_receipt_sequence<>v_attempt.last_receipt_sequence
     OR v_effect.last_receipt_digest<>v_attempt.last_receipt_digest THEN
    RAISE EXCEPTION 'provider_control_execution_chain_invalid' USING ERRCODE='23514';
  END IF;
  IF v_effect.state='SUCCEEDED' AND v_attempt.attempt_state='SUCCEEDED' THEN
    IF v_attempt.terminal_proof_digest<>v_result_digest THEN
      RAISE EXCEPTION 'provider_control_completion_idempotency_conflict'
        USING ERRCODE='23505';
    END IF;
    SELECT * INTO STRICT v_existing FROM ops.execution_receipts r
     WHERE r.execution_id=p_execution_id AND r.generation=p_generation
       AND r.receipt_kind='EFFECT_SUCCEEDED';
    RETURN v_existing.receipt_payload||jsonb_build_object(
      'receiptDigest',v_existing.receipt_digest,
      'auditEventId',v_existing.audit_event_id,'outboxId',v_existing.outbox_id);
  END IF;
  IF v_effect.state<>'RUNNING' OR v_attempt.attempt_state<>'DISPATCHING'
     OR v_attempt.fencing_token<>p_fencing_token
     OR v_attempt.lease_token IS NULL OR v_attempt.lease_expires_at<=v_now
     OR v_auth.expires_at<=v_now THEN
    RAISE EXCEPTION 'provider_control_completion_fence_stale' USING ERRCODE='40001';
  END IF;

  SELECT * INTO v_provider FROM ops.provider_configs p
   WHERE p.id=v_detail.provider_id FOR UPDATE;
  IF NOT FOUND OR v_provider.version<>v_detail.expected_provider_version THEN
    RAISE EXCEPTION 'provider_control_provider_version_stale' USING ERRCODE='40001';
  END IF;
  v_snapshot:=jsonb_build_object(
    'providerType',v_provider.provider_type,'enabled',v_provider.enabled,
    'routingPolicy',v_provider.routing_policy,
    'dataRetentionPolicy',v_provider.data_retention_policy,
    'version',v_provider.version);
  v_snapshot_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_snapshot),'sha256'),'hex');
  IF v_snapshot_digest<>v_detail.provider_configuration_digest THEN
    RAISE EXCEPTION 'provider_control_provider_configuration_stale'
      USING ERRCODE='40001';
  END IF;
  -- A previously configured policy is reusable only when its stored digest
  -- still matches the canonical three-field policy material used by the
  -- relay request validator.  Check before writing connection/cost evidence.
  IF v_detail.operation_id='upgradeProviderModel'
     AND v_provider.routing_policy#>>'{dataPolicy,state}'='CONFIGURED' THEN
    v_configured_policy:=v_provider.routing_policy->'dataPolicy';
    v_policy_material:=jsonb_build_object(
      'processingRegion',v_configured_policy->>'processingRegion',
      'retentionMode',v_configured_policy->>'retentionMode',
      'policyVersion',v_configured_policy->>'policyVersion');
    IF encode(extensions.digest(
      ops.canonical_jsonb_v1(v_policy_material),'sha256'),'hex')<>
      v_configured_policy->>'policySha256' THEN
      RAISE EXCEPTION 'provider_control_upgrade_policy_digest_invalid'
        USING ERRCODE='23514';
    END IF;
  END IF;

  IF p_result->>'outcome'='PROVIDER_SUCCESS' THEN
    v_usage:=p_result->'usage';
    v_input_units:=(v_usage->>'inputUnits')::bigint;
    v_output_units:=(v_usage->>'outputUnits')::bigint;
    v_cached_input_units:=CASE
      WHEN jsonb_typeof(v_usage->'cachedInputUnits')='number'
      THEN (v_usage->>'cachedInputUnits')::bigint ELSE NULL END;
    v_billable_units:=(v_usage->>'billableUnits')::bigint;
    v_provider_acknowledgement_digest:=
      (p_result->>'gatewayReceiptSha256')::char(64);
    v_provider_observation_digest:=
      (p_result->>'providerPayloadSha256')::char(64);
    v_provider_lookup_digest:=(p_result->>'providerRequestIdHash')::char(64);
    v_proof_kind:='PROVIDER_SUCCESS';
    v_connection_test_id:=gen_random_uuid();
    INSERT INTO ops.provider_connection_tests(
      id,provider_id,test_model,status,redacted_result,requested_by,reason,
      started_at,completed_at)
    VALUES(
      v_connection_test_id,v_detail.provider_id,
      CASE WHEN v_detail.operation_id='testProviderConnection'
        THEN v_detail.test_model ELSE v_detail.target_model_id END,
      'SUCCEEDED',jsonb_build_object(
        'gatewayReceiptSha256',p_result->>'gatewayReceiptSha256',
        'httpStatus',200,'payloadSha256',p_result->>'providerPayloadSha256',
        'providerRequestIdHash',p_result->>'providerRequestIdHash',
        'redacted',true,'usageEvidenceSha256',p_result->>'usageCanonicalSha256',
        'usage',v_usage),v_detail.creator_actor_id,NULL,v_now,v_now);

    v_actual_amount:=((v_input_units::numeric*
      (v_provider.routing_policy#>>'{pricing,inputMicrosKrwPerUnit}')::numeric)+
      (v_output_units::numeric*
      (v_provider.routing_policy#>>'{pricing,outputMicrosKrwPerUnit}')::numeric))/1000000;
    v_cost_event_id:=gen_random_uuid();
    INSERT INTO ops.cost_events(
      id,provider_id,case_id,job_id,occurred_at,model,input_units,output_units,
      amount,currency,metadata)
    VALUES(
      v_cost_event_id,v_detail.provider_id,NULL,p_request_id,v_now,
      CASE WHEN v_detail.operation_id='testProviderConnection'
        THEN v_detail.test_model ELSE v_detail.target_model_id END,
      v_input_units,v_output_units,v_actual_amount,'KRW',jsonb_build_object(
        'executionId',p_execution_id,'generation',p_generation,
        'operationId',v_detail.operation_id,
        'pricingSha256',v_provider.routing_policy#>>'{pricing,pricingSha256}',
        'pricingVersion',v_provider.routing_policy#>>'{pricing,pricingVersion}',
        'providerRequestIdHash',p_result->>'providerRequestIdHash',
        'providerPayloadSha256',p_result->>'providerPayloadSha256',
        'cachedInputUnits',v_cached_input_units,
        'billableUnits',v_billable_units,'redacted',true,
        'usageEvidenceSha256',p_result->>'usageCanonicalSha256'));
    v_cost_event_ids:=ARRAY[v_cost_event_id];

    IF v_detail.operation_id='testProviderConnection' THEN
      UPDATE ops.provider_configs SET
        last_connection_test_at=v_now,last_connection_test_status='SUCCEEDED'
       WHERE id=v_detail.provider_id AND version=v_detail.expected_provider_version
       RETURNING version INTO v_after_provider_version;
    ELSE
      SELECT * INTO v_model FROM ops.relay_model_catalog m
       WHERE m.model_id=v_detail.target_model_id AND m.active FOR SHARE;
      IF NOT FOUND OR v_model.track IS NULL THEN
        RAISE EXCEPTION 'provider_control_upgrade_model_unavailable'
          USING ERRCODE='40001';
      END IF;
      IF v_provider.routing_policy#>>'{dataPolicy,state}'='UNCONFIGURED' THEN
        IF num_nonnulls(
          v_detail.requested_processing_region,v_detail.requested_retention_mode,
          v_detail.requested_policy_version,v_detail.requested_policy_sha256
        )<>4 THEN
          RAISE EXCEPTION 'provider_control_upgrade_policy_required'
            USING ERRCODE='23514';
        END IF;
        v_policy_material:=jsonb_build_object(
          'processingRegion',v_detail.requested_processing_region,
          'retentionMode',v_detail.requested_retention_mode,
          'policyVersion',v_detail.requested_policy_version);
        IF encode(extensions.digest(
          ops.canonical_jsonb_v1(v_policy_material),'sha256'),'hex')<>
          v_detail.requested_policy_sha256 THEN
          RAISE EXCEPTION 'provider_control_upgrade_policy_digest_invalid'
            USING ERRCODE='23514';
        END IF;
        v_requested_policy:=v_policy_material;
        v_configured_policy:=jsonb_build_object(
          'state','CONFIGURED',
          'processingRegion',v_detail.requested_processing_region,
          'retentionMode',v_detail.requested_retention_mode,
          'trainingUse','PROHIBITED',
          'policyVersion',v_detail.requested_policy_version,
          'policySha256',v_detail.requested_policy_sha256);
      ELSIF v_provider.routing_policy#>>'{dataPolicy,state}'='CONFIGURED'
        AND num_nonnulls(
          v_detail.requested_processing_region,v_detail.requested_retention_mode,
          v_detail.requested_policy_version,v_detail.requested_policy_sha256
        )=0 THEN
        v_requested_policy:=NULL;
      ELSE
        RAISE EXCEPTION 'provider_control_upgrade_policy_state_invalid'
          USING ERRCODE='23514';
      END IF;
      v_policy_sha256:=(v_configured_policy->>'policySha256')::char(64);
      v_before_model:=v_provider.routing_policy->>'model';
      v_new_routing:=v_provider.routing_policy||jsonb_build_object(
        'model',v_detail.target_model_id,'track',v_model.track,
        'dataPolicy',v_configured_policy);
      v_upgrade_attempt_id:=gen_random_uuid();
      INSERT INTO ops.provider_model_upgrade_attempts(
        id,provider_id,target_model_id,attempt_kind,requested_by,owner_user_id,
        expected_provider_version,requested_data_policy,status,connection_test_id,
        gateway_receipt_sha256,usage_evidence_sha256,started_at,completed_at)
      VALUES(
        v_upgrade_attempt_id,v_detail.provider_id,v_detail.target_model_id,
        'MANUAL',v_detail.creator_actor_id,v_detail.creator_actor_id,
        v_detail.expected_provider_version,v_requested_policy,'SUCCEEDED',
        v_connection_test_id,v_provider_acknowledgement_digest,
        (p_result->>'usageCanonicalSha256')::char(64),v_now,v_now);
      UPDATE ops.provider_configs SET
        enabled=true,routing_policy=v_new_routing,
        data_retention_policy=v_configured_policy->>'retentionMode',
        last_connection_test_at=v_now,last_connection_test_status='SUCCEEDED',
        version=version+1
       WHERE id=v_detail.provider_id AND version=v_detail.expected_provider_version
       RETURNING version INTO v_after_provider_version;
      IF v_after_provider_version IS NULL
         OR v_after_provider_version<>v_detail.expected_provider_version+1 THEN
        RAISE EXCEPTION 'provider_control_provider_version_stale'
          USING ERRCODE='40001';
      END IF;
      v_upgrade_audit_id:=ops.record_relay_model_upgrade_success_audit_v1(
        v_upgrade_attempt_id,v_policy_sha256,
        v_provider_acknowledgement_digest,
        (p_result->>'usageCanonicalSha256')::char(64));
      v_upgrade_receipt_id:=gen_random_uuid();
      v_upgrade_receipt:=jsonb_build_object(
        'schemaVersion','provider-model-upgrade-receipt.v1',
        'receiptId',v_upgrade_receipt_id,'attemptId',v_upgrade_attempt_id,
        'providerId',v_detail.provider_id,'targetModelId',v_detail.target_model_id,
        'attemptKind','MANUAL','outcome','APPLIED',
        'beforeProviderVersion',v_detail.expected_provider_version,
        'afterProviderVersion',v_after_provider_version,
        'beforeModelId',v_before_model,'afterModelId',v_detail.target_model_id,
        'policySha256',v_policy_sha256,
        'gatewayReceiptSha256',v_provider_acknowledgement_digest,
        'usageEvidenceSha256',p_result->>'usageCanonicalSha256',
        'auditEventId',v_upgrade_audit_id,'incidentEventId',NULL,
        'costEventId',v_cost_event_id,'recordedAt',v_now);
      v_upgrade_receipt_canonical:=ops.canonical_jsonb_v1(v_upgrade_receipt);
      v_upgrade_receipt_digest:=encode(extensions.digest(
        v_upgrade_receipt_canonical,'sha256'),'hex');
      INSERT INTO ops.provider_model_upgrade_receipts(
        id,attempt_id,provider_id,target_model_id,attempt_kind,outcome,
        before_provider_version,after_provider_version,before_model_id,
        after_model_id,policy_sha256,gateway_receipt_sha256,
        usage_evidence_sha256,audit_event_id,incident_event_id,cost_event_id,
        receipt_canonical,canonical_receipt,receipt_sha256,recorded_at)
      VALUES(
        v_upgrade_receipt_id,v_upgrade_attempt_id,v_detail.provider_id,
        v_detail.target_model_id,'MANUAL','APPLIED',
        v_detail.expected_provider_version,v_after_provider_version,
        v_before_model,v_detail.target_model_id,v_policy_sha256,
        v_provider_acknowledgement_digest,
        (p_result->>'usageCanonicalSha256')::char(64),v_upgrade_audit_id,NULL,
        v_cost_event_id,v_upgrade_receipt_canonical,v_upgrade_receipt,
        v_upgrade_receipt_digest,v_now);
    END IF;
  ELSE
    v_proof_kind:='NO_EGRESS';
    IF v_detail.operation_id='disableProviderRouting' THEN
      v_new_routing:=CASE WHEN v_provider.provider_type='relay'
        THEN jsonb_set(v_provider.routing_policy,'{autoUpgrade}','false'::jsonb,true)
        ELSE v_provider.routing_policy END;
      UPDATE ops.provider_configs SET
        enabled=false,routing_policy=v_new_routing,
        last_connection_test_status='DISABLED',version=version+1
       WHERE id=v_detail.provider_id AND version=v_detail.expected_provider_version
       RETURNING version INTO v_after_provider_version;
    ELSE
      v_new_routing:=jsonb_set(
        v_provider.routing_policy,'{autoUpgrade}',
        to_jsonb(v_detail.auto_upgrade_enabled),true);
      IF v_detail.auto_upgrade_track IS NOT NULL THEN
        v_new_routing:=jsonb_set(
          v_new_routing,'{track}',to_jsonb(v_detail.auto_upgrade_track),true);
      END IF;
      IF v_detail.auto_upgrade_enabled THEN
        v_new_routing:=jsonb_set(
          v_new_routing,'{autoUpgradeOwnerUserId}',
          to_jsonb(v_detail.creator_actor_id::text),true);
      END IF;
      UPDATE ops.provider_configs SET routing_policy=v_new_routing,version=version+1
       WHERE id=v_detail.provider_id AND version=v_detail.expected_provider_version
       RETURNING version INTO v_after_provider_version;
    END IF;
    IF v_after_provider_version IS NULL
       OR v_after_provider_version<>v_detail.expected_provider_version+1 THEN
      RAISE EXCEPTION 'provider_control_provider_version_stale'
        USING ERRCODE='40001';
    END IF;
  END IF;

  v_sequence:=v_effect.last_receipt_sequence+1;
  v_receipt_payload:=jsonb_build_object(
    'schemaVersion','action-execution-receipt.v1',
    'receiptKind','EFFECT_SUCCEEDED','executionId',p_execution_id,
    'generation',p_generation,'aggregateState','SUCCEEDED',
    'aggregateStateVersion',v_effect.state_version+1,
    'attemptState','SUCCEEDED','attemptStateVersion',v_attempt.state_version+1,
    'cancellationGeneration',v_effect.cancellation_generation,
    'effectCertainty',v_proof_kind,'executionDigest',v_auth.execution_digest,
    'targetRequestSha256',v_auth.target_request_sha256,
    'providerOperationId',v_detail.operation_id,
    'providerId',v_detail.provider_id,'providerVersion',v_after_provider_version,
    'resultDigest',v_result_digest,'requestId',p_request_id,'occurredAt',v_now);
  v_receipt_canonical:=ops.canonical_jsonb_v1(v_receipt_payload);
  v_receipt_digest:=encode(extensions.digest(v_receipt_canonical,'sha256'),'hex');
  v_outbox_id:=ops.enqueue_outbox(
    'action_execution',p_execution_id::text,v_effect.state_version+1,
    'action.execution_completed.v1',jsonb_build_object(
      'executionId',p_execution_id,'generation',p_generation,
      'stateVersion',v_effect.state_version+1,
      'terminalOrReconciliationState','SUCCEEDED',
      'executionDigest',v_auth.execution_digest,'receiptSequence',v_sequence,
      'receiptDigest',v_receipt_digest,'costFactIds',to_jsonb(v_cost_event_ids)),v_now);
  v_audit_id:=ops.append_audit_event(
    'worker:provider-control:'||p_execution_id::text,'SERVICE',session_user,
    NULL::uuid,'PROVIDER_CONTROL_EXECUTION_COMPLETED','ActionExecution',
    p_execution_id::text,'jobs.operate','SUCCESS',NULL,p_request_id,
    v_receipt_payload||jsonb_build_object('receiptDigest',v_receipt_digest));
  INSERT INTO ops.execution_receipts(
    id,execution_id,generation,attempt_id,receipt_sequence,receipt_kind,
    mutates_aggregate_state,prior_aggregate_state,aggregate_state,
    aggregate_state_version,prior_attempt_state,attempt_state,fencing_token,
    cancellation_generation,provider_acknowledgement_digest,
    provider_observation_digest,proof_kind,proof_digest,receipt_payload,
    receipt_payload_canonical,actual_amount,actual_currency,cost_event_ids,
    budget_reservation_digest,request_id,audit_event_id,outbox_id,observed_at,
    prior_receipt_digest,receipt_digest)
  VALUES(
    v_receipt_id,p_execution_id,p_generation,v_attempt.id,v_sequence,
    'EFFECT_SUCCEEDED',true,v_effect.state,'SUCCEEDED',v_effect.state_version+1,
    v_attempt.attempt_state,'SUCCEEDED',p_fencing_token,
    v_effect.cancellation_generation,v_provider_acknowledgement_digest,
    v_provider_observation_digest,v_proof_kind,v_result_digest,
    v_receipt_payload,v_receipt_canonical,
    CASE WHEN v_cost_event_id IS NULL THEN NULL ELSE v_actual_amount END,
    CASE WHEN v_cost_event_id IS NULL THEN NULL ELSE 'KRW'::char(3) END,
    v_cost_event_ids,v_auth.budget_reservation_digest,p_request_id,v_audit_id,
    v_outbox_id,v_now,v_effect.last_receipt_digest,v_receipt_digest);
  UPDATE ops.execution_attempts SET
    attempt_state='SUCCEEDED',state_version=state_version+1,
    lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL,
    provider_acknowledgement_digest=v_provider_acknowledgement_digest,
    provider_lookup_receipt_digest=v_provider_lookup_digest,
    terminal_proof_digest=v_result_digest,
    provider_accepted_at=CASE WHEN v_proof_kind='PROVIDER_SUCCESS'
      THEN v_now ELSE provider_accepted_at END,
    completed_at=v_now,last_receipt_sequence=v_sequence,
    last_receipt_digest=v_receipt_digest,updated_at=v_now
   WHERE id=v_attempt.id;
  UPDATE ops.in_flight_effects SET
    state='SUCCEEDED',state_version=state_version+1,
    last_receipt_sequence=v_sequence,last_receipt_digest=v_receipt_digest,
    terminal_at=v_now,updated_at=v_now
   WHERE id=p_execution_id;
  RETURN v_receipt_payload||jsonb_build_object(
    'receiptDigest',v_receipt_digest,'auditEventId',v_audit_id,
    'outboxId',v_outbox_id);
END $$;
ALTER FUNCTION ops.complete_provider_control_execution_v1(
  uuid,bigint,bigint,jsonb,uuid
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.complete_provider_control_execution_v1(
  uuid,bigint,bigint,jsonb,uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.complete_provider_control_execution_v1(
  uuid,bigint,bigint,jsonb,uuid
) TO gurine_analysis_worker;

CREATE FUNCTION ops.fail_provider_control_execution_v1(
  p_execution_id uuid,
  p_generation bigint,
  p_fencing_token bigint,
  p_error_code text,
  p_error_detail_digest char(64),
  p_retryable boolean,
  p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_now timestamptz:=clock_timestamp();
  v_auth ops.execution_authorizations%ROWTYPE;
  v_detail ops.action_approval_provider_control_details%ROWTYPE;
  v_attempt ops.execution_attempts%ROWTYPE;
  v_effect ops.in_flight_effects%ROWTYPE;
  v_provider_effect boolean;
  v_new_state text;
  v_receipt_kind text;
  v_proof_kind text;
  v_failure_proof jsonb;
  v_failure_proof_digest char(64);
  v_sequence bigint;
  v_receipt_id uuid:=gen_random_uuid();
  v_receipt_payload jsonb;
  v_receipt_canonical bytea;
  v_receipt_digest char(64);
  v_outbox_id uuid;
  v_audit_id uuid;
  v_existing ops.execution_receipts%ROWTYPE;
BEGIN
  IF session_user<>'gurine_analysis_worker'
     OR p_execution_id IS NULL OR p_generation<1 OR p_fencing_token<1
     OR p_request_id IS NULL OR p_retryable IS NULL
     OR p_error_code !~ '^[A-Z][A-Z0-9_]{0,127}$'
     OR p_error_detail_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'provider_control_failure_invalid' USING ERRCODE='22023';
  END IF;
  v_failure_proof:=jsonb_build_object(
    'schemaVersion','provider-control-execution-failure.v1',
    'errorCode',p_error_code,'errorDetailDigest',p_error_detail_digest,
    'retryable',p_retryable);
  v_failure_proof_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_failure_proof),'sha256'),'hex');

  SELECT * INTO v_auth FROM ops.execution_authorizations a
   WHERE a.execution_id=p_execution_id AND a.generation=p_generation FOR SHARE;
  SELECT * INTO v_detail FROM ops.action_approval_provider_control_details d
   WHERE d.proposal_id=v_auth.proposal_id
     AND d.proposal_version=v_auth.proposal_version
     AND d.approval_digest=v_auth.approval_digest FOR SHARE;
  SELECT * INTO v_effect FROM ops.in_flight_effects e
   WHERE e.id=p_execution_id AND e.action_kind='PROVIDER_CONTROL' FOR UPDATE;
  SELECT * INTO v_attempt FROM ops.execution_attempts a
   WHERE a.execution_id=p_execution_id AND a.generation=p_generation FOR UPDATE;
  IF v_auth.id IS NULL OR v_auth.action_kind<>'PROVIDER_CONTROL'
     OR v_auth.executor_id<>'private.ExecuteProviderControl'
     OR v_auth.transport<>'PRIVATE_APPLICATION_COMMAND'
     OR v_detail.proposal_id IS NULL
     OR v_detail.content_digest<>v_auth.target_request_sha256
     OR v_detail.required_creator_capability<>v_auth.required_capability
     OR v_effect.id IS NULL OR v_attempt.id IS NULL
     OR v_effect.current_generation<>p_generation
     OR v_effect.last_receipt_sequence<>v_attempt.last_receipt_sequence
     OR v_effect.last_receipt_digest<>v_attempt.last_receipt_digest THEN
    RAISE EXCEPTION 'provider_control_execution_chain_invalid' USING ERRCODE='23514';
  END IF;
  IF v_effect.state IN (
       'RETRYABLE_FAILED','PERMANENT_FAILED','RECONCILIATION_REQUIRED'
     ) AND v_attempt.attempt_state=v_effect.state THEN
    IF v_attempt.last_error_code<>p_error_code
       OR v_attempt.last_error_detail_digest<>p_error_detail_digest
       OR v_attempt.terminal_proof_digest<>v_failure_proof_digest THEN
      RAISE EXCEPTION 'provider_control_failure_idempotency_conflict'
        USING ERRCODE='23505';
    END IF;
    SELECT * INTO STRICT v_existing FROM ops.execution_receipts r
     WHERE r.execution_id=p_execution_id AND r.generation=p_generation
       AND r.receipt_sequence=v_effect.last_receipt_sequence;
    RETURN v_existing.receipt_payload||jsonb_build_object(
      'receiptDigest',v_existing.receipt_digest,
      'auditEventId',v_existing.audit_event_id,'outboxId',v_existing.outbox_id);
  END IF;
  IF v_effect.state<>'RUNNING' OR v_attempt.attempt_state<>'DISPATCHING'
     OR v_attempt.fencing_token<>p_fencing_token OR v_attempt.lease_token IS NULL
     OR v_attempt.lease_expires_at<=v_now THEN
    RAISE EXCEPTION 'provider_control_failure_fence_stale' USING ERRCODE='40001';
  END IF;

  v_provider_effect:=v_detail.operation_id IN (
    'testProviderConnection','upgradeProviderModel'
  );
  IF v_provider_effect THEN
    v_new_state:='RECONCILIATION_REQUIRED';
    v_receipt_kind:='RECONCILIATION_REQUIRED';
    v_proof_kind:='BOUNDED_AMBIGUITY';
  ELSIF p_retryable THEN
    v_new_state:='RETRYABLE_FAILED';
    v_receipt_kind:='EFFECT_RETRYABLE_FAILED';
    v_proof_kind:='NO_EGRESS';
  ELSE
    v_new_state:='PERMANENT_FAILED';
    v_receipt_kind:='EFFECT_PERMANENT_FAILED';
    v_proof_kind:='NO_EGRESS';
  END IF;
  v_sequence:=v_effect.last_receipt_sequence+1;
  v_receipt_payload:=jsonb_build_object(
    'schemaVersion','action-execution-receipt.v1',
    'receiptKind',v_receipt_kind,'executionId',p_execution_id,
    'generation',p_generation,'aggregateState',v_new_state,
    'aggregateStateVersion',v_effect.state_version+1,
    'attemptState',v_new_state,'attemptStateVersion',v_attempt.state_version+1,
    'cancellationGeneration',v_effect.cancellation_generation,
    'effectCertainty',v_proof_kind,'executionDigest',v_auth.execution_digest,
    'targetRequestSha256',v_auth.target_request_sha256,
    'providerOperationId',v_detail.operation_id,
    'errorCode',p_error_code,'errorDetailDigest',p_error_detail_digest,
    'failureProofDigest',v_failure_proof_digest,
    'requestId',p_request_id,'occurredAt',v_now);
  v_receipt_canonical:=ops.canonical_jsonb_v1(v_receipt_payload);
  v_receipt_digest:=encode(extensions.digest(v_receipt_canonical,'sha256'),'hex');
  v_outbox_id:=ops.enqueue_outbox(
    'action_execution',p_execution_id::text,v_effect.state_version+1,
    'action.execution_completed.v1',jsonb_build_object(
      'executionId',p_execution_id,'generation',p_generation,
      'stateVersion',v_effect.state_version+1,
      'terminalOrReconciliationState',v_new_state,
      'executionDigest',v_auth.execution_digest,'receiptSequence',v_sequence,
      'receiptDigest',v_receipt_digest,'costFactIds','[]'::jsonb),v_now);
  v_audit_id:=ops.append_audit_event(
    'worker:provider-control:'||p_execution_id::text,'SERVICE',session_user,
    NULL::uuid,'PROVIDER_CONTROL_EXECUTION_FAILED','ActionExecution',
    p_execution_id::text,'jobs.operate','FAILED',p_error_code,p_request_id,
    v_receipt_payload||jsonb_build_object('receiptDigest',v_receipt_digest));
  INSERT INTO ops.execution_receipts(
    id,execution_id,generation,attempt_id,receipt_sequence,receipt_kind,
    mutates_aggregate_state,prior_aggregate_state,aggregate_state,
    aggregate_state_version,prior_attempt_state,attempt_state,fencing_token,
    cancellation_generation,proof_kind,proof_digest,receipt_payload,
    receipt_payload_canonical,budget_reservation_digest,request_id,audit_event_id,
    outbox_id,observed_at,prior_receipt_digest,receipt_digest)
  VALUES(
    v_receipt_id,p_execution_id,p_generation,v_attempt.id,v_sequence,
    v_receipt_kind,true,v_effect.state,v_new_state,v_effect.state_version+1,
    v_attempt.attempt_state,v_new_state,p_fencing_token,
    v_effect.cancellation_generation,v_proof_kind,v_failure_proof_digest,
    v_receipt_payload,v_receipt_canonical,v_auth.budget_reservation_digest,
    p_request_id,v_audit_id,v_outbox_id,v_now,v_effect.last_receipt_digest,
    v_receipt_digest);
  UPDATE ops.execution_attempts SET
    attempt_state=v_new_state,state_version=state_version+1,
    lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL,
    terminal_proof_digest=v_failure_proof_digest,
    last_error_code=p_error_code,last_error_detail_digest=p_error_detail_digest,
    next_reconcile_at=CASE WHEN v_new_state='RECONCILIATION_REQUIRED'
      THEN v_now+interval '5 minutes' ELSE NULL END,
    completed_at=CASE WHEN v_new_state='PERMANENT_FAILED' THEN v_now ELSE NULL END,
    last_receipt_sequence=v_sequence,last_receipt_digest=v_receipt_digest,
    updated_at=v_now
   WHERE id=v_attempt.id;
  UPDATE ops.in_flight_effects SET
    state=v_new_state,state_version=state_version+1,
    next_reconcile_at=CASE WHEN v_new_state='RECONCILIATION_REQUIRED'
      THEN v_now+interval '5 minutes' ELSE NULL END,
    terminal_at=CASE WHEN v_new_state='PERMANENT_FAILED' THEN v_now ELSE NULL END,
    last_receipt_sequence=v_sequence,last_receipt_digest=v_receipt_digest,
    updated_at=v_now
   WHERE id=p_execution_id;
  RETURN v_receipt_payload||jsonb_build_object(
    'receiptDigest',v_receipt_digest,'auditEventId',v_audit_id,
    'outboxId',v_outbox_id);
END $$;
ALTER FUNCTION ops.fail_provider_control_execution_v1(
  uuid,bigint,bigint,text,char(64),boolean,uuid
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.fail_provider_control_execution_v1(
  uuid,bigint,bigint,text,char(64),boolean,uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.fail_provider_control_execution_v1(
  uuid,bigint,bigint,text,char(64),boolean,uuid
) TO gurine_analysis_worker;
