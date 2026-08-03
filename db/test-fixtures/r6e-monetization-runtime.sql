\set ON_ERROR_STOP on

-- R6E_OWNER_ABI_STATE: PENDING

BEGIN;
SET LOCAL statement_timeout='30s';
SET LOCAL lock_timeout='5s';

DO $r6e_disposable_database_guard$
BEGIN
  IF current_database()<>'gurine_r6e_monetization' THEN
    RAISE EXCEPTION 'R6E_TEST_FIXTURE_REQUIRES_DISPOSABLE_DATABASE';
  END IF;
END
$r6e_disposable_database_guard$;

CREATE FUNCTION pg_temp.r6e_assert(
  p_condition boolean,
  p_message text
) RETURNS void
LANGUAGE plpgsql
SET search_path=pg_catalog,pg_temp
AS $$
BEGIN
  IF p_condition IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'R6E_ASSERTION_FAILED:%',p_message;
  END IF;
END
$$;

CREATE FUNCTION pg_temp.r6e_test_fixture_digest(
  p_field text
) RETURNS char(64)
LANGUAGE sql
IMMUTABLE
STRICT
SET search_path=pg_catalog,extensions,pg_temp
AS $$
  SELECT encode(extensions.digest(convert_to(
    'r6e-test-fixture-only:'||p_field,'UTF8'
  ),'sha256'),'hex')::char(64)
$$;

CREATE FUNCTION pg_temp.r6e_relation_fingerprint(
  p_relation regclass
) RETURNS text
LANGUAGE plpgsql
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_fingerprint text;
BEGIN
  EXECUTE format(
    $query$
      SELECT count(*)::text||':'||encode(extensions.digest(
        ops.canonical_jsonb_v1(jsonb_build_object(
          'count',count(*),
          'rows',COALESCE(
            jsonb_agg(to_jsonb(row_value)
              ORDER BY (to_jsonb(row_value)::text) COLLATE "C"),
            '[]'::jsonb
          )
        )),'sha256'
      ),'hex')
      FROM %s AS row_value
    $query$,
    p_relation
  ) INTO v_fingerprint;
  RETURN v_fingerprint;
END
$$;

DO $r6e_catalog_and_acl_boundary$
DECLARE
  v_relation regclass;
  v_role text;
  v_writer_action text;
  v_direct_privileges constant text[] := ARRAY[
    'INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'
  ];
  v_economics_relations constant regclass[] := ARRAY[
    'ops.fx_rate_facts'::regclass,
    'ops.product_events'::regclass,
    'ops.outcome_facts'::regclass,
    'ops.acquisition_source_receipts'::regclass,
    'ops.cost_allocations'::regclass,
    'ops.tariff_versions'::regclass,
    'ops.commercial_contract_periods'::regclass,
    'ops.usage_window_receipts'::regclass,
    'ops.usage_facts'::regclass,
    'ops.discount_decisions'::regclass,
    'ops.invoice_facts'::regclass,
    'ops.invoice_line_facts'::regclass,
    'ops.invoice_usage_memberships'::regclass,
    'ops.revenue_facts'::regclass,
    'ops.funding_concentration_snapshots'::regclass,
    'editorial.funding_disclosure_revisions'::regclass,
    'editorial.funding_disclosure_entries'::regclass,
    'ops.sku_readiness_evaluations'::regclass,
    'ops.sku_readiness_items'::regclass,
    'ops.accounting_corrections'::regclass,
    'ops.commercial_qualification_receipts'::regclass,
    'ops.offer_profile_capabilities'::regclass,
    'ops.paid_evidence_packets'::regclass,
    'ops.paid_evidence_packet_members'::regclass
  ];
  v_action_detail_relation constant regclass :=
    'ops.action_approval_economics_import_details'::regclass;
  v_private_r6e_relations constant regclass[] := ARRAY[
    'ops.cash_application_facts'::regclass,
    'ops.tax_invoice_issuance_receipts'::regclass,
    'ops.payment_method_bindings'::regclass,
    'ops.payment_charge_attempts'::regclass,
    'ops.provider_webhook_receipts'::regclass,
    'ops.donation_facts'::regclass
  ];
  v_runtime_roles constant text[] := ARRAY[
    'gurine_control_api','gurine_workflow_worker','gurine_analysis_worker',
    'gurine_public_projector','gurine_public_api','gurine_submission_api',
    'gurine_ingest_worker','gurine_notification_worker','gurine_scheduler',
    'gurine_document_extractor','gurine_identity_api',
    'gurine_auditor','gurine_billing_gateway','gurine_economics_importer'
  ];
BEGIN
  PERFORM pg_temp.r6e_assert(
    cardinality(v_economics_relations)=24,
    'exact twenty-four-relation economics inventory'
  );
  PERFORM pg_temp.r6e_assert(
    cardinality(v_private_r6e_relations)=6,
    'exact six-relation private R6e ledger inventory'
  );
  PERFORM pg_temp.r6e_assert(
    cardinality(v_runtime_roles)=14
      AND (SELECT count(DISTINCT role_name)=14
           FROM unnest(v_runtime_roles) AS roles(role_name))
      AND (SELECT count(*)=14 FROM pg_roles
           WHERE rolname=ANY(v_runtime_roles)),
    'exact fourteen-role runtime inventory'
  );

  PERFORM pg_temp.r6e_assert(
    NOT EXISTS (
      SELECT 1
      FROM pg_roles
      WHERE rolname IN ('gurine_billing_gateway','gurine_economics_importer')
        AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolbypassrls
          OR rolinherit)
    ),
    'runtime writer roles must be least-privilege NOINHERIT roles'
  );

  FOREACH v_relation IN ARRAY v_economics_relations
      ||ARRAY[v_action_detail_relation]::regclass[]
      ||v_private_r6e_relations LOOP
    FOREACH v_role IN ARRAY v_runtime_roles LOOP
      FOREACH v_writer_action IN ARRAY v_direct_privileges LOOP
        PERFORM pg_temp.r6e_assert(
          NOT has_table_privilege(v_role,v_relation,v_writer_action),
          format('%s has direct %s on %s',v_role,v_writer_action,v_relation)
        );
      END LOOP;
    END LOOP;
  END LOOP;

  FOREACH v_relation IN ARRAY v_private_r6e_relations LOOP
    FOREACH v_role IN ARRAY v_runtime_roles LOOP
      PERFORM pg_temp.r6e_assert(
        has_table_privilege(v_role,v_relation,'SELECT')
          IS NOT DISTINCT FROM (v_role='gurine_auditor'),
        format('%s private R6e SELECT boundary mismatch on %s',
          v_role,v_relation)
      );
    END LOOP;
  END LOOP;

  FOREACH v_relation IN ARRAY v_economics_relations LOOP
    PERFORM pg_temp.r6e_assert(
      has_table_privilege('gurine_auditor',v_relation,'SELECT'),
      format('auditor lacks economics SELECT on %s',v_relation)
    );
  END LOOP;

  FOREACH v_role IN ARRAY v_runtime_roles LOOP
    PERFORM pg_temp.r6e_assert(
      NOT has_table_privilege(v_role,v_action_detail_relation,'SELECT'),
      format('%s has forbidden economics action-detail SELECT',v_role)
    );
  END LOOP;

  PERFORM pg_temp.r6e_assert(
    NOT has_function_privilege(
      'gurine_workflow_worker',
      'ops.record_commercial_qualification_receipt_v1(ops.commercial_qualification_receipt_input_v1,text)',
      'EXECUTE'
    ) AND NOT has_function_privilege(
      'gurine_workflow_worker',
      'ops.record_invoice_fact_v1(jsonb)',
      'EXECUTE'
    ) AND NOT has_function_privilege(
      'gurine_workflow_worker',
      'ops.record_revenue_fact_v1(jsonb,uuid,character)',
      'EXECUTE'
    ),
    'legacy economics side-door writers must remain revoked'
  );

  FOREACH v_role IN ARRAY v_runtime_roles LOOP
    PERFORM pg_temp.r6e_assert(
      NOT has_function_privilege(
        v_role,
        'ops.materialize_paid_evidence_packet_subject_v1(ops.paid_evidence_packet_subject_input_v1,text)',
        'EXECUTE'
      ) AND NOT has_function_privilege(
        v_role,
        'ops.bind_paid_terminal_receipt_v1(ops.paid_terminal_binding_input_v1,text)',
        'EXECUTE'
      ) AND NOT has_type_privilege(
        v_role,'ops.paid_evidence_packet_subject_input_v1'::regtype,'USAGE'
      ) AND NOT has_type_privilege(
        v_role,'ops.paid_evidence_packet_member_input_v1'::regtype,'USAGE'
      ) AND NOT has_type_privilege(
        v_role,'ops.paid_terminal_binding_input_v1'::regtype,'USAGE'
      ),
      format('%s has forbidden paid-packet draft authority',v_role)
    );
  END LOOP;
END
$r6e_catalog_and_acl_boundary$;

DO $r6e_event_catalog_contract$
DECLARE
  v_donation jsonb := jsonb_build_object(
    'donationFactId','41000000-0000-4000-8000-000000000001',
    'donationFactDigest',pg_temp.r6e_test_fixture_digest(
      'event-donation-fact:v1'
    ),
    'chargeAttemptId','41000000-0000-4000-8000-000000000002',
    'chargeAttemptDigest',pg_temp.r6e_test_fixture_digest(
      'event-charge-attempt:v1'
    ),
    'providerFetchDigest',pg_temp.r6e_test_fixture_digest(
      'event-provider-fetch:v1'
    ),
    'occurredAt','2026-08-02T00:00:00Z'
  );
  v_review jsonb := jsonb_build_object(
    'reviewTaskId','41000000-0000-4000-8000-000000000003',
    'reviewTaskVersion',1,
    'reviewTaskDigest',pg_temp.r6e_test_fixture_digest(
      'event-review-task:v1'
    ),
    'sourceKind','DONATION_PAYMENT_FAILURE',
    'sourceReceiptId','41000000-0000-4000-8000-000000000004',
    'sourceReceiptDigest',pg_temp.r6e_test_fixture_digest(
      'event-review-source:v1'
    ),
    'occurredAt','2026-08-02T00:00:00Z'
  );
  v_denied boolean := false;
BEGIN
  PERFORM ops.event_payload_admissible_v1(
    'donation.fact_recorded.v1',v_donation
  );
  PERFORM ops.event_payload_admissible_v1(
    'notification.payment_review_requested.v1',v_review
  );
  BEGIN
    PERFORM ops.event_payload_admissible_v1(
      'donation.fact_recorded.v1',v_donation||jsonb_build_object(
        'amount','10000'
      )
    );
  EXCEPTION WHEN SQLSTATE '22023' THEN
    v_denied := true;
  END;
  PERFORM pg_temp.r6e_assert(
    v_denied,
    'donation event must reject private or extra payload fields'
  );
END
$r6e_event_catalog_contract$;

DO $r6e_funding_projection_digest_latch$
DECLARE
  v_relations constant regclass[] := ARRAY[
    'public.transparency_reports'::regclass,
    'ops.inbox'::regclass,
    'ops.jobs'::regclass,
    'ops.job_attempts'::regclass,
    'ops.audit_events'::regclass,
    'ops.outbox'::regclass,
    'editorial.funding_disclosure_revisions'::regclass,
    'editorial.funding_disclosure_entries'::regclass,
    'ops.funding_concentration_snapshots'::regclass
  ];
  v_before text[]:='{}'::text[];
  v_after text[]:='{}'::text[];
  v_relation regclass;
  v_message text;
  v_latched boolean:=false;
BEGIN
  FOREACH v_relation IN ARRAY v_relations LOOP
    v_before:=array_append(
      v_before,pg_temp.r6e_relation_fingerprint(v_relation)
    );
  END LOOP;
  BEGIN
    PERFORM *
    FROM editorial.read_public_funding_projection_inputs_v1(
      '46000000-0000-4000-8000-000000000003'::uuid,
      pg_temp.r6e_test_fixture_digest('projection-reader-input:v1')
    );
  EXCEPTION WHEN SQLSTATE '55000' THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    v_latched:=v_message='FUNDING_PROJECTION_DIGEST_ABI_UNAVAILABLE';
  END;
  PERFORM pg_temp.r6e_assert(
    v_latched,
    'funding projection reader must fail on the exact digest ABI latch'
  );
  FOREACH v_relation IN ARRAY v_relations LOOP
    v_after:=array_append(
      v_after,pg_temp.r6e_relation_fingerprint(v_relation)
    );
  END LOOP;
  PERFORM pg_temp.r6e_assert(
    v_after IS NOT DISTINCT FROM v_before,
    'funding projection reader digest latch must have exact zero delta'
  );
END
$r6e_funding_projection_digest_latch$;

-- R6E_FIXTURE_ECONOMICS_IMPORT

DO $r6e_paid_packet_authority_latches$
DECLARE
  v_relations constant regclass[] := ARRAY[
    'ops.paid_evidence_packets'::regclass,
    'ops.paid_evidence_packet_members'::regclass,
    'ops.outcome_facts'::regclass,
    'ops.audit_events'::regclass,
    'ops.outbox'::regclass,
    'ops.idempotency_keys'::regclass
  ];
  v_before text[]:='{}'::text[];
  v_after text[]:='{}'::text[];
  v_relation regclass;
  v_materialize_latched boolean:=false;
  v_terminal_latched boolean:=false;
  v_message text;
BEGIN
  FOREACH v_relation IN ARRAY v_relations LOOP
    v_before:=array_append(
      v_before,pg_temp.r6e_relation_fingerprint(v_relation)
    );
  END LOOP;
  BEGIN
    PERFORM ops.materialize_paid_evidence_packet_subject_v1(
      NULL::ops.paid_evidence_packet_subject_input_v1,NULL::text
    );
  EXCEPTION WHEN SQLSTATE '55000' THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    v_materialize_latched:=
      v_message='PAID_PACKET_DIGEST_AUTHORITY_UNAVAILABLE';
  END;
  BEGIN
    PERFORM ops.bind_paid_terminal_receipt_v1(
      NULL::ops.paid_terminal_binding_input_v1,NULL::text
    );
  EXCEPTION WHEN SQLSTATE '55000' THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    v_terminal_latched:=v_message='PAID_PACKET_TERMINAL_NOT_READY';
  END;
  PERFORM pg_temp.r6e_assert(
    v_materialize_latched AND v_terminal_latched,
    'paid packet and terminal paths must remain on their exact authority latches'
  );
  FOREACH v_relation IN ARRAY v_relations LOOP
    v_after:=array_append(
      v_after,pg_temp.r6e_relation_fingerprint(v_relation)
    );
  END LOOP;
  PERFORM pg_temp.r6e_assert(
    v_after IS NOT DISTINCT FROM v_before,
    'paid authority latches must have exact zero committed-state delta'
  );
END
$r6e_paid_packet_authority_latches$;

-- R6E_FIXTURE_PAYMENT_AND_DUNNING

DO $r6e_payment_review_authority_root$
DECLARE
  v_user constant uuid :=
    '6e000000-0000-4000-8000-000000000101'::uuid;
  v_subject constant uuid :=
    '6e000000-0000-4000-8000-000000000102'::uuid;
  v_endpoint constant uuid :=
    '6e000000-0000-4000-8000-000000000103'::uuid;
  v_link constant uuid :=
    '6e000000-0000-4000-8000-000000000104'::uuid;
  v_auth constant uuid :=
    '6e000000-0000-4000-8000-000000000105'::uuid;
  v_source constant uuid :=
    '6e000000-0000-4000-8000-000000000106'::uuid;
  v_proof_receipt constant uuid :=
    '6e000000-0000-4000-8000-000000000107'::uuid;
  v_link_audit constant uuid :=
    '6e000000-0000-4000-8000-000000000108'::uuid;
  v_auth_audit constant uuid :=
    '6e000000-0000-4000-8000-000000000109'::uuid;
  v_now constant timestamptz := '2026-08-02T00:00:00Z'::timestamptz;
  v_expires_at constant timestamptz :=
    '2099-08-02T00:00:00Z'::timestamptz;
  v_topic constant jsonb := jsonb_build_object(
    'schemaVersion','r6e-payment-review-authority.v1',
    'scope','PAYMENT_REVIEW',
    'authority','TEST_FIXTURE_ONLY'
  );
  v_origin char(64) := encode(extensions.digest(convert_to(
    'r6e-test-fixture-only:subject-origin-binding:v1','UTF8'
  ),'sha256'),'hex');
  v_subject_hmac char(64) := encode(extensions.digest(convert_to(
    'r6e-test-fixture-only:subject-pseudonym-hmac:v1','UTF8'
  ),'sha256'),'hex');
  v_profile char(64) := encode(extensions.digest(convert_to(
    'r6e-test-fixture-only:subject-profile:v1','UTF8'
  ),'sha256'),'hex');
  v_endpoint_hmac char(64) := encode(extensions.digest(convert_to(
    'r6e-test-fixture-only:endpoint-hmac:v1','UTF8'
  ),'sha256'),'hex');
  v_endpoint_digest char(64) := encode(extensions.digest(convert_to(
    'r6e-test-fixture-only:endpoint-digest:v1','UTF8'
  ),'sha256'),'hex');
  v_link_proof char(64) := encode(extensions.digest(convert_to(
    'r6e-test-fixture-only:link-proof:v1','UTF8'
  ),'sha256'),'hex');
  v_link_event char(64) := encode(extensions.digest(convert_to(
    'r6e-test-fixture-only:link-event:v1','UTF8'
  ),'sha256'),'hex');
  v_link_receipt char(64) := encode(extensions.digest(convert_to(
    'r6e-test-fixture-only:link-receipt:v1','UTF8'
  ),'sha256'),'hex');
  v_policy char(64) := encode(extensions.digest(convert_to(
    'r6e-test-fixture-only:authorization-policy:v1','UTF8'
  ),'sha256'),'hex');
  v_source_decision char(64) := encode(extensions.digest(convert_to(
    'r6e-test-fixture-only:authorization-source-decision:v1','UTF8'
  ),'sha256'),'hex');
  v_proof char(64) := encode(extensions.digest(convert_to(
    'r6e-test-fixture-only:authorization-proof:v1','UTF8'
  ),'sha256'),'hex');
  v_auth_event char(64) := encode(extensions.digest(convert_to(
    'r6e-test-fixture-only:authorization-event:v1','UTF8'
  ),'sha256'),'hex');
  v_auth_receipt char(64) := encode(extensions.digest(convert_to(
    'r6e-test-fixture-only:authorization-receipt:v1','UTF8'
  ),'sha256'),'hex');
BEGIN
  PERFORM pg_temp.r6e_assert(
    session_user='postgres' AND current_user='postgres',
    'TEST_FIXTURE_ONLY authority root requires the disposable admin session'
  );
  PERFORM pg_temp.r6e_assert(
    NOT EXISTS (SELECT 1 FROM ops.users WHERE id=v_user)
      AND NOT EXISTS (
        SELECT 1 FROM intake.communication_subjects WHERE id=v_subject
      )
      AND NOT EXISTS (
        SELECT 1 FROM intake.communication_endpoints WHERE id=v_endpoint
      )
      AND NOT EXISTS (
        SELECT 1 FROM intake.communication_endpoint_link_events
        WHERE id=v_link
      )
      AND NOT EXISTS (
        SELECT 1 FROM intake.communication_authorization_events
        WHERE id=v_auth
      ),
    'TEST_FIXTURE_ONLY authority root must be inserted exactly once'
  );

  INSERT INTO ops.users(id,oidc_subject,email,display_name,status)
  VALUES (
    v_user,'r6e-test-fixture-payment-review',
    'r6e-payment-review@gurine.invalid',
    'R6e TEST FIXTURE payment reviewer','ACTIVE'
  );
  INSERT INTO intake.communication_subjects(
    id,subject_kind,origin_object_type,origin_object_id,
    origin_object_version,origin_binding_digest,subject_pseudonym_hmac,
    hmac_key_version,jurisdiction,locale,status,profile_version,
    profile_digest,created_at,updated_at
  ) VALUES (
    v_subject,'INTERNAL_USER','INTERNAL_USER',v_user,1,v_origin,
    v_subject_hmac,'TEST_FIXTURE_ONLY_V1','KR','ko-KR','ACTIVE',1,
    v_profile,v_now,v_now
  );
  INSERT INTO intake.communication_endpoints(
    id,subject_id,channel,endpoint_hmac,hmac_key_version,
    endpoint_ciphertext,encryption_key_id,state,version,endpoint_digest,
    endpoint_aad_digest,verified_at,created_at,updated_at
  ) VALUES (
    v_endpoint,v_subject,'SMTP_EMAIL',v_endpoint_hmac,
    'TEST_FIXTURE_ONLY_V1',extensions.digest(convert_to(
      'r6e-test-fixture-only:endpoint-ciphertext:v1','UTF8'
    ),'sha256'),'TEST_FIXTURE_ONLY_KEY_V1','ACTIVE',1,v_endpoint_digest,
    ops.r6d_nul5_sha256_v1(
      'intake.communication_endpoints','endpoint_ciphertext',
      v_endpoint::text,'email-address','1'
    ),v_now,v_now,v_now
  );
  INSERT INTO intake.communication_endpoint_link_events(
    id,subject_id,subject_origin_binding_digest,endpoint_id,
    endpoint_sequence,profile_version,endpoint_version,endpoint_hmac,
    endpoint_digest,channel,state,change_kind,proof_digest,reason_code,
    endpoint_snapshot_digest,event_digest,audit_event_id,receipt_digest,
    occurred_at
  ) VALUES (
    v_link,v_subject,v_origin,v_endpoint,1,1,1,v_endpoint_hmac,
    v_endpoint_digest,'SMTP_EMAIL','ACTIVE','VERIFIED',v_link_proof,
    'R6E_TEST_FIXTURE_ONLY_PAYMENT_REVIEW_AUTHORITY',v_endpoint_digest,
    v_link_event,v_link_audit,v_link_receipt,v_now
  );
  INSERT INTO intake.communication_authorization_events(
    id,subject_id,subject_origin_binding_digest,endpoint_id,
    endpoint_version,endpoint_snapshot_digest,authorization_sequence,
    authorization_kind,change_kind,channel,purpose,topic_scope,
    topic_scope_digest,basis,basis_reference,policy_version,policy_digest,
    jurisdiction,locale,source_kind,source_id,source_version,
    source_decision_digest,proof_receipt_id,proof_digest,actor_type,actor_id,
    effective_at,expires_at,event_digest,audit_event_id,receipt_digest,
    created_at
  ) VALUES (
    v_auth,v_subject,v_origin,v_endpoint,1,v_endpoint_digest,1,
    'LAWFUL_PURPOSE_AUTHORIZATION','GRANTED','SMTP_EMAIL',
    'INTERNAL_ACTION_REQUEST',v_topic,
    ops.communication_topic_scope_digest(v_topic),
    'LEGITIMATE_INTEREST_REVIEWED',
    'TEST_FIXTURE_ONLY payment review authority',
    'r6e-test-fixture-only-v1',v_policy,'KR','ko-KR',
    'AUTHORIZED_POLICY_JOB',v_source,1,v_source_decision,v_proof_receipt,
    v_proof,'AUTHORIZED_SERVICE',NULL,v_now,v_expires_at,v_auth_event,
    v_auth_audit,v_auth_receipt,v_now
  );

  PERFORM pg_temp.r6e_assert(
    (SELECT count(*)=1
     FROM intake.communication_subjects AS subject
     JOIN ops.users AS reviewer
       ON reviewer.id=subject.origin_object_id
      AND reviewer.status='ACTIVE'
     JOIN intake.communication_endpoints AS endpoint
       ON endpoint.subject_id=subject.id
      AND endpoint.state='ACTIVE'
     JOIN intake.communication_endpoint_link_events AS link
       ON link.subject_id=subject.id
      AND link.endpoint_id=endpoint.id
      AND link.endpoint_version=endpoint.version
      AND link.endpoint_snapshot_digest=endpoint.endpoint_digest
      AND link.channel=endpoint.channel
     JOIN intake.communication_authorization_events AS auth_event
       ON auth_event.subject_id=subject.id
      AND auth_event.endpoint_id=endpoint.id
      AND auth_event.endpoint_version=endpoint.version
      AND auth_event.endpoint_snapshot_digest=endpoint.endpoint_digest
     WHERE subject.id=v_subject
       AND subject.subject_kind='INTERNAL_USER'
       AND subject.origin_object_type='INTERNAL_USER'
       AND subject.status='ACTIVE'
       AND auth_event.id=v_auth
       AND auth_event.purpose='INTERNAL_ACTION_REQUEST'
       AND auth_event.change_kind IN ('GRANTED','RESTORED')
       AND auth_event.effective_at<=clock_timestamp()
       AND (auth_event.expires_at IS NULL
         OR auth_event.expires_at>clock_timestamp())
       AND NOT EXISTS (
         SELECT 1
         FROM intake.communication_authorization_events AS later
         WHERE later.subject_id=auth_event.subject_id
           AND later.endpoint_id=auth_event.endpoint_id
           AND later.purpose=auth_event.purpose
           AND later.topic_scope_digest=auth_event.topic_scope_digest
           AND later.authorization_sequence>
             auth_event.authorization_sequence
       )),
    'exact one current TEST_FIXTURE_ONLY payment-review authority root'
  );
END
$r6e_payment_review_authority_root$;

-- R6E_FIXTURE_DONATION_AND_PUBLIC_PROJECTION

ROLLBACK;
