BEGIN;
-- Source-derived 0027 physical registry: 22 relations.
-- Existing 0001..0024 migrations are byte-immutable; this migration is additive.
SET LOCAL search_path = pg_catalog, public;
CREATE OR REPLACE FUNCTION ops.is_lower_sha256(text) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 ~ '^[0-9a-f]{64}$' $$;
ALTER FUNCTION ops.is_lower_sha256(text) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.is_lower_sha256(text) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.idempotency_safe_header_bytes_is_valid(bytea,text) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL $$;
ALTER FUNCTION ops.idempotency_safe_header_bytes_is_valid(bytea,text) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.idempotency_safe_header_bytes_is_valid(bytea,text) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.idempotency_stored_response_is_valid(text,text,bytea,char(64),jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $5 IS NOT NULL AND jsonb_typeof($5) = 'object' $$;
ALTER FUNCTION ops.idempotency_stored_response_is_valid(text,text,bytea,char(64),jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.idempotency_stored_response_is_valid(text,text,bytea,char(64),jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.communication_topic_scope_digest(jsonb) RETURNS char(64) LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT encode(extensions.digest(convert_to($1::text,'UTF8'),'sha256'),'hex')::char(64) $$;
ALTER FUNCTION ops.communication_topic_scope_digest(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.communication_topic_scope_digest(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.uuid_array_is_unique(uuid[]) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND cardinality($1) = (SELECT count(DISTINCT value) FROM unnest($1) AS item(value)) AND NOT EXISTS (SELECT 1 FROM unnest($1) AS item(value) WHERE value IS NULL) $$;
ALTER FUNCTION ops.uuid_array_is_unique(uuid[]) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.uuid_array_is_unique(uuid[]) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.smallint_array_is_unique(smallint[]) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND cardinality($1) = (SELECT count(DISTINCT value) FROM unnest($1) AS item(value)) AND NOT EXISTS (SELECT 1 FROM unnest($1) AS item(value) WHERE value IS NULL) $$;
ALTER FUNCTION ops.smallint_array_is_unique(smallint[]) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.smallint_array_is_unique(smallint[]) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.date_array_is_sorted_unique(date[]) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND cardinality($1) = (SELECT count(DISTINCT value) FROM unnest($1) AS item(value)) AND NOT EXISTS (SELECT 1 FROM unnest($1) AS item(value) WHERE value IS NULL) $$;
ALTER FUNCTION ops.date_array_is_sorted_unique(date[]) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.date_array_is_sorted_unique(date[]) FROM PUBLIC;
CREATE OR REPLACE FUNCTION intake.communication_channel_array_is_unique(text[]) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL $$;
ALTER FUNCTION intake.communication_channel_array_is_unique(text[]) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION intake.communication_channel_array_is_unique(text[]) FROM PUBLIC;
CREATE OR REPLACE FUNCTION intake.communication_channel_array_is_closed(text[]) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL $$;
ALTER FUNCTION intake.communication_channel_array_is_closed(text[]) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION intake.communication_channel_array_is_closed(text[]) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.communication_callback_auth_evidence_is_valid(jsonb,text,char(64)) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.communication_callback_auth_evidence_is_valid(jsonb,text,char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.communication_callback_auth_evidence_is_valid(jsonb,text,char(64)) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.communication_callback_items_are_valid(jsonb,integer,char(64)) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.communication_callback_items_are_valid(jsonb,integer,char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.communication_callback_items_are_valid(jsonb,integer,char(64)) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.communication_safe_retry_proof_is_valid(jsonb,text,char(64)) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.communication_safe_retry_proof_is_valid(jsonb,text,char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.communication_safe_retry_proof_is_valid(jsonb,text,char(64)) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.communication_provider_revision_snapshot_is_valid(jsonb,char(64)) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.communication_provider_revision_snapshot_is_valid(jsonb,char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.communication_provider_revision_snapshot_is_valid(jsonb,char(64)) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.secret_reference_is_version_pinned(text) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL $$;
ALTER FUNCTION ops.secret_reference_is_version_pinned(text) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.secret_reference_is_version_pinned(text) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.delivery_proof_rank(text) RETURNS smallint LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT CASE $1 WHEN 'NONE' THEN 0 WHEN 'PROVIDER_ACCEPTED' THEN 10 WHEN 'DELIVERED' THEN 20 WHEN 'READ' THEN 30 ELSE -1 END::smallint $$;
ALTER FUNCTION ops.delivery_proof_rank(text) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.delivery_proof_rank(text) FROM PUBLIC;
CREATE TABLE intake.communication_subjects (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  subject_kind text NOT NULL,
  subscription_id uuid,
  origin_object_type text NOT NULL,
  origin_object_id uuid NOT NULL,
  origin_object_version bigint NOT NULL,
  origin_binding_digest char(64) NOT NULL,
  subject_pseudonym_hmac char(64) NOT NULL,
  hmac_key_version text NOT NULL,
  jurisdiction text NOT NULL,
  locale text NOT NULL DEFAULT 'ko-KR',
  status text NOT NULL DEFAULT 'ACTIVE',
  profile_version bigint NOT NULL DEFAULT 1,
  profile_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  revoked_at timestamptz,
  CONSTRAINT g_pk_intake_communication_subjects_1 PRIMARY KEY (id)
);
ALTER TABLE intake.communication_subjects OWNER TO gurine_migrator;
ALTER TABLE intake.communication_subjects ADD CONSTRAINT communication_subject_identity_binding_uq UNIQUE (id, origin_binding_digest);
ALTER TABLE intake.communication_subjects ADD CONSTRAINT communication_subject_origin_uq UNIQUE (subject_kind, origin_object_type, origin_object_id);
ALTER TABLE intake.communication_subjects ADD CONSTRAINT communication_subject_pseudonym_scope_uq UNIQUE (subject_pseudonym_hmac, hmac_key_version, origin_binding_digest);
CREATE UNIQUE INDEX communication_subject_subscription_uq ON intake.communication_subjects (subscription_id) WHERE subscription_id IS NOT NULL;
ALTER TABLE intake.communication_subjects ADD CONSTRAINT g_ck_intake_communication_subjects_1 CHECK (subject_kind IN ('ACCOUNTLESS_SUBSCRIBER','RESPONSE_PARTY','CORRECTION_REQUESTER','PRIVACY_REQUESTER','INTERNAL_USER','ORGANIZATION_CONTACT'));
ALTER TABLE intake.communication_subjects ADD CONSTRAINT g_ck_intake_communication_subjects_2 CHECK (subject_kind = 'ACCOUNTLESS_SUBSCRIBER' AND subscription_id IS NOT NULL AND origin_object_type = 'SUBSCRIPTION' AND origin_object_id = subscription_id OR subject_kind <> 'ACCOUNTLESS_SUBSCRIBER' AND subscription_id IS NULL);
ALTER TABLE intake.communication_subjects ADD CONSTRAINT g_ck_intake_communication_subjects_3 CHECK (origin_object_type IN ('SUBSCRIPTION','RESPONSE_REQUEST','CORRECTION_REQUEST','PRIVACY_REQUEST','INTERNAL_USER','ORGANIZATION_CONTACT'));
ALTER TABLE intake.communication_subjects ADD CONSTRAINT g_ck_intake_communication_subjects_4 CHECK (origin_object_version > 0);
ALTER TABLE intake.communication_subjects ADD CONSTRAINT g_ck_intake_communication_subjects_5 CHECK (status IN ('ACTIVE','REVOKED'));
ALTER TABLE intake.communication_subjects ADD CONSTRAINT g_ck_intake_communication_subjects_6 CHECK (profile_version > 0);
ALTER TABLE intake.communication_subjects ADD CONSTRAINT g_ck_intake_communication_subjects_7 CHECK (length(jurisdiction) BETWEEN 2 AND 64);
ALTER TABLE intake.communication_subjects ADD CONSTRAINT g_ck_intake_communication_subjects_8 CHECK (length(locale) BETWEEN 2 AND 35);
ALTER TABLE intake.communication_subjects ADD CONSTRAINT g_ck_intake_communication_subjects_9 CHECK (length(hmac_key_version) BETWEEN 1 AND 100);
ALTER TABLE intake.communication_subjects ADD CONSTRAINT g_ck_intake_communication_subjects_10 CHECK ((status = 'ACTIVE' AND revoked_at IS NULL) OR (status = 'REVOKED' AND revoked_at IS NOT NULL));
ALTER TABLE intake.communication_subjects ADD CONSTRAINT g_ck_intake_communication_subjects_11 CHECK (ops.is_lower_sha256(origin_binding_digest) AND ops.is_lower_sha256(subject_pseudonym_hmac) AND ops.is_lower_sha256(profile_digest));
REVOKE ALL ON intake.communication_subjects FROM PUBLIC;
REVOKE ALL ON intake.communication_subjects FROM gurine_workflow_worker;
REVOKE ALL ON intake.communication_subjects FROM gurine_control_api;
REVOKE ALL ON intake.communication_subjects FROM gurine_analysis_worker;
REVOKE ALL ON intake.communication_subjects FROM gurine_public_projector;
REVOKE ALL ON intake.communication_subjects FROM gurine_notification_worker;
REVOKE ALL ON intake.communication_subjects FROM gurine_submission_api;
REVOKE ALL ON intake.communication_subjects FROM gurine_auditor;
GRANT SELECT ON intake.communication_subjects TO gurine_control_api;
GRANT SELECT ON intake.communication_subjects TO gurine_notification_worker;
GRANT SELECT ON intake.communication_subjects TO gurine_workflow_worker;
ALTER TABLE intake.communication_subjects ENABLE ROW LEVEL SECURITY;
CREATE POLICY communication_subject_profile_scope ON intake.communication_subjects TO gurine_submission_api USING (id::text = current_setting('gurine.communication_subject_id', true)) WITH CHECK (id::text = current_setting('gurine.communication_subject_id', true));
CREATE POLICY communication_subject_control_read ON intake.communication_subjects TO gurine_control_api USING (id::text = current_setting('gurine.communication_subject_id', true));
CREATE POLICY communication_subject_gateway_read ON intake.communication_subjects TO gurine_notification_worker USING (id::text = current_setting('gurine.communication_subject_id', true));
CREATE TRIGGER intake_communication_subjects_immutable_mutation_guard BEFORE UPDATE OR DELETE ON intake.communication_subjects FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE intake.communication_endpoints (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  subject_id uuid NOT NULL,
  channel text NOT NULL,
  endpoint_hmac char(64) NOT NULL,
  hmac_key_version text NOT NULL,
  endpoint_ciphertext bytea NOT NULL,
  encryption_key_id text NOT NULL,
  destination_hint_ciphertext bytea,
  state text NOT NULL DEFAULT 'PENDING_VERIFICATION',
  version bigint NOT NULL DEFAULT 1,
  endpoint_digest char(64) NOT NULL,
  verified_at timestamptz,
  bounced_at timestamptz,
  suppressed_at timestamptz,
  revoked_at timestamptz,
  last_provider_evidence_digest char(64),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_intake_communication_endpoints_1 PRIMARY KEY (id)
);
ALTER TABLE intake.communication_endpoints OWNER TO gurine_migrator;
ALTER TABLE intake.communication_endpoints ADD CONSTRAINT communication_endpoint_subject_identity_uq UNIQUE (id, subject_id);
ALTER TABLE intake.communication_endpoints ADD CONSTRAINT communication_endpoint_subject_channel_uq UNIQUE (subject_id, channel, endpoint_hmac, hmac_key_version);
ALTER TABLE intake.communication_endpoints ADD CONSTRAINT communication_endpoint_version_digest_uq UNIQUE (id, version, endpoint_digest);
ALTER TABLE intake.communication_endpoints ADD CONSTRAINT communication_endpoint_version_hmac_uq UNIQUE (id, version, endpoint_hmac);
ALTER TABLE intake.communication_endpoints ADD CONSTRAINT communication_endpoint_subject_revision_uq UNIQUE (id, subject_id, version, endpoint_hmac, endpoint_digest);
ALTER TABLE intake.communication_endpoints ADD CONSTRAINT g_ck_intake_communication_endpoints_1 CHECK (channel IN ('SMTP_EMAIL','TELEGRAM_BOT_API','META_WHATSAPP_BUSINESS_CLOUD','LINE_MESSAGING_API','SOLAPI_SMS','SOLAPI_KAKAO_BIZMESSAGE','TWILIO_VOICE','SIGNED_WEBHOOK'));
ALTER TABLE intake.communication_endpoints ADD CONSTRAINT g_ck_intake_communication_endpoints_2 CHECK (state IN ('PENDING_VERIFICATION','ACTIVE','BOUNCED','SUPPRESSED','REVOKED'));
ALTER TABLE intake.communication_endpoints ADD CONSTRAINT g_ck_intake_communication_endpoints_3 CHECK (version > 0);
ALTER TABLE intake.communication_endpoints ADD CONSTRAINT g_ck_intake_communication_endpoints_4 CHECK (octet_length(endpoint_ciphertext) BETWEEN 1 AND 16384);
ALTER TABLE intake.communication_endpoints ADD CONSTRAINT g_ck_intake_communication_endpoints_5 CHECK (length(hmac_key_version) BETWEEN 1 AND 100);
ALTER TABLE intake.communication_endpoints ADD CONSTRAINT g_ck_intake_communication_endpoints_6 CHECK (length(encryption_key_id) BETWEEN 1 AND 200);
ALTER TABLE intake.communication_endpoints ADD CONSTRAINT g_ck_intake_communication_endpoints_7 CHECK (state = 'PENDING_VERIFICATION' AND verified_at IS NULL AND revoked_at IS NULL OR state = 'ACTIVE' AND verified_at IS NOT NULL AND revoked_at IS NULL OR state = 'BOUNCED' AND verified_at IS NOT NULL AND bounced_at IS NOT NULL AND revoked_at IS NULL OR state = 'SUPPRESSED' AND verified_at IS NOT NULL AND suppressed_at IS NOT NULL AND revoked_at IS NULL OR state = 'REVOKED' AND revoked_at IS NOT NULL);
ALTER TABLE intake.communication_endpoints ADD CONSTRAINT g_ck_intake_communication_endpoints_8 CHECK (ops.is_lower_sha256(endpoint_hmac) AND ops.is_lower_sha256(endpoint_digest) AND (last_provider_evidence_digest IS NULL OR ops.is_lower_sha256(last_provider_evidence_digest)));
REVOKE ALL ON intake.communication_endpoints FROM PUBLIC;
REVOKE ALL ON intake.communication_endpoints FROM gurine_workflow_worker;
REVOKE ALL ON intake.communication_endpoints FROM gurine_control_api;
REVOKE ALL ON intake.communication_endpoints FROM gurine_analysis_worker;
REVOKE ALL ON intake.communication_endpoints FROM gurine_public_projector;
REVOKE ALL ON intake.communication_endpoints FROM gurine_notification_worker;
REVOKE ALL ON intake.communication_endpoints FROM gurine_submission_api;
REVOKE ALL ON intake.communication_endpoints FROM gurine_auditor;
GRANT SELECT(id, subject_id, channel, endpoint_hmac, hmac_key_version, state, version, endpoint_digest, verified_at, bounced_at, suppressed_at, revoked_at, last_provider_evidence_digest, created_at, updated_at) ON intake.communication_endpoints TO gurine_control_api;
GRANT SELECT ON intake.communication_endpoints TO gurine_notification_worker;
GRANT SELECT(id, subject_id, channel, state, version, endpoint_digest, verified_at, revoked_at) ON intake.communication_endpoints TO gurine_workflow_worker;
ALTER TABLE intake.communication_endpoints ENABLE ROW LEVEL SECURITY;
CREATE POLICY communication_endpoint_profile_scope ON intake.communication_endpoints TO gurine_submission_api USING (subject_id::text = current_setting('gurine.communication_subject_id', true)) WITH CHECK (subject_id::text = current_setting('gurine.communication_subject_id', true));
CREATE POLICY communication_endpoint_control_read ON intake.communication_endpoints TO gurine_control_api USING (subject_id::text = current_setting('gurine.communication_subject_id', true));
CREATE POLICY communication_endpoint_gateway_read ON intake.communication_endpoints TO gurine_notification_worker USING (subject_id::text = current_setting('gurine.communication_subject_id', true));
CREATE TRIGGER intake_communication_endpoints_immutable_mutation_guard BEFORE UPDATE OR DELETE ON intake.communication_endpoints FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE intake.communication_endpoint_verifications (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  subject_id uuid NOT NULL,
  subject_origin_binding_digest char(64) NOT NULL,
  endpoint_id uuid NOT NULL,
  endpoint_version bigint NOT NULL,
  endpoint_snapshot_digest char(64) NOT NULL,
  profile_session_id uuid NOT NULL,
  challenge_kind text NOT NULL,
  challenge_hash char(64) NOT NULL,
  nonce_hash char(64) NOT NULL,
  verification_binding_digest char(64) NOT NULL,
  pending_authorization_binding jsonb,
  pending_authorization_digest char(64),
  state text NOT NULL DEFAULT 'PENDING',
  attempt_count integer NOT NULL DEFAULT 0,
  max_attempts integer NOT NULL,
  version bigint NOT NULL DEFAULT 1,
  proof_digest char(64),
  receipt_digest char(64),
  issued_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  expires_at timestamptz NOT NULL,
  verified_at timestamptz,
  consumed_at timestamptz,
  failed_at timestamptz,
  CONSTRAINT g_pk_intake_communication_endpoint_verifications_1 PRIMARY KEY (id)
);
ALTER TABLE intake.communication_endpoint_verifications OWNER TO gurine_migrator;
ALTER TABLE intake.communication_endpoint_verifications ADD CONSTRAINT communication_endpoint_challenge_hash_uq UNIQUE (challenge_hash);
ALTER TABLE intake.communication_endpoint_verifications ADD CONSTRAINT communication_endpoint_challenge_nonce_uq UNIQUE (nonce_hash);
ALTER TABLE intake.communication_endpoint_verifications ADD CONSTRAINT g_ck_intake_communication_endpoint_verifications_1 CHECK (endpoint_version > 0 AND version > 0);
ALTER TABLE intake.communication_endpoint_verifications ADD CONSTRAINT g_ck_intake_communication_endpoint_verifications_2 CHECK (challenge_kind IN ('EMAIL_LINK','SMS_OTP','TELEGRAM_SIGNED_BINDING','WHATSAPP_SIGNED_BINDING','LINE_SIGNED_BINDING','KAKAO_SIGNED_BINDING','VOICE_PHONE_OTP','SIGNED_WEBHOOK_CHALLENGE'));
ALTER TABLE intake.communication_endpoint_verifications ADD CONSTRAINT g_ck_intake_communication_endpoint_verifications_3 CHECK (state IN ('PENDING','VERIFIED','FAILED','EXPIRED','CANCELLED'));
ALTER TABLE intake.communication_endpoint_verifications ADD CONSTRAINT g_ck_intake_communication_endpoint_verifications_4 CHECK (max_attempts BETWEEN 1 AND 10 AND attempt_count BETWEEN 0 AND max_attempts);
ALTER TABLE intake.communication_endpoint_verifications ADD CONSTRAINT g_ck_intake_communication_endpoint_verifications_5 CHECK (expires_at > issued_at);
ALTER TABLE intake.communication_endpoint_verifications ADD CONSTRAINT g_ck_intake_communication_endpoint_verifications_6 CHECK ((pending_authorization_binding IS NULL) = (pending_authorization_digest IS NULL));
ALTER TABLE intake.communication_endpoint_verifications ADD CONSTRAINT g_ck_intake_communication_endpoint_verifications_7 CHECK (pending_authorization_binding IS NULL OR pending_authorization_binding->>'authorizationKind' IN ('SUBSCRIPTION_CONSENT','ENDPOINT_LINKING_CONSENT'));
ALTER TABLE intake.communication_endpoint_verifications ADD CONSTRAINT g_ck_intake_communication_endpoint_verifications_8 CHECK (state = 'PENDING' AND verified_at IS NULL AND consumed_at IS NULL AND failed_at IS NULL OR state = 'VERIFIED' AND verified_at IS NOT NULL AND consumed_at IS NOT NULL AND proof_digest IS NOT NULL AND receipt_digest IS NOT NULL OR state IN ('FAILED','EXPIRED','CANCELLED') AND verified_at IS NULL AND failed_at IS NOT NULL);
ALTER TABLE intake.communication_endpoint_verifications ADD CONSTRAINT g_ck_intake_communication_endpoint_verifications_9 CHECK (ops.is_lower_sha256(subject_origin_binding_digest) AND ops.is_lower_sha256(endpoint_snapshot_digest) AND ops.is_lower_sha256(challenge_hash) AND ops.is_lower_sha256(nonce_hash) AND ops.is_lower_sha256(verification_binding_digest) AND (pending_authorization_digest IS NULL OR ops.is_lower_sha256(pending_authorization_digest)) AND (proof_digest IS NULL OR ops.is_lower_sha256(proof_digest)) AND (receipt_digest IS NULL OR ops.is_lower_sha256(receipt_digest)));
REVOKE ALL ON intake.communication_endpoint_verifications FROM PUBLIC;
REVOKE ALL ON intake.communication_endpoint_verifications FROM gurine_workflow_worker;
REVOKE ALL ON intake.communication_endpoint_verifications FROM gurine_control_api;
REVOKE ALL ON intake.communication_endpoint_verifications FROM gurine_analysis_worker;
REVOKE ALL ON intake.communication_endpoint_verifications FROM gurine_public_projector;
REVOKE ALL ON intake.communication_endpoint_verifications FROM gurine_notification_worker;
REVOKE ALL ON intake.communication_endpoint_verifications FROM gurine_submission_api;
REVOKE ALL ON intake.communication_endpoint_verifications FROM gurine_auditor;
GRANT SELECT(id, subject_id, endpoint_id, endpoint_version, challenge_kind, verification_binding_digest, state, attempt_count, max_attempts, version, proof_digest, receipt_digest, issued_at, expires_at, verified_at, consumed_at, failed_at) ON intake.communication_endpoint_verifications TO gurine_control_api;
GRANT SELECT(id, subject_id, endpoint_id, endpoint_version, challenge_kind, challenge_hash, nonce_hash, verification_binding_digest, state, attempt_count, max_attempts, version, issued_at, expires_at) ON intake.communication_endpoint_verifications TO gurine_notification_worker;
ALTER TABLE intake.communication_endpoint_verifications ENABLE ROW LEVEL SECURITY;
CREATE POLICY communication_verification_profile_scope ON intake.communication_endpoint_verifications TO gurine_submission_api USING (subject_id::text = current_setting('gurine.communication_subject_id', true)) WITH CHECK (subject_id::text = current_setting('gurine.communication_subject_id', true));
CREATE POLICY communication_verification_control_read ON intake.communication_endpoint_verifications TO gurine_control_api USING (subject_id::text = current_setting('gurine.communication_subject_id', true));
CREATE POLICY communication_verification_gateway_read ON intake.communication_endpoint_verifications TO gurine_notification_worker USING (subject_id::text = current_setting('gurine.communication_subject_id', true));
CREATE TRIGGER intake_communication_endpoint_verifications_immutable_mutation_guard BEFORE UPDATE OR DELETE ON intake.communication_endpoint_verifications FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE intake.communication_endpoint_link_events (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  subject_id uuid NOT NULL,
  subject_origin_binding_digest char(64) NOT NULL,
  endpoint_id uuid NOT NULL,
  endpoint_sequence bigint NOT NULL,
  profile_version bigint NOT NULL,
  prior_endpoint_version bigint,
  endpoint_version bigint NOT NULL,
  endpoint_hmac char(64) NOT NULL,
  endpoint_digest char(64) NOT NULL,
  channel text NOT NULL,
  prior_state text,
  state text NOT NULL,
  change_kind text NOT NULL,
  profile_session_id uuid,
  verification_id uuid,
  consent_digest char(64),
  proof_digest char(64) NOT NULL,
  reason_code text NOT NULL,
  endpoint_snapshot_digest char(64) NOT NULL,
  event_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL,
  receipt_digest char(64) NOT NULL,
  occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_intake_communication_endpoint_link_events_1 PRIMARY KEY (id)
);
ALTER TABLE intake.communication_endpoint_link_events OWNER TO gurine_migrator;
ALTER TABLE intake.communication_endpoint_link_events ADD CONSTRAINT communication_endpoint_link_sequence_uq UNIQUE (endpoint_id, endpoint_sequence);
ALTER TABLE intake.communication_endpoint_link_events ADD CONSTRAINT communication_profile_link_version_uq UNIQUE (subject_id, profile_version);
ALTER TABLE intake.communication_endpoint_link_events ADD CONSTRAINT communication_endpoint_revision_snapshot_uq UNIQUE (endpoint_id, endpoint_version, endpoint_snapshot_digest);
ALTER TABLE intake.communication_endpoint_link_events ADD CONSTRAINT communication_endpoint_subject_revision_snapshot_uq UNIQUE (subject_id, endpoint_id, endpoint_version, endpoint_snapshot_digest);
ALTER TABLE intake.communication_endpoint_link_events ADD CONSTRAINT communication_endpoint_subject_revision_channel_uq UNIQUE (subject_id, endpoint_id, endpoint_version, endpoint_snapshot_digest, channel);
ALTER TABLE intake.communication_endpoint_link_events ADD CONSTRAINT communication_endpoint_revision_channel_uq UNIQUE (endpoint_id, endpoint_version, endpoint_snapshot_digest, channel);
ALTER TABLE intake.communication_endpoint_link_events ADD CONSTRAINT communication_endpoint_link_event_digest_uq UNIQUE (event_digest);
ALTER TABLE intake.communication_endpoint_link_events ADD CONSTRAINT communication_endpoint_link_receipt_digest_uq UNIQUE (receipt_digest);
ALTER TABLE intake.communication_endpoint_link_events ADD CONSTRAINT g_ck_intake_communication_endpoint_link_events_1 CHECK (endpoint_sequence > 0 AND profile_version > 0 AND endpoint_version > 0);
ALTER TABLE intake.communication_endpoint_link_events ADD CONSTRAINT g_ck_intake_communication_endpoint_link_events_2 CHECK (prior_endpoint_version IS NULL OR prior_endpoint_version > 0);
ALTER TABLE intake.communication_endpoint_link_events ADD CONSTRAINT g_ck_intake_communication_endpoint_link_events_3 CHECK (prior_state IS NULL OR prior_state IN ('PENDING_VERIFICATION','ACTIVE','BOUNCED','SUPPRESSED','REVOKED'));
ALTER TABLE intake.communication_endpoint_link_events ADD CONSTRAINT g_ck_intake_communication_endpoint_link_events_4 CHECK (state IN ('PENDING_VERIFICATION','ACTIVE','BOUNCED','SUPPRESSED','REVOKED'));
ALTER TABLE intake.communication_endpoint_link_events ADD CONSTRAINT g_ck_intake_communication_endpoint_link_events_5 CHECK (channel IN ('SMTP_EMAIL','TELEGRAM_BOT_API','META_WHATSAPP_BUSINESS_CLOUD','LINE_MESSAGING_API','SOLAPI_SMS','SOLAPI_KAKAO_BIZMESSAGE','TWILIO_VOICE','SIGNED_WEBHOOK'));
ALTER TABLE intake.communication_endpoint_link_events ADD CONSTRAINT g_ck_intake_communication_endpoint_link_events_6 CHECK (change_kind IN ('LINK_REQUESTED','VERIFIED','UNLINKED','BOUNCED','SUPPRESSED','REENROLLMENT_REQUESTED','SUPPRESSION_RELEASED','CHALLENGE_EXPIRED','CHALLENGE_CANCELLED'));
ALTER TABLE intake.communication_endpoint_link_events ADD CONSTRAINT g_ck_intake_communication_endpoint_link_events_7 CHECK (endpoint_sequence = 1 AND prior_endpoint_version IS NULL AND prior_state IS NULL OR endpoint_sequence > 1 AND prior_endpoint_version IS NOT NULL AND prior_state IS NOT NULL);
ALTER TABLE intake.communication_endpoint_link_events ADD CONSTRAINT g_ck_intake_communication_endpoint_link_events_8 CHECK (ops.is_lower_sha256(subject_origin_binding_digest) AND ops.is_lower_sha256(endpoint_hmac) AND ops.is_lower_sha256(endpoint_digest) AND (consent_digest IS NULL OR ops.is_lower_sha256(consent_digest)) AND ops.is_lower_sha256(proof_digest) AND ops.is_lower_sha256(endpoint_snapshot_digest) AND ops.is_lower_sha256(event_digest) AND ops.is_lower_sha256(receipt_digest));
REVOKE ALL ON intake.communication_endpoint_link_events FROM PUBLIC;
REVOKE ALL ON intake.communication_endpoint_link_events FROM gurine_workflow_worker;
REVOKE ALL ON intake.communication_endpoint_link_events FROM gurine_control_api;
REVOKE ALL ON intake.communication_endpoint_link_events FROM gurine_analysis_worker;
REVOKE ALL ON intake.communication_endpoint_link_events FROM gurine_public_projector;
REVOKE ALL ON intake.communication_endpoint_link_events FROM gurine_notification_worker;
REVOKE ALL ON intake.communication_endpoint_link_events FROM gurine_submission_api;
REVOKE ALL ON intake.communication_endpoint_link_events FROM gurine_auditor;
GRANT SELECT ON intake.communication_endpoint_link_events TO gurine_control_api;
GRANT SELECT ON intake.communication_endpoint_link_events TO gurine_notification_worker;
ALTER TABLE intake.communication_endpoint_link_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY communication_link_event_profile_scope ON intake.communication_endpoint_link_events TO gurine_submission_api USING (subject_id::text = current_setting('gurine.communication_subject_id', true));
CREATE POLICY communication_link_event_control_read ON intake.communication_endpoint_link_events TO gurine_control_api USING (subject_id::text = current_setting('gurine.communication_subject_id', true));
CREATE POLICY communication_link_event_gateway_read ON intake.communication_endpoint_link_events TO gurine_notification_worker USING (subject_id::text = current_setting('gurine.communication_subject_id', true));
CREATE TRIGGER intake_communication_endpoint_link_events_immutable_mutation_guard BEFORE UPDATE OR DELETE ON intake.communication_endpoint_link_events FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE intake.communication_authorization_events (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  subject_id uuid NOT NULL,
  subject_origin_binding_digest char(64) NOT NULL,
  endpoint_id uuid NOT NULL,
  endpoint_version bigint NOT NULL,
  endpoint_snapshot_digest char(64) NOT NULL,
  authorization_sequence bigint NOT NULL,
  authorization_kind text NOT NULL,
  change_kind text NOT NULL,
  channel text NOT NULL,
  purpose text NOT NULL,
  topic_scope jsonb NOT NULL,
  topic_scope_digest char(64) NOT NULL,
  basis text NOT NULL,
  basis_reference text NOT NULL,
  policy_version text NOT NULL,
  policy_digest char(64) NOT NULL,
  jurisdiction text NOT NULL,
  locale text NOT NULL,
  source_kind text NOT NULL,
  source_id uuid NOT NULL,
  source_version bigint NOT NULL,
  source_decision_digest char(64) NOT NULL,
  proof_receipt_id uuid NOT NULL,
  proof_digest char(64) NOT NULL,
  actor_type text NOT NULL,
  actor_id uuid,
  effective_at timestamptz NOT NULL,
  expires_at timestamptz,
  event_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL,
  receipt_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_intake_communication_authorization_events_1 PRIMARY KEY (id)
);
ALTER TABLE intake.communication_authorization_events OWNER TO gurine_migrator;
ALTER TABLE intake.communication_authorization_events ADD CONSTRAINT communication_authorization_sequence_uq UNIQUE (subject_id, endpoint_id, purpose, topic_scope_digest, authorization_sequence);
ALTER TABLE intake.communication_authorization_events ADD CONSTRAINT communication_authorization_event_digest_uq UNIQUE (event_digest);
ALTER TABLE intake.communication_authorization_events ADD CONSTRAINT communication_authorization_receipt_digest_uq UNIQUE (receipt_digest);
ALTER TABLE intake.communication_authorization_events ADD CONSTRAINT communication_authorization_source_decision_uq UNIQUE (source_kind, source_id, source_version, source_decision_digest);
ALTER TABLE intake.communication_authorization_events ADD CONSTRAINT g_ck_intake_communication_authorization_events_1 CHECK (endpoint_version > 0 AND authorization_sequence > 0 AND source_version > 0);
ALTER TABLE intake.communication_authorization_events ADD CONSTRAINT g_ck_intake_communication_authorization_events_2 CHECK (authorization_kind IN ('ENDPOINT_LINKING_CONSENT','LAWFUL_PURPOSE_AUTHORIZATION','SUBSCRIPTION_CONSENT','MARKETING_CONSENT','FALLBACK_CONSENT','VOICE_CONSENT'));
ALTER TABLE intake.communication_authorization_events ADD CONSTRAINT g_ck_intake_communication_authorization_events_3 CHECK (change_kind IN ('GRANTED','VERIFIED','REVOKED','EXPIRED','SUSPENDED','RESTORED'));
ALTER TABLE intake.communication_authorization_events ADD CONSTRAINT g_ck_intake_communication_authorization_events_4 CHECK (channel IN ('SMTP_EMAIL','TELEGRAM_BOT_API','META_WHATSAPP_BUSINESS_CLOUD','LINE_MESSAGING_API','SOLAPI_SMS','SOLAPI_KAKAO_BIZMESSAGE','TWILIO_VOICE','SIGNED_WEBHOOK'));
ALTER TABLE intake.communication_authorization_events ADD CONSTRAINT g_ck_intake_communication_authorization_events_5 CHECK (purpose IN ('ENDPOINT_VERIFICATION','RIGHT_OF_REPLY_REQUEST','RIGHT_OF_REPLY_REMINDER','RESPONSE_RECEIPT','CORRECTION_STATUS','CORRECTION_RETRACTION_NOTICE','PRIVACY_TRANSACTIONAL_NOTICE','SECURITY_TRANSACTIONAL_NOTICE','SUBSCRIPTION_UPDATE','PRODUCT_MARKETING','INCIDENT_RECOVERY','INTERNAL_ACTION_REQUEST','DISCRETIONARY_OUTREACH'));
ALTER TABLE intake.communication_authorization_events ADD CONSTRAINT g_ck_intake_communication_authorization_events_6 CHECK (basis IN ('CONSENT','CONTRACTUAL_TRANSACTIONAL','LEGAL_OBLIGATION_REVIEWED','LEGITIMATE_INTEREST_REVIEWED','PUBLIC_TASK_REVIEWED','VITAL_INTEREST_REVIEWED'));
ALTER TABLE intake.communication_authorization_events ADD CONSTRAINT g_ck_intake_communication_authorization_events_7 CHECK (length(basis_reference) BETWEEN 1 AND 1000);
ALTER TABLE intake.communication_authorization_events ADD CONSTRAINT g_ck_intake_communication_authorization_events_8 CHECK (length(policy_version) BETWEEN 1 AND 100);
ALTER TABLE intake.communication_authorization_events ADD CONSTRAINT g_ck_intake_communication_authorization_events_9 CHECK (length(jurisdiction) BETWEEN 2 AND 64 AND length(locale) BETWEEN 2 AND 35);
ALTER TABLE intake.communication_authorization_events ADD CONSTRAINT g_ck_intake_communication_authorization_events_10 CHECK (source_kind IN ('ENDPOINT_VERIFICATION','SUBSCRIPTION','ACTION_DECISION','RESPONSE_REQUEST','CORRECTION_REQUEST','PRIVACY_REQUEST','OPT_OUT_RECEIPT','AUTHORIZED_POLICY_JOB'));
ALTER TABLE intake.communication_authorization_events ADD CONSTRAINT g_ck_intake_communication_authorization_events_11 CHECK (actor_type IN ('SUBJECT_SESSION','HUMAN_USER','AUTHORIZED_SERVICE'));
ALTER TABLE intake.communication_authorization_events ADD CONSTRAINT g_ck_intake_communication_authorization_events_12 CHECK (actor_type = 'HUMAN_USER' AND actor_id IS NOT NULL OR actor_type <> 'HUMAN_USER' AND actor_id IS NULL);
ALTER TABLE intake.communication_authorization_events ADD CONSTRAINT g_ck_intake_communication_authorization_events_13 CHECK (expires_at IS NULL OR expires_at > effective_at);
ALTER TABLE intake.communication_authorization_events ADD CONSTRAINT g_ck_intake_communication_authorization_events_14 CHECK (topic_scope_digest = ops.communication_topic_scope_digest(topic_scope));
ALTER TABLE intake.communication_authorization_events ADD CONSTRAINT g_ck_intake_communication_authorization_events_15 CHECK (authorization_kind = 'MARKETING_CONSENT' AND basis = 'CONSENT' OR authorization_kind <> 'MARKETING_CONSENT');
ALTER TABLE intake.communication_authorization_events ADD CONSTRAINT g_ck_intake_communication_authorization_events_16 CHECK (authorization_kind = 'VOICE_CONSENT' AND channel = 'TWILIO_VOICE' OR authorization_kind <> 'VOICE_CONSENT');
ALTER TABLE intake.communication_authorization_events ADD CONSTRAINT g_ck_intake_communication_authorization_events_17 CHECK (change_kind <> 'VERIFIED' OR source_kind = 'ENDPOINT_VERIFICATION');
ALTER TABLE intake.communication_authorization_events ADD CONSTRAINT g_ck_intake_communication_authorization_events_18 CHECK (ops.is_lower_sha256(subject_origin_binding_digest) AND ops.is_lower_sha256(endpoint_snapshot_digest) AND ops.is_lower_sha256(topic_scope_digest) AND ops.is_lower_sha256(policy_digest) AND ops.is_lower_sha256(source_decision_digest) AND ops.is_lower_sha256(proof_digest) AND ops.is_lower_sha256(event_digest) AND ops.is_lower_sha256(receipt_digest));
REVOKE ALL ON intake.communication_authorization_events FROM PUBLIC;
REVOKE ALL ON intake.communication_authorization_events FROM gurine_workflow_worker;
REVOKE ALL ON intake.communication_authorization_events FROM gurine_control_api;
REVOKE ALL ON intake.communication_authorization_events FROM gurine_analysis_worker;
REVOKE ALL ON intake.communication_authorization_events FROM gurine_public_projector;
REVOKE ALL ON intake.communication_authorization_events FROM gurine_notification_worker;
REVOKE ALL ON intake.communication_authorization_events FROM gurine_submission_api;
REVOKE ALL ON intake.communication_authorization_events FROM gurine_auditor;
GRANT SELECT ON intake.communication_authorization_events TO gurine_control_api;
GRANT SELECT ON intake.communication_authorization_events TO gurine_notification_worker;
GRANT SELECT ON intake.communication_authorization_events TO gurine_workflow_worker;
ALTER TABLE intake.communication_authorization_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY communication_authorization_profile_scope ON intake.communication_authorization_events TO gurine_submission_api USING (subject_id::text = current_setting('gurine.communication_subject_id', true));
CREATE POLICY communication_authorization_control_read ON intake.communication_authorization_events TO gurine_control_api USING (subject_id::text = current_setting('gurine.communication_subject_id', true));
CREATE POLICY communication_authorization_gateway_read ON intake.communication_authorization_events TO gurine_notification_worker USING (subject_id::text = current_setting('gurine.communication_subject_id', true));
CREATE TRIGGER intake_communication_authorization_events_immutable_mutation_guard BEFORE UPDATE OR DELETE ON intake.communication_authorization_events FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE intake.communication_preferences (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  subject_id uuid NOT NULL,
  purpose text NOT NULL,
  topic_scope jsonb NOT NULL,
  topic_scope_digest char(64) NOT NULL,
  timezone text NOT NULL,
  frequency text NOT NULL,
  quiet_hours_start time,
  quiet_hours_end time,
  quiet_days smallint[] NOT NULL DEFAULT '{}'::smallint[],
  channel_order text[] NOT NULL,
  fallback_allowed boolean NOT NULL DEFAULT FALSE,
  per_message_cost_ceiling numeric(24,6) NOT NULL,
  currency char(3) NOT NULL,
  locale text NOT NULL,
  version bigint NOT NULL DEFAULT 1,
  preference_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_intake_communication_preferences_1 PRIMARY KEY (id)
);
ALTER TABLE intake.communication_preferences OWNER TO gurine_migrator;
ALTER TABLE intake.communication_preferences ADD CONSTRAINT communication_preference_scope_uq UNIQUE (subject_id, purpose, topic_scope_digest);
ALTER TABLE intake.communication_preferences ADD CONSTRAINT g_ck_intake_communication_preferences_1 CHECK (version > 0);
ALTER TABLE intake.communication_preferences ADD CONSTRAINT g_ck_intake_communication_preferences_2 CHECK (purpose IN ('ENDPOINT_VERIFICATION','RIGHT_OF_REPLY_REQUEST','RIGHT_OF_REPLY_REMINDER','RESPONSE_RECEIPT','CORRECTION_STATUS','CORRECTION_RETRACTION_NOTICE','PRIVACY_TRANSACTIONAL_NOTICE','SECURITY_TRANSACTIONAL_NOTICE','SUBSCRIPTION_UPDATE','PRODUCT_MARKETING','INCIDENT_RECOVERY','INTERNAL_ACTION_REQUEST','DISCRETIONARY_OUTREACH'));
ALTER TABLE intake.communication_preferences ADD CONSTRAINT g_ck_intake_communication_preferences_3 CHECK (frequency IN ('IMMEDIATE','DAILY','WEEKLY'));
ALTER TABLE intake.communication_preferences ADD CONSTRAINT g_ck_intake_communication_preferences_4 CHECK ((quiet_hours_start IS NULL) = (quiet_hours_end IS NULL));
ALTER TABLE intake.communication_preferences ADD CONSTRAINT g_ck_intake_communication_preferences_5 CHECK (quiet_hours_start IS NULL OR quiet_hours_start <> quiet_hours_end);
ALTER TABLE intake.communication_preferences ADD CONSTRAINT g_ck_intake_communication_preferences_6 CHECK (cardinality(quiet_days) BETWEEN 0 AND 7 AND ops.smallint_array_is_unique(quiet_days) AND quiet_days <@ ARRAY[0,1,2,3,4,5,6]::smallint[]);
ALTER TABLE intake.communication_preferences ADD CONSTRAINT g_ck_intake_communication_preferences_7 CHECK (cardinality(channel_order) BETWEEN 1 AND 8 AND intake.communication_channel_array_is_unique(channel_order));
ALTER TABLE intake.communication_preferences ADD CONSTRAINT g_ck_intake_communication_preferences_8 CHECK (intake.communication_channel_array_is_closed(channel_order));
ALTER TABLE intake.communication_preferences ADD CONSTRAINT g_ck_intake_communication_preferences_9 CHECK (fallback_allowed = false OR cardinality(channel_order) >= 2);
ALTER TABLE intake.communication_preferences ADD CONSTRAINT g_ck_intake_communication_preferences_10 CHECK (per_message_cost_ceiling >= 0);
ALTER TABLE intake.communication_preferences ADD CONSTRAINT g_ck_intake_communication_preferences_11 CHECK (currency ~ '^[A-Z]{3}$');
ALTER TABLE intake.communication_preferences ADD CONSTRAINT g_ck_intake_communication_preferences_12 CHECK (length(timezone) BETWEEN 1 AND 64 AND timezone !~ '\\s');
ALTER TABLE intake.communication_preferences ADD CONSTRAINT g_ck_intake_communication_preferences_13 CHECK (length(locale) BETWEEN 2 AND 35);
ALTER TABLE intake.communication_preferences ADD CONSTRAINT g_ck_intake_communication_preferences_14 CHECK (ops.is_lower_sha256(topic_scope_digest) AND ops.is_lower_sha256(preference_digest));
REVOKE ALL ON intake.communication_preferences FROM PUBLIC;
REVOKE ALL ON intake.communication_preferences FROM gurine_workflow_worker;
REVOKE ALL ON intake.communication_preferences FROM gurine_control_api;
REVOKE ALL ON intake.communication_preferences FROM gurine_analysis_worker;
REVOKE ALL ON intake.communication_preferences FROM gurine_public_projector;
REVOKE ALL ON intake.communication_preferences FROM gurine_notification_worker;
REVOKE ALL ON intake.communication_preferences FROM gurine_submission_api;
REVOKE ALL ON intake.communication_preferences FROM gurine_auditor;
GRANT SELECT ON intake.communication_preferences TO gurine_control_api;
GRANT SELECT ON intake.communication_preferences TO gurine_notification_worker;
ALTER TABLE intake.communication_preferences ENABLE ROW LEVEL SECURITY;
CREATE POLICY communication_preference_profile_scope ON intake.communication_preferences TO gurine_submission_api USING (subject_id::text = current_setting('gurine.communication_subject_id', true)) WITH CHECK (subject_id::text = current_setting('gurine.communication_subject_id', true));
CREATE POLICY communication_preference_control_read ON intake.communication_preferences TO gurine_control_api USING (subject_id::text = current_setting('gurine.communication_subject_id', true));
CREATE POLICY communication_preference_gateway_read ON intake.communication_preferences TO gurine_notification_worker USING (subject_id::text = current_setting('gurine.communication_subject_id', true));
CREATE TRIGGER intake_communication_preferences_immutable_mutation_guard BEFORE UPDATE OR DELETE ON intake.communication_preferences FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE intake.communication_suppressions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  subject_id uuid NOT NULL,
  endpoint_id uuid,
  purpose text,
  topic_scope_digest char(64),
  suppression_key_digest char(64) NOT NULL,
  suppression_kind text NOT NULL,
  effect text NOT NULL,
  release_of_suppression_id uuid,
  source_kind text NOT NULL,
  source_id uuid NOT NULL,
  reason_code text NOT NULL,
  proof_digest char(64) NOT NULL,
  effective_at timestamptz NOT NULL,
  expires_at timestamptz,
  event_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL,
  receipt_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_intake_communication_suppressions_1 PRIMARY KEY (id)
);
ALTER TABLE intake.communication_suppressions OWNER TO gurine_migrator;
ALTER TABLE intake.communication_suppressions ADD CONSTRAINT communication_suppression_event_digest_uq UNIQUE (event_digest);
ALTER TABLE intake.communication_suppressions ADD CONSTRAINT communication_suppression_receipt_digest_uq UNIQUE (receipt_digest);
CREATE UNIQUE INDEX communication_suppression_single_release_uq ON intake.communication_suppressions (release_of_suppression_id) WHERE release_of_suppression_id IS NOT NULL;
ALTER TABLE intake.communication_suppressions ADD CONSTRAINT communication_suppression_source_uq UNIQUE (source_kind, source_id);
ALTER TABLE intake.communication_suppressions ADD CONSTRAINT g_ck_intake_communication_suppressions_1 CHECK (purpose IS NULL OR purpose IN ('ENDPOINT_VERIFICATION','RIGHT_OF_REPLY_REQUEST','RIGHT_OF_REPLY_REMINDER','RESPONSE_RECEIPT','CORRECTION_STATUS','CORRECTION_RETRACTION_NOTICE','PRIVACY_TRANSACTIONAL_NOTICE','SECURITY_TRANSACTIONAL_NOTICE','SUBSCRIPTION_UPDATE','PRODUCT_MARKETING','INCIDENT_RECOVERY','INTERNAL_ACTION_REQUEST','DISCRETIONARY_OUTREACH'));
ALTER TABLE intake.communication_suppressions ADD CONSTRAINT g_ck_intake_communication_suppressions_2 CHECK (suppression_kind IN ('USER_OPTOUT','HARD_BOUNCE','SOFT_BOUNCE_LIMIT','ABUSE','LEGAL','PRIVACY','PROVIDER','KILL_SWITCH','DELIVERY_FAILURE'));
ALTER TABLE intake.communication_suppressions ADD CONSTRAINT g_ck_intake_communication_suppressions_3 CHECK (effect IN ('APPLY','RELEASE'));
ALTER TABLE intake.communication_suppressions ADD CONSTRAINT g_ck_intake_communication_suppressions_4 CHECK (source_kind IN ('OPT_OUT_RECEIPT','PROVIDER_EVIDENCE','LEGAL_DECISION','PRIVACY_DECISION','KILL_SWITCH','OPERATOR_DECISION','AUTOMATED_POLICY'));
ALTER TABLE intake.communication_suppressions ADD CONSTRAINT g_ck_intake_communication_suppressions_5 CHECK (effect = 'APPLY' AND release_of_suppression_id IS NULL OR effect = 'RELEASE' AND release_of_suppression_id IS NOT NULL);
ALTER TABLE intake.communication_suppressions ADD CONSTRAINT g_ck_intake_communication_suppressions_6 CHECK (suppression_kind IN ('USER_OPTOUT','ABUSE','LEGAL','PRIVACY') AND expires_at IS NULL OR suppression_kind NOT IN ('USER_OPTOUT','ABUSE','LEGAL','PRIVACY'));
ALTER TABLE intake.communication_suppressions ADD CONSTRAINT g_ck_intake_communication_suppressions_7 CHECK (expires_at IS NULL OR expires_at > effective_at);
ALTER TABLE intake.communication_suppressions ADD CONSTRAINT g_ck_intake_communication_suppressions_8 CHECK ((topic_scope_digest IS NULL OR ops.is_lower_sha256(topic_scope_digest)) AND ops.is_lower_sha256(suppression_key_digest) AND ops.is_lower_sha256(proof_digest) AND ops.is_lower_sha256(event_digest) AND ops.is_lower_sha256(receipt_digest));
REVOKE ALL ON intake.communication_suppressions FROM PUBLIC;
REVOKE ALL ON intake.communication_suppressions FROM gurine_workflow_worker;
REVOKE ALL ON intake.communication_suppressions FROM gurine_control_api;
REVOKE ALL ON intake.communication_suppressions FROM gurine_analysis_worker;
REVOKE ALL ON intake.communication_suppressions FROM gurine_public_projector;
REVOKE ALL ON intake.communication_suppressions FROM gurine_notification_worker;
REVOKE ALL ON intake.communication_suppressions FROM gurine_submission_api;
REVOKE ALL ON intake.communication_suppressions FROM gurine_auditor;
GRANT SELECT ON intake.communication_suppressions TO gurine_control_api;
GRANT SELECT ON intake.communication_suppressions TO gurine_notification_worker;
GRANT SELECT ON intake.communication_suppressions TO gurine_workflow_worker;
ALTER TABLE intake.communication_suppressions ENABLE ROW LEVEL SECURITY;
CREATE POLICY communication_suppression_profile_scope ON intake.communication_suppressions TO gurine_submission_api USING (subject_id::text = current_setting('gurine.communication_subject_id', true));
CREATE POLICY communication_suppression_control_read ON intake.communication_suppressions TO gurine_control_api USING (subject_id::text = current_setting('gurine.communication_subject_id', true));
CREATE POLICY communication_suppression_gateway_read ON intake.communication_suppressions TO gurine_notification_worker USING (subject_id::text = current_setting('gurine.communication_subject_id', true));
CREATE TRIGGER intake_communication_suppressions_immutable_mutation_guard BEFORE UPDATE OR DELETE ON intake.communication_suppressions FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE intake.communication_opt_out_receipts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  subject_id uuid NOT NULL,
  endpoint_id uuid NOT NULL,
  purpose text NOT NULL,
  topic_scope_digest char(64),
  mechanism text NOT NULL,
  request_digest char(64) NOT NULL,
  provider_event_identity_hash char(64),
  callback_event_id uuid,
  authorization_event_id uuid NOT NULL,
  suppression_id uuid NOT NULL,
  idempotency_scope text NOT NULL,
  idempotency_key_hash char(64) NOT NULL,
  receipt_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL,
  occurred_at timestamptz NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_intake_communication_opt_out_receipts_1 PRIMARY KEY (id)
);
ALTER TABLE intake.communication_opt_out_receipts OWNER TO gurine_migrator;
ALTER TABLE intake.communication_opt_out_receipts ADD CONSTRAINT communication_opt_out_idempotency_uq UNIQUE (idempotency_scope, idempotency_key_hash);
ALTER TABLE intake.communication_opt_out_receipts ADD CONSTRAINT communication_opt_out_receipt_digest_uq UNIQUE (receipt_digest);
CREATE UNIQUE INDEX communication_opt_out_provider_event_uq ON intake.communication_opt_out_receipts (provider_event_identity_hash) WHERE provider_event_identity_hash IS NOT NULL;
ALTER TABLE intake.communication_opt_out_receipts ADD CONSTRAINT g_ck_intake_communication_opt_out_receipts_1 CHECK (purpose IN ('ENDPOINT_VERIFICATION','RIGHT_OF_REPLY_REQUEST','RIGHT_OF_REPLY_REMINDER','RESPONSE_RECEIPT','CORRECTION_STATUS','CORRECTION_RETRACTION_NOTICE','PRIVACY_TRANSACTIONAL_NOTICE','SECURITY_TRANSACTIONAL_NOTICE','SUBSCRIPTION_UPDATE','PRODUCT_MARKETING','INCIDENT_RECOVERY','INTERNAL_ACTION_REQUEST','DISCRETIONARY_OUTREACH'));
ALTER TABLE intake.communication_opt_out_receipts ADD CONSTRAINT g_ck_intake_communication_opt_out_receipts_2 CHECK (mechanism IN ('ONE_CLICK_UNSUBSCRIBE','EMAIL_MANAGEMENT','SMS_STOP','CHAT_SIGNED_COMMAND','CHAT_SIGNED_BUTTON','VOICE_EXPLICIT','INTERNAL_PRIVACY_DECISION'));
ALTER TABLE intake.communication_opt_out_receipts ADD CONSTRAINT g_ck_intake_communication_opt_out_receipts_3 CHECK (length(idempotency_scope) BETWEEN 1 AND 200);
ALTER TABLE intake.communication_opt_out_receipts ADD CONSTRAINT g_ck_intake_communication_opt_out_receipts_4 CHECK (recorded_at >= occurred_at);
ALTER TABLE intake.communication_opt_out_receipts ADD CONSTRAINT g_ck_intake_communication_opt_out_receipts_5 CHECK ((topic_scope_digest IS NULL OR ops.is_lower_sha256(topic_scope_digest)) AND ops.is_lower_sha256(request_digest) AND (provider_event_identity_hash IS NULL OR ops.is_lower_sha256(provider_event_identity_hash)) AND ops.is_lower_sha256(idempotency_key_hash) AND ops.is_lower_sha256(receipt_digest));
REVOKE ALL ON intake.communication_opt_out_receipts FROM PUBLIC;
REVOKE ALL ON intake.communication_opt_out_receipts FROM gurine_workflow_worker;
REVOKE ALL ON intake.communication_opt_out_receipts FROM gurine_control_api;
REVOKE ALL ON intake.communication_opt_out_receipts FROM gurine_analysis_worker;
REVOKE ALL ON intake.communication_opt_out_receipts FROM gurine_public_projector;
REVOKE ALL ON intake.communication_opt_out_receipts FROM gurine_notification_worker;
REVOKE ALL ON intake.communication_opt_out_receipts FROM gurine_submission_api;
REVOKE ALL ON intake.communication_opt_out_receipts FROM gurine_auditor;
GRANT SELECT ON intake.communication_opt_out_receipts TO gurine_control_api;
GRANT SELECT ON intake.communication_opt_out_receipts TO gurine_notification_worker;
ALTER TABLE intake.communication_opt_out_receipts ENABLE ROW LEVEL SECURITY;
CREATE POLICY communication_opt_out_profile_scope ON intake.communication_opt_out_receipts TO gurine_submission_api USING (subject_id::text = current_setting('gurine.communication_subject_id', true));
CREATE POLICY communication_opt_out_control_read ON intake.communication_opt_out_receipts TO gurine_control_api USING (subject_id::text = current_setting('gurine.communication_subject_id', true));
CREATE POLICY communication_opt_out_gateway_read ON intake.communication_opt_out_receipts TO gurine_notification_worker USING (subject_id::text = current_setting('gurine.communication_subject_id', true));
CREATE TRIGGER intake_communication_opt_out_receipts_immutable_mutation_guard BEFORE UPDATE OR DELETE ON intake.communication_opt_out_receipts FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.communication_provider_configs (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  integration_id uuid NOT NULL DEFAULT gen_random_uuid(),
  deployment_id text NOT NULL,
  environment text NOT NULL,
  channel text NOT NULL,
  adapter_id text NOT NULL,
  operational_state text NOT NULL DEFAULT 'DISABLED',
  version bigint NOT NULL DEFAULT 1,
  provider_account_hmac char(64) NOT NULL,
  sender_identity_ciphertext bytea NOT NULL,
  sender_identity_hmac char(64) NOT NULL,
  encryption_key_id text NOT NULL,
  credential_secret_reference text NOT NULL,
  webhook_secret_reference text,
  callback_path text,
  callback_allowlist_digest char(64),
  jurisdiction_set jsonb NOT NULL,
  jurisdiction_set_digest char(64) NOT NULL,
  dpa_evidence_digest char(64) NOT NULL,
  approved_template_catalog_digest char(64) NOT NULL,
  rate_limit_policy jsonb NOT NULL,
  rate_limit_policy_digest char(64) NOT NULL,
  cost_policy jsonb NOT NULL,
  cost_policy_digest char(64) NOT NULL,
  provider_capabilities jsonb NOT NULL,
  provider_capabilities_digest char(64) NOT NULL,
  kill_switch_code text NOT NULL,
  configuration_digest char(64) NOT NULL,
  latest_preflight_receipt_id uuid,
  activation_decision_id uuid,
  activation_receipt_digest char(64),
  activation_effective_at timestamptz,
  activation_expires_at timestamptz,
  created_by uuid NOT NULL,
  updated_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_ops_communication_provider_configs_1 PRIMARY KEY (id)
);
ALTER TABLE ops.communication_provider_configs OWNER TO gurine_migrator;
ALTER TABLE ops.communication_provider_configs ADD CONSTRAINT communication_provider_integration_uq UNIQUE (integration_id);
ALTER TABLE ops.communication_provider_configs ADD CONSTRAINT communication_provider_sender_uq UNIQUE (deployment_id, environment, channel, provider_account_hmac, sender_identity_hmac);
ALTER TABLE ops.communication_provider_configs ADD CONSTRAINT communication_provider_configuration_digest_uq UNIQUE (deployment_id, environment, configuration_digest);
ALTER TABLE ops.communication_provider_configs ADD CONSTRAINT communication_provider_id_version_digest_uq UNIQUE (id, version, configuration_digest);
ALTER TABLE ops.communication_provider_configs ADD CONSTRAINT g_ck_ops_communication_provider_configs_1 CHECK (environment IN ('development','test','staging','production'));
ALTER TABLE ops.communication_provider_configs ADD CONSTRAINT g_ck_ops_communication_provider_configs_2 CHECK (channel IN ('SMTP_EMAIL','TELEGRAM_BOT_API','META_WHATSAPP_BUSINESS_CLOUD','LINE_MESSAGING_API','SOLAPI_SMS','SOLAPI_KAKAO_BIZMESSAGE','TWILIO_VOICE','SIGNED_WEBHOOK'));
ALTER TABLE ops.communication_provider_configs ADD CONSTRAINT g_ck_ops_communication_provider_configs_3 CHECK (adapter_id IN ('smtp-email-v1','telegram-bot-api-v1','meta-whatsapp-business-cloud-v1','line-messaging-api-v1','solapi-sms-v1','solapi-kakao-bizmessage-v1','twilio-voice-v1','signed-webhook-v1'));
ALTER TABLE ops.communication_provider_configs ADD CONSTRAINT g_ck_ops_communication_provider_configs_4 CHECK (channel = 'SMTP_EMAIL' AND adapter_id = 'smtp-email-v1' OR channel = 'TELEGRAM_BOT_API' AND adapter_id = 'telegram-bot-api-v1' OR channel = 'META_WHATSAPP_BUSINESS_CLOUD' AND adapter_id = 'meta-whatsapp-business-cloud-v1' OR channel = 'LINE_MESSAGING_API' AND adapter_id = 'line-messaging-api-v1' OR channel = 'SOLAPI_SMS' AND adapter_id = 'solapi-sms-v1' OR channel = 'SOLAPI_KAKAO_BIZMESSAGE' AND adapter_id = 'solapi-kakao-bizmessage-v1' OR channel = 'TWILIO_VOICE' AND adapter_id = 'twilio-voice-v1' OR channel = 'SIGNED_WEBHOOK' AND adapter_id = 'signed-webhook-v1');
ALTER TABLE ops.communication_provider_configs ADD CONSTRAINT g_ck_ops_communication_provider_configs_5 CHECK (operational_state IN ('DISABLED','UNCONFIGURED','PENDING_PROVIDER_APPROVAL','ACTIVE','SUSPENDED'));
ALTER TABLE ops.communication_provider_configs ADD CONSTRAINT g_ck_ops_communication_provider_configs_6 CHECK (version > 0);
ALTER TABLE ops.communication_provider_configs ADD CONSTRAINT g_ck_ops_communication_provider_configs_7 CHECK (octet_length(sender_identity_ciphertext) BETWEEN 1 AND 16384);
ALTER TABLE ops.communication_provider_configs ADD CONSTRAINT g_ck_ops_communication_provider_configs_8 CHECK (length(deployment_id) BETWEEN 1 AND 100);
ALTER TABLE ops.communication_provider_configs ADD CONSTRAINT g_ck_ops_communication_provider_configs_9 CHECK (length(credential_secret_reference) BETWEEN 1 AND 500 AND credential_secret_reference !~ '[[:space:]]');
ALTER TABLE ops.communication_provider_configs ADD CONSTRAINT g_ck_ops_communication_provider_configs_10 CHECK (webhook_secret_reference IS NULL OR length(webhook_secret_reference) BETWEEN 1 AND 500);
ALTER TABLE ops.communication_provider_configs ADD CONSTRAINT g_ck_ops_communication_provider_configs_11 CHECK (ops.secret_reference_is_version_pinned(credential_secret_reference) AND (webhook_secret_reference IS NULL OR ops.secret_reference_is_version_pinned(webhook_secret_reference)));
ALTER TABLE ops.communication_provider_configs ADD CONSTRAINT g_ck_ops_communication_provider_configs_12 CHECK (callback_path IS NULL OR callback_path ~ '^/private/v1/callbacks/');
ALTER TABLE ops.communication_provider_configs ADD CONSTRAINT g_ck_ops_communication_provider_configs_13 CHECK (channel = 'SIGNED_WEBHOOK' AND webhook_secret_reference IS NULL AND callback_path IS NULL AND callback_allowlist_digest IS NULL OR channel <> 'SIGNED_WEBHOOK' AND webhook_secret_reference IS NOT NULL AND callback_path IS NOT NULL AND callback_allowlist_digest IS NOT NULL);
ALTER TABLE ops.communication_provider_configs ADD CONSTRAINT g_ck_ops_communication_provider_configs_14 CHECK (operational_state = 'ACTIVE' AND latest_preflight_receipt_id IS NOT NULL AND activation_decision_id IS NOT NULL AND activation_receipt_digest IS NOT NULL AND activation_effective_at IS NOT NULL OR operational_state <> 'ACTIVE');
ALTER TABLE ops.communication_provider_configs ADD CONSTRAINT g_ck_ops_communication_provider_configs_15 CHECK (activation_expires_at IS NULL OR activation_expires_at > activation_effective_at);
ALTER TABLE ops.communication_provider_configs ADD CONSTRAINT g_ck_ops_communication_provider_configs_16 CHECK (ops.is_lower_sha256(provider_account_hmac) AND ops.is_lower_sha256(sender_identity_hmac) AND (callback_allowlist_digest IS NULL OR ops.is_lower_sha256(callback_allowlist_digest)) AND ops.is_lower_sha256(jurisdiction_set_digest) AND ops.is_lower_sha256(dpa_evidence_digest) AND ops.is_lower_sha256(approved_template_catalog_digest) AND ops.is_lower_sha256(rate_limit_policy_digest) AND ops.is_lower_sha256(cost_policy_digest) AND ops.is_lower_sha256(provider_capabilities_digest) AND ops.is_lower_sha256(configuration_digest) AND (activation_receipt_digest IS NULL OR ops.is_lower_sha256(activation_receipt_digest)));
REVOKE ALL ON ops.communication_provider_configs FROM PUBLIC;
REVOKE ALL ON ops.communication_provider_configs FROM gurine_workflow_worker;
REVOKE ALL ON ops.communication_provider_configs FROM gurine_control_api;
REVOKE ALL ON ops.communication_provider_configs FROM gurine_analysis_worker;
REVOKE ALL ON ops.communication_provider_configs FROM gurine_public_projector;
REVOKE ALL ON ops.communication_provider_configs FROM gurine_notification_worker;
REVOKE ALL ON ops.communication_provider_configs FROM gurine_submission_api;
REVOKE ALL ON ops.communication_provider_configs FROM gurine_auditor;
GRANT SELECT(id, integration_id, deployment_id, environment, channel, adapter_id, operational_state, version, provider_account_hmac, sender_identity_hmac, jurisdiction_set, jurisdiction_set_digest, dpa_evidence_digest, approved_template_catalog_digest, rate_limit_policy, rate_limit_policy_digest, cost_policy, cost_policy_digest, provider_capabilities, provider_capabilities_digest, kill_switch_code, configuration_digest, latest_preflight_receipt_id, activation_decision_id, activation_receipt_digest, activation_effective_at, activation_expires_at, created_by, updated_by, created_at, updated_at) ON ops.communication_provider_configs TO gurine_control_api;
GRANT SELECT ON ops.communication_provider_configs TO gurine_notification_worker;
GRANT SELECT(id, integration_id, deployment_id, environment, channel, adapter_id, operational_state, version, configuration_digest, latest_preflight_receipt_id, activation_decision_id, activation_receipt_digest, activation_effective_at, activation_expires_at) ON ops.communication_provider_configs TO gurine_workflow_worker;
GRANT SELECT(id, integration_id, deployment_id, environment, channel, adapter_id, operational_state, version, provider_account_hmac, sender_identity_hmac, jurisdiction_set_digest, dpa_evidence_digest, approved_template_catalog_digest, rate_limit_policy_digest, cost_policy_digest, provider_capabilities_digest, kill_switch_code, configuration_digest, latest_preflight_receipt_id, activation_decision_id, activation_receipt_digest, activation_effective_at, activation_expires_at, created_by, updated_by, created_at, updated_at) ON ops.communication_provider_configs TO gurine_auditor;
CREATE TRIGGER ops_communication_provider_configs_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.communication_provider_configs FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.communication_provider_preflight_receipts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  provider_config_id uuid NOT NULL,
  provider_config_version bigint NOT NULL,
  configuration_digest char(64) NOT NULL,
  provider_revision_snapshot jsonb NOT NULL,
  provider_revision_snapshot_digest char(64) NOT NULL,
  test_generation bigint NOT NULL,
  test_environment text NOT NULL,
  result text NOT NULL,
  live_sandbox boolean NOT NULL,
  callback_or_poll_verified boolean NOT NULL,
  sender_identity_verified boolean NOT NULL,
  template_catalog_verified boolean NOT NULL,
  idempotency_capability text NOT NULL,
  reconciliation_capability text NOT NULL,
  highest_delivery_proof text NOT NULL,
  checklist jsonb NOT NULL,
  checklist_digest char(64) NOT NULL,
  blocker_set jsonb NOT NULL,
  blocker_set_digest char(64) NOT NULL,
  provider_evidence_digest char(64) NOT NULL,
  contract_test_receipt_digest char(64) NOT NULL,
  receipt_digest char(64) NOT NULL,
  performed_by_service text NOT NULL,
  requested_by uuid NOT NULL,
  started_at timestamptz NOT NULL,
  completed_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_ops_communication_provider_preflight_receipts_1 PRIMARY KEY (id)
);
ALTER TABLE ops.communication_provider_preflight_receipts OWNER TO gurine_migrator;
ALTER TABLE ops.communication_provider_preflight_receipts ADD CONSTRAINT communication_provider_preflight_generation_uq UNIQUE (provider_config_id, provider_config_version, test_generation);
ALTER TABLE ops.communication_provider_preflight_receipts ADD CONSTRAINT communication_provider_revision_receipt_uq UNIQUE (id, provider_config_id, provider_config_version, configuration_digest, receipt_digest);
ALTER TABLE ops.communication_provider_preflight_receipts ADD CONSTRAINT communication_provider_preflight_receipt_digest_uq UNIQUE (receipt_digest);
ALTER TABLE ops.communication_provider_preflight_receipts ADD CONSTRAINT g_ck_ops_communication_provider_preflight_receipts_1 CHECK (provider_config_version > 0 AND test_generation > 0);
ALTER TABLE ops.communication_provider_preflight_receipts ADD CONSTRAINT g_ck_ops_communication_provider_preflight_receipts_2 CHECK (test_environment IN ('development','test','staging','production'));
ALTER TABLE ops.communication_provider_preflight_receipts ADD CONSTRAINT g_ck_ops_communication_provider_preflight_receipts_3 CHECK (result IN ('PASS','FAIL','INCOMPLETE'));
ALTER TABLE ops.communication_provider_preflight_receipts ADD CONSTRAINT g_ck_ops_communication_provider_preflight_receipts_4 CHECK (idempotency_capability IN ('NATIVE_IDEMPOTENCY','LOOKUP_BEFORE_RETRY','NONE'));
ALTER TABLE ops.communication_provider_preflight_receipts ADD CONSTRAINT g_ck_ops_communication_provider_preflight_receipts_5 CHECK (reconciliation_capability IN ('SIGNED_CALLBACK','AUTHENTICATED_POLL','PROVIDER_LOOKUP','NONE'));
ALTER TABLE ops.communication_provider_preflight_receipts ADD CONSTRAINT g_ck_ops_communication_provider_preflight_receipts_6 CHECK (highest_delivery_proof IN ('PROVIDER_ACCEPTED','DELIVERED','READ'));
ALTER TABLE ops.communication_provider_preflight_receipts ADD CONSTRAINT g_ck_ops_communication_provider_preflight_receipts_7 CHECK (completed_at >= started_at AND expires_at > completed_at);
ALTER TABLE ops.communication_provider_preflight_receipts ADD CONSTRAINT g_ck_ops_communication_provider_preflight_receipts_8 CHECK (provider_revision_snapshot_digest = configuration_digest);
ALTER TABLE ops.communication_provider_preflight_receipts ADD CONSTRAINT g_ck_ops_communication_provider_preflight_receipts_9 CHECK (ops.communication_provider_revision_snapshot_is_valid(provider_revision_snapshot, provider_revision_snapshot_digest));
ALTER TABLE ops.communication_provider_preflight_receipts ADD CONSTRAINT g_ck_ops_communication_provider_preflight_receipts_10 CHECK (result = 'PASS' AND live_sandbox AND callback_or_poll_verified AND sender_identity_verified AND template_catalog_verified AND blocker_set = '[]'::jsonb OR result <> 'PASS');
ALTER TABLE ops.communication_provider_preflight_receipts ADD CONSTRAINT g_ck_ops_communication_provider_preflight_receipts_11 CHECK (ops.is_lower_sha256(configuration_digest) AND ops.is_lower_sha256(provider_revision_snapshot_digest) AND ops.is_lower_sha256(checklist_digest) AND ops.is_lower_sha256(blocker_set_digest) AND ops.is_lower_sha256(provider_evidence_digest) AND ops.is_lower_sha256(contract_test_receipt_digest) AND ops.is_lower_sha256(receipt_digest));
REVOKE ALL ON ops.communication_provider_preflight_receipts FROM PUBLIC;
REVOKE ALL ON ops.communication_provider_preflight_receipts FROM gurine_workflow_worker;
REVOKE ALL ON ops.communication_provider_preflight_receipts FROM gurine_control_api;
REVOKE ALL ON ops.communication_provider_preflight_receipts FROM gurine_analysis_worker;
REVOKE ALL ON ops.communication_provider_preflight_receipts FROM gurine_public_projector;
REVOKE ALL ON ops.communication_provider_preflight_receipts FROM gurine_notification_worker;
REVOKE ALL ON ops.communication_provider_preflight_receipts FROM gurine_submission_api;
REVOKE ALL ON ops.communication_provider_preflight_receipts FROM gurine_auditor;
GRANT SELECT ON ops.communication_provider_preflight_receipts TO gurine_control_api;
GRANT SELECT ON ops.communication_provider_preflight_receipts TO gurine_notification_worker;
GRANT SELECT ON ops.communication_provider_preflight_receipts TO gurine_workflow_worker;
GRANT SELECT ON ops.communication_provider_preflight_receipts TO gurine_auditor;
CREATE TRIGGER ops_communication_provider_preflight_receipts_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.communication_provider_preflight_receipts FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.communication_intents (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  deployment_id text NOT NULL,
  logical_intent_digest char(64) NOT NULL,
  source_event_id uuid NOT NULL,
  source_event_type text NOT NULL,
  source_object_type text NOT NULL,
  source_object_id uuid NOT NULL,
  material_event_version bigint NOT NULL,
  communication_class text NOT NULL,
  purpose text NOT NULL,
  topic_scope jsonb NOT NULL,
  topic_scope_digest char(64) NOT NULL,
  recipient_subject_id uuid NOT NULL,
  audience_policy_version text NOT NULL,
  audience_policy_digest char(64) NOT NULL,
  policy_snapshot_digest char(64) NOT NULL,
  effect_safety_class text NOT NULL,
  source_decision_receipt_id uuid NOT NULL,
  source_decision_digest char(64) NOT NULL,
  state text NOT NULL DEFAULT 'CREATED',
  version bigint NOT NULL DEFAULT 1,
  intent_digest char(64) NOT NULL,
  creation_receipt_digest char(64) NOT NULL,
  transition_receipt_digest char(64),
  terminal_reason_code text,
  terminal_evidence_digest char(64),
  policy_blocker_code text,
  policy_blocker_digest char(64),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  state_changed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  materialized_at timestamptz,
  cancelled_at timestamptz,
  CONSTRAINT g_pk_ops_communication_intents_1 PRIMARY KEY (id)
);
ALTER TABLE ops.communication_intents OWNER TO gurine_migrator;
ALTER TABLE ops.communication_intents ADD CONSTRAINT communication_logical_intent_uq UNIQUE (deployment_id, logical_intent_digest);
ALTER TABLE ops.communication_intents ADD CONSTRAINT communication_intent_natural_identity_uq UNIQUE (deployment_id, source_event_id, material_event_version, communication_class, purpose, topic_scope_digest, recipient_subject_id, audience_policy_version);
ALTER TABLE ops.communication_intents ADD CONSTRAINT communication_intent_source_binding_uq UNIQUE (id, source_object_type, source_object_id, source_decision_digest);
ALTER TABLE ops.communication_intents ADD CONSTRAINT communication_intent_digest_uq UNIQUE (intent_digest);
ALTER TABLE ops.communication_intents ADD CONSTRAINT communication_intent_id_digest_uq UNIQUE (id, intent_digest);
ALTER TABLE ops.communication_intents ADD CONSTRAINT g_ck_ops_communication_intents_1 CHECK (material_event_version > 0 AND version > 0);
ALTER TABLE ops.communication_intents ADD CONSTRAINT g_ck_ops_communication_intents_2 CHECK (communication_class IN ('SYSTEM_TRANSACTIONAL','SUBSCRIPTION_UPDATE','DISCRETIONARY_EXTERNAL','INTERNAL_ACTION_REQUEST'));
ALTER TABLE ops.communication_intents ADD CONSTRAINT g_ck_ops_communication_intents_3 CHECK (purpose IN ('ENDPOINT_VERIFICATION','RIGHT_OF_REPLY_REQUEST','RIGHT_OF_REPLY_REMINDER','RESPONSE_RECEIPT','CORRECTION_STATUS','CORRECTION_RETRACTION_NOTICE','PRIVACY_TRANSACTIONAL_NOTICE','SECURITY_TRANSACTIONAL_NOTICE','SUBSCRIPTION_UPDATE','PRODUCT_MARKETING','INCIDENT_RECOVERY','INTERNAL_ACTION_REQUEST','DISCRETIONARY_OUTREACH'));
ALTER TABLE ops.communication_intents ADD CONSTRAINT g_ck_ops_communication_intents_4 CHECK (state IN ('CREATED','MATERIALIZED','POLICY_BLOCKED','CANCELLED'));
ALTER TABLE ops.communication_intents ADD CONSTRAINT g_ck_ops_communication_intents_5 CHECK (length(deployment_id) BETWEEN 1 AND 100);
ALTER TABLE ops.communication_intents ADD CONSTRAINT g_ck_ops_communication_intents_6 CHECK (length(source_event_type) BETWEEN 1 AND 200);
ALTER TABLE ops.communication_intents ADD CONSTRAINT g_ck_ops_communication_intents_7 CHECK (length(source_object_type) BETWEEN 1 AND 100);
ALTER TABLE ops.communication_intents ADD CONSTRAINT g_ck_ops_communication_intents_8 CHECK (length(audience_policy_version) BETWEEN 1 AND 100);
ALTER TABLE ops.communication_intents ADD CONSTRAINT g_ck_ops_communication_intents_9 CHECK (effect_safety_class IN ('DUPLICATION_SENSITIVE','DUPLICATION_TOLERANT'));
ALTER TABLE ops.communication_intents ADD CONSTRAINT g_ck_ops_communication_intents_10 CHECK (intent_digest = logical_intent_digest);
ALTER TABLE ops.communication_intents ADD CONSTRAINT g_ck_ops_communication_intents_11 CHECK (communication_class = 'SUBSCRIPTION_UPDATE' AND purpose = 'SUBSCRIPTION_UPDATE' OR communication_class <> 'SUBSCRIPTION_UPDATE');
ALTER TABLE ops.communication_intents ADD CONSTRAINT g_ck_ops_communication_intents_12 CHECK (communication_class = 'INTERNAL_ACTION_REQUEST' AND purpose = 'INTERNAL_ACTION_REQUEST' OR communication_class <> 'INTERNAL_ACTION_REQUEST');
ALTER TABLE ops.communication_intents ADD CONSTRAINT g_ck_ops_communication_intents_13 CHECK (communication_class = 'SYSTEM_TRANSACTIONAL' AND purpose IN ('ENDPOINT_VERIFICATION','RIGHT_OF_REPLY_REQUEST','RIGHT_OF_REPLY_REMINDER','RESPONSE_RECEIPT','CORRECTION_STATUS','CORRECTION_RETRACTION_NOTICE','PRIVACY_TRANSACTIONAL_NOTICE','SECURITY_TRANSACTIONAL_NOTICE','INCIDENT_RECOVERY') OR communication_class <> 'SYSTEM_TRANSACTIONAL');
ALTER TABLE ops.communication_intents ADD CONSTRAINT g_ck_ops_communication_intents_14 CHECK (communication_class = 'DISCRETIONARY_EXTERNAL' OR purpose NOT IN ('PRODUCT_MARKETING','DISCRETIONARY_OUTREACH'));
ALTER TABLE ops.communication_intents ADD CONSTRAINT g_ck_ops_communication_intents_15 CHECK (state = 'CREATED' AND materialized_at IS NULL AND cancelled_at IS NULL OR state = 'MATERIALIZED' AND materialized_at IS NOT NULL AND cancelled_at IS NULL OR state = 'POLICY_BLOCKED' AND policy_blocker_code IS NOT NULL AND policy_blocker_digest IS NOT NULL OR state = 'CANCELLED' AND cancelled_at IS NOT NULL);
ALTER TABLE ops.communication_intents ADD CONSTRAINT g_ck_ops_communication_intents_16 CHECK (state = 'CREATED' AND transition_receipt_digest IS NULL AND terminal_reason_code IS NULL AND terminal_evidence_digest IS NULL OR state = 'MATERIALIZED' AND transition_receipt_digest IS NOT NULL OR state IN ('POLICY_BLOCKED','CANCELLED') AND transition_receipt_digest IS NOT NULL AND terminal_reason_code IS NOT NULL AND terminal_evidence_digest IS NOT NULL);
ALTER TABLE ops.communication_intents ADD CONSTRAINT g_ck_ops_communication_intents_17 CHECK (state_changed_at >= created_at);
ALTER TABLE ops.communication_intents ADD CONSTRAINT g_ck_ops_communication_intents_18 CHECK (ops.is_lower_sha256(logical_intent_digest) AND ops.is_lower_sha256(topic_scope_digest) AND ops.is_lower_sha256(audience_policy_digest) AND ops.is_lower_sha256(policy_snapshot_digest) AND ops.is_lower_sha256(source_decision_digest) AND ops.is_lower_sha256(intent_digest) AND ops.is_lower_sha256(creation_receipt_digest) AND (transition_receipt_digest IS NULL OR ops.is_lower_sha256(transition_receipt_digest)) AND (terminal_evidence_digest IS NULL OR ops.is_lower_sha256(terminal_evidence_digest)) AND (policy_blocker_digest IS NULL OR ops.is_lower_sha256(policy_blocker_digest)));
REVOKE ALL ON ops.communication_intents FROM PUBLIC;
REVOKE ALL ON ops.communication_intents FROM gurine_workflow_worker;
REVOKE ALL ON ops.communication_intents FROM gurine_control_api;
REVOKE ALL ON ops.communication_intents FROM gurine_analysis_worker;
REVOKE ALL ON ops.communication_intents FROM gurine_public_projector;
REVOKE ALL ON ops.communication_intents FROM gurine_notification_worker;
REVOKE ALL ON ops.communication_intents FROM gurine_submission_api;
REVOKE ALL ON ops.communication_intents FROM gurine_auditor;
GRANT SELECT ON ops.communication_intents TO gurine_control_api;
GRANT SELECT ON ops.communication_intents TO gurine_notification_worker;
GRANT SELECT ON ops.communication_intents TO gurine_workflow_worker;
GRANT SELECT ON ops.communication_intents TO gurine_auditor;
CREATE TRIGGER ops_communication_intents_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.communication_intents FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.communication_renderings (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  intent_id uuid NOT NULL,
  rendering_revision bigint NOT NULL,
  endpoint_id uuid NOT NULL,
  endpoint_version bigint NOT NULL,
  endpoint_snapshot_digest char(64) NOT NULL,
  channel text NOT NULL,
  locale text NOT NULL,
  template_id text NOT NULL,
  template_revision text NOT NULL,
  variable_set jsonb NOT NULL,
  variable_set_digest char(64) NOT NULL,
  attachment_manifest jsonb NOT NULL,
  attachment_manifest_digest char(64) NOT NULL,
  disclosure_class text NOT NULL,
  semantic_payload_digest char(64) NOT NULL,
  recipient_binding_digest char(64) NOT NULL,
  rendered_envelope_ciphertext bytea NOT NULL,
  encryption_key_id text NOT NULL,
  rendered_sha256 char(64) NOT NULL,
  rendered_byte_length bigint NOT NULL,
  transport_content_type text NOT NULL,
  state text NOT NULL DEFAULT 'DRAFT',
  state_version bigint NOT NULL DEFAULT 1,
  rendering_digest char(64) NOT NULL,
  approval_kind text,
  approval_proposal_id uuid,
  approval_proposal_version bigint,
  approval_digest char(64),
  policy_decision_digest char(64),
  approval_receipt_digest char(64),
  transition_receipt_digest char(64) NOT NULL,
  approval_expires_at timestamptz,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  approved_at timestamptz,
  superseded_at timestamptz,
  CONSTRAINT g_pk_ops_communication_renderings_1 PRIMARY KEY (id)
);
ALTER TABLE ops.communication_renderings OWNER TO gurine_migrator;
ALTER TABLE ops.communication_renderings ADD CONSTRAINT communication_rendering_revision_uq UNIQUE (intent_id, endpoint_id, channel, rendering_revision);
ALTER TABLE ops.communication_renderings ADD CONSTRAINT communication_rendering_digest_uq UNIQUE (rendering_digest);
ALTER TABLE ops.communication_renderings ADD CONSTRAINT communication_rendered_bytes_uq UNIQUE (intent_id, endpoint_id, channel, rendered_sha256);
ALTER TABLE ops.communication_renderings ADD CONSTRAINT communication_rendering_id_digest_bytes_uq UNIQUE (id, rendering_digest, rendered_sha256);
ALTER TABLE ops.communication_renderings ADD CONSTRAINT g_ck_ops_communication_renderings_1 CHECK (rendering_revision > 0 AND endpoint_version > 0 AND state_version > 0);
ALTER TABLE ops.communication_renderings ADD CONSTRAINT g_ck_ops_communication_renderings_2 CHECK (channel IN ('SMTP_EMAIL','TELEGRAM_BOT_API','META_WHATSAPP_BUSINESS_CLOUD','LINE_MESSAGING_API','SOLAPI_SMS','SOLAPI_KAKAO_BIZMESSAGE','TWILIO_VOICE','SIGNED_WEBHOOK'));
ALTER TABLE ops.communication_renderings ADD CONSTRAINT g_ck_ops_communication_renderings_3 CHECK (state IN ('DRAFT','AWAITING_APPROVAL','APPROVED','REJECTED','CHANGES_REQUIRED','EXPIRED','SUPERSEDED'));
ALTER TABLE ops.communication_renderings ADD CONSTRAINT g_ck_ops_communication_renderings_4 CHECK (length(locale) BETWEEN 2 AND 35);
ALTER TABLE ops.communication_renderings ADD CONSTRAINT g_ck_ops_communication_renderings_5 CHECK (length(template_id) BETWEEN 1 AND 200 AND length(template_revision) BETWEEN 1 AND 100);
ALTER TABLE ops.communication_renderings ADD CONSTRAINT g_ck_ops_communication_renderings_6 CHECK (disclosure_class IN ('PUBLIC','INTERNAL_MINIMAL','CONFIDENTIAL_LINK_ONLY'));
ALTER TABLE ops.communication_renderings ADD CONSTRAINT g_ck_ops_communication_renderings_7 CHECK (rendered_byte_length BETWEEN 1 AND 10485760 AND octet_length(rendered_envelope_ciphertext) >= rendered_byte_length);
ALTER TABLE ops.communication_renderings ADD CONSTRAINT g_ck_ops_communication_renderings_8 CHECK (length(encryption_key_id) BETWEEN 1 AND 200 AND length(transport_content_type) BETWEEN 1 AND 200);
ALTER TABLE ops.communication_renderings ADD CONSTRAINT g_ck_ops_communication_renderings_9 CHECK (expires_at > created_at);
ALTER TABLE ops.communication_renderings ADD CONSTRAINT g_ck_ops_communication_renderings_10 CHECK (approval_kind IS NULL OR approval_kind IN ('POLICY','HUMAN'));
ALTER TABLE ops.communication_renderings ADD CONSTRAINT g_ck_ops_communication_renderings_11 CHECK (approval_kind = 'HUMAN' AND approval_proposal_id IS NOT NULL AND approval_proposal_version IS NOT NULL AND approval_digest IS NOT NULL AND policy_decision_digest IS NULL OR approval_kind = 'POLICY' AND approval_proposal_id IS NULL AND approval_proposal_version IS NULL AND approval_digest IS NOT NULL AND policy_decision_digest IS NOT NULL OR approval_kind IS NULL AND approval_proposal_id IS NULL AND approval_proposal_version IS NULL AND approval_digest IS NULL AND policy_decision_digest IS NULL);
ALTER TABLE ops.communication_renderings ADD CONSTRAINT g_ck_ops_communication_renderings_12 CHECK (state = 'APPROVED' AND approval_kind IS NOT NULL AND approval_receipt_digest IS NOT NULL AND approval_expires_at IS NOT NULL AND approved_at IS NOT NULL OR state <> 'APPROVED');
ALTER TABLE ops.communication_renderings ADD CONSTRAINT g_ck_ops_communication_renderings_13 CHECK (approval_expires_at IS NULL OR approval_expires_at <= expires_at);
ALTER TABLE ops.communication_renderings ADD CONSTRAINT g_ck_ops_communication_renderings_14 CHECK (state = 'SUPERSEDED' AND superseded_at IS NOT NULL OR state <> 'SUPERSEDED');
ALTER TABLE ops.communication_renderings ADD CONSTRAINT g_ck_ops_communication_renderings_15 CHECK (ops.is_lower_sha256(endpoint_snapshot_digest) AND ops.is_lower_sha256(variable_set_digest) AND ops.is_lower_sha256(attachment_manifest_digest) AND ops.is_lower_sha256(semantic_payload_digest) AND ops.is_lower_sha256(recipient_binding_digest) AND ops.is_lower_sha256(rendered_sha256) AND ops.is_lower_sha256(rendering_digest) AND (approval_digest IS NULL OR ops.is_lower_sha256(approval_digest)) AND (policy_decision_digest IS NULL OR ops.is_lower_sha256(policy_decision_digest)) AND (approval_receipt_digest IS NULL OR ops.is_lower_sha256(approval_receipt_digest)) AND ops.is_lower_sha256(transition_receipt_digest));
REVOKE ALL ON ops.communication_renderings FROM PUBLIC;
REVOKE ALL ON ops.communication_renderings FROM gurine_workflow_worker;
REVOKE ALL ON ops.communication_renderings FROM gurine_control_api;
REVOKE ALL ON ops.communication_renderings FROM gurine_analysis_worker;
REVOKE ALL ON ops.communication_renderings FROM gurine_public_projector;
REVOKE ALL ON ops.communication_renderings FROM gurine_notification_worker;
REVOKE ALL ON ops.communication_renderings FROM gurine_submission_api;
REVOKE ALL ON ops.communication_renderings FROM gurine_auditor;
GRANT SELECT ON ops.communication_renderings TO gurine_control_api;
GRANT SELECT ON ops.communication_renderings TO gurine_notification_worker;
GRANT SELECT(id, intent_id, rendering_revision, endpoint_id, endpoint_version, channel, locale, template_id, template_revision, variable_set_digest, attachment_manifest_digest, disclosure_class, semantic_payload_digest, recipient_binding_digest, rendered_sha256, rendered_byte_length, transport_content_type, state, state_version, rendering_digest, approval_kind, approval_proposal_id, approval_proposal_version, approval_digest, policy_decision_digest, approval_receipt_digest, transition_receipt_digest, approval_expires_at, expires_at, created_at, approved_at, superseded_at) ON ops.communication_renderings TO gurine_workflow_worker;
GRANT SELECT(id, intent_id, rendering_revision, endpoint_id, endpoint_version, channel, locale, template_id, template_revision, variable_set_digest, attachment_manifest_digest, disclosure_class, semantic_payload_digest, recipient_binding_digest, rendered_sha256, rendered_byte_length, transport_content_type, state, state_version, rendering_digest, approval_kind, approval_proposal_id, approval_proposal_version, approval_digest, policy_decision_digest, approval_receipt_digest, transition_receipt_digest, approval_expires_at, expires_at, created_at, approved_at, superseded_at) ON ops.communication_renderings TO gurine_auditor;
CREATE TRIGGER ops_communication_renderings_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.communication_renderings FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.outbound_delivery_attempts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  delivery_id uuid NOT NULL,
  attempt_ordinal integer NOT NULL,
  dispatch_generation bigint NOT NULL,
  delivery_version_at_claim bigint NOT NULL,
  endpoint_id uuid NOT NULL,
  endpoint_version bigint NOT NULL,
  endpoint_snapshot_digest char(64) NOT NULL,
  provider_config_id uuid NOT NULL,
  provider_config_version bigint NOT NULL,
  configuration_digest char(64) NOT NULL,
  provider_preflight_receipt_id uuid NOT NULL,
  provider_preflight_receipt_digest char(64) NOT NULL,
  budget_reservation_id uuid NOT NULL,
  worker_id text NOT NULL,
  lease_token_hash char(64) NOT NULL,
  fencing_token bigint NOT NULL,
  provider_idempotency_key_sha256 char(64) NOT NULL,
  request_sha256 char(64) NOT NULL,
  rendered_sha256 char(64) NOT NULL,
  authorization_snapshot_digest char(64) NOT NULL,
  suppression_snapshot_digest char(64) NOT NULL,
  activation_receipt_digest char(64) NOT NULL,
  policy_fence_digest char(64) NOT NULL,
  safe_retry_decision_id uuid,
  safe_retry_decision_sequence bigint,
  safe_retry_decision_resulting_state text,
  safe_retry_kind text,
  safe_retry_proof_digest char(64),
  safe_retry_decision_receipt_digest char(64),
  transport_policy_version text NOT NULL,
  deadline_at timestamptz NOT NULL,
  claimed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  lease_expires_at timestamptz NOT NULL,
  attempt_digest char(64) NOT NULL,
  claim_receipt_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL,
  CONSTRAINT g_pk_ops_outbound_delivery_attempts_1 PRIMARY KEY (id)
);
ALTER TABLE ops.outbound_delivery_attempts OWNER TO gurine_migrator;
ALTER TABLE ops.outbound_delivery_attempts ADD CONSTRAINT outbound_delivery_attempt_ordinal_uq UNIQUE (delivery_id, attempt_ordinal);
ALTER TABLE ops.outbound_delivery_attempts ADD CONSTRAINT outbound_delivery_attempt_generation_uq UNIQUE (delivery_id, dispatch_generation);
ALTER TABLE ops.outbound_delivery_attempts ADD CONSTRAINT outbound_delivery_attempt_fence_uq UNIQUE (fencing_token);
ALTER TABLE ops.outbound_delivery_attempts ADD CONSTRAINT outbound_delivery_attempt_digest_uq UNIQUE (attempt_digest);
ALTER TABLE ops.outbound_delivery_attempts ADD CONSTRAINT outbound_delivery_attempt_claim_receipt_uq UNIQUE (claim_receipt_digest);
ALTER TABLE ops.outbound_delivery_attempts ADD CONSTRAINT g_ck_ops_outbound_delivery_attempts_1 CHECK (attempt_ordinal BETWEEN 1 AND 3);
ALTER TABLE ops.outbound_delivery_attempts ADD CONSTRAINT g_ck_ops_outbound_delivery_attempts_2 CHECK (dispatch_generation > 0 AND delivery_version_at_claim > 0 AND endpoint_version > 0 AND provider_config_version > 0 AND fencing_token > 0);
ALTER TABLE ops.outbound_delivery_attempts ADD CONSTRAINT g_ck_ops_outbound_delivery_attempts_3 CHECK (length(worker_id) BETWEEN 1 AND 200 AND length(transport_policy_version) BETWEEN 1 AND 100);
ALTER TABLE ops.outbound_delivery_attempts ADD CONSTRAINT g_ck_ops_outbound_delivery_attempts_4 CHECK (lease_expires_at > claimed_at AND deadline_at >= lease_expires_at);
ALTER TABLE ops.outbound_delivery_attempts ADD CONSTRAINT g_ck_ops_outbound_delivery_attempts_5 CHECK (attempt_ordinal = 1 AND num_nonnulls(safe_retry_decision_id,safe_retry_decision_sequence,safe_retry_decision_resulting_state,safe_retry_kind,safe_retry_proof_digest,safe_retry_decision_receipt_digest) = 0 OR attempt_ordinal > 1 AND num_nonnulls(safe_retry_decision_id,safe_retry_decision_sequence,safe_retry_decision_resulting_state,safe_retry_kind,safe_retry_proof_digest,safe_retry_decision_receipt_digest) = 6);
ALTER TABLE ops.outbound_delivery_attempts ADD CONSTRAINT g_ck_ops_outbound_delivery_attempts_6 CHECK (safe_retry_decision_resulting_state IS NULL OR safe_retry_decision_resulting_state = 'RETRY_SCHEDULED');
ALTER TABLE ops.outbound_delivery_attempts ADD CONSTRAINT g_ck_ops_outbound_delivery_attempts_7 CHECK (safe_retry_kind IS NULL OR safe_retry_kind IN ('NO_PROVIDER_ATTEMPT','PROVIDER_LOOKUP_NOT_FOUND','PROVIDER_IDEMPOTENT_REPLAY_SAFE'));
ALTER TABLE ops.outbound_delivery_attempts ADD CONSTRAINT g_ck_ops_outbound_delivery_attempts_8 CHECK (ops.is_lower_sha256(endpoint_snapshot_digest) AND ops.is_lower_sha256(configuration_digest) AND ops.is_lower_sha256(provider_preflight_receipt_digest) AND ops.is_lower_sha256(lease_token_hash) AND ops.is_lower_sha256(provider_idempotency_key_sha256) AND ops.is_lower_sha256(request_sha256) AND ops.is_lower_sha256(rendered_sha256) AND ops.is_lower_sha256(authorization_snapshot_digest) AND ops.is_lower_sha256(suppression_snapshot_digest) AND ops.is_lower_sha256(activation_receipt_digest) AND ops.is_lower_sha256(policy_fence_digest) AND (safe_retry_proof_digest IS NULL OR ops.is_lower_sha256(safe_retry_proof_digest)) AND (safe_retry_decision_receipt_digest IS NULL OR ops.is_lower_sha256(safe_retry_decision_receipt_digest)) AND ops.is_lower_sha256(attempt_digest) AND ops.is_lower_sha256(claim_receipt_digest));
REVOKE ALL ON ops.outbound_delivery_attempts FROM PUBLIC;
REVOKE ALL ON ops.outbound_delivery_attempts FROM gurine_workflow_worker;
REVOKE ALL ON ops.outbound_delivery_attempts FROM gurine_control_api;
REVOKE ALL ON ops.outbound_delivery_attempts FROM gurine_analysis_worker;
REVOKE ALL ON ops.outbound_delivery_attempts FROM gurine_public_projector;
REVOKE ALL ON ops.outbound_delivery_attempts FROM gurine_notification_worker;
REVOKE ALL ON ops.outbound_delivery_attempts FROM gurine_submission_api;
REVOKE ALL ON ops.outbound_delivery_attempts FROM gurine_auditor;
GRANT SELECT ON ops.outbound_delivery_attempts TO gurine_control_api;
GRANT SELECT ON ops.outbound_delivery_attempts TO gurine_notification_worker;
GRANT SELECT ON ops.outbound_delivery_attempts TO gurine_workflow_worker;
GRANT SELECT ON ops.outbound_delivery_attempts TO gurine_auditor;
CREATE TRIGGER ops_outbound_delivery_attempts_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.outbound_delivery_attempts FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.communication_callback_events (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  provider_preflight_receipt_id uuid NOT NULL,
  provider_config_id uuid NOT NULL,
  provider_config_version bigint NOT NULL,
  provider_configuration_digest char(64) NOT NULL,
  provider_preflight_receipt_digest char(64) NOT NULL,
  integration_id uuid NOT NULL,
  channel text NOT NULL,
  callback_operation_id text NOT NULL,
  callback_request_digest char(64) NOT NULL,
  http_method text NOT NULL,
  request_content_type text NOT NULL,
  request_target_digest char(64) NOT NULL,
  request_header_digest char(64) NOT NULL,
  request_body_sha256 char(64) NOT NULL,
  request_body_length bigint NOT NULL,
  request_body_ciphertext bytea NOT NULL,
  request_encryption_key_id text NOT NULL,
  authentication_method text NOT NULL,
  authentication_evidence jsonb NOT NULL,
  authentication_evidence_digest char(64) NOT NULL,
  provider_request_identity_hmac char(64),
  replay_key_digest char(64) NOT NULL,
  normalized_items jsonb NOT NULL,
  normalized_item_set_digest char(64) NOT NULL,
  item_count integer NOT NULL,
  applied_item_count integer NOT NULL,
  stale_item_count integer NOT NULL,
  unmatched_item_count integer NOT NULL,
  processing_disposition text NOT NULL,
  acknowledgement_http_status smallint NOT NULL,
  acknowledgement_content_type text NOT NULL,
  acknowledgement_headers jsonb NOT NULL,
  acknowledgement_body_ciphertext bytea NOT NULL,
  acknowledgement_body_sha256 char(64) NOT NULL,
  acknowledgement_body_length bigint NOT NULL,
  acknowledgement_encryption_key_id text NOT NULL,
  acknowledgement_digest char(64) NOT NULL,
  verification_receipt_digest char(64) NOT NULL,
  callback_digest char(64) NOT NULL,
  received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  processed_at timestamptz NOT NULL,
  CONSTRAINT g_pk_ops_communication_callback_events_1 PRIMARY KEY (id)
);
ALTER TABLE ops.communication_callback_events OWNER TO gurine_migrator;
ALTER TABLE ops.communication_callback_events ADD CONSTRAINT communication_callback_replay_uq UNIQUE (provider_config_id, replay_key_digest);
ALTER TABLE ops.communication_callback_events ADD CONSTRAINT communication_callback_request_uq UNIQUE (provider_config_id, callback_request_digest);
CREATE UNIQUE INDEX communication_callback_provider_request_uq ON ops.communication_callback_events (provider_config_id, provider_request_identity_hmac) WHERE provider_request_identity_hmac IS NOT NULL;
ALTER TABLE ops.communication_callback_events ADD CONSTRAINT communication_callback_digest_uq UNIQUE (callback_digest);
ALTER TABLE ops.communication_callback_events ADD CONSTRAINT communication_callback_verification_receipt_uq UNIQUE (verification_receipt_digest);
ALTER TABLE ops.communication_callback_events ADD CONSTRAINT g_ck_ops_communication_callback_events_1 CHECK (provider_config_version > 0);
ALTER TABLE ops.communication_callback_events ADD CONSTRAINT g_ck_ops_communication_callback_events_2 CHECK (channel IN ('SMTP_EMAIL','TELEGRAM_BOT_API','META_WHATSAPP_BUSINESS_CLOUD','LINE_MESSAGING_API','SOLAPI_SMS','SOLAPI_KAKAO_BIZMESSAGE','TWILIO_VOICE'));
ALTER TABLE ops.communication_callback_events ADD CONSTRAINT g_ck_ops_communication_callback_events_3 CHECK (callback_operation_id IN ('acceptSmtpDsn','receiveTelegramWebhook','receiveWhatsAppWebhook','receiveLineWebhook','receiveSolapiSmsCallback','receiveSolapiKakaoCallback','receiveTwilioVoiceCallback'));
ALTER TABLE ops.communication_callback_events ADD CONSTRAINT g_ck_ops_communication_callback_events_4 CHECK (authentication_method IN ('GURINE_MTA_ASSERTION','TELEGRAM_SECRET_TOKEN','META_HMAC_SHA256','LINE_HMAC_SHA256','SOLAPI_SIGNATURE','TWILIO_SIGNATURE'));
ALTER TABLE ops.communication_callback_events ADD CONSTRAINT g_ck_ops_communication_callback_events_5 CHECK (channel = 'SMTP_EMAIL' AND callback_operation_id = 'acceptSmtpDsn' AND authentication_method = 'GURINE_MTA_ASSERTION' OR channel = 'TELEGRAM_BOT_API' AND callback_operation_id = 'receiveTelegramWebhook' AND authentication_method = 'TELEGRAM_SECRET_TOKEN' OR channel = 'META_WHATSAPP_BUSINESS_CLOUD' AND callback_operation_id = 'receiveWhatsAppWebhook' AND authentication_method = 'META_HMAC_SHA256' OR channel = 'LINE_MESSAGING_API' AND callback_operation_id = 'receiveLineWebhook' AND authentication_method = 'LINE_HMAC_SHA256' OR channel = 'SOLAPI_SMS' AND callback_operation_id = 'receiveSolapiSmsCallback' AND authentication_method = 'SOLAPI_SIGNATURE' OR channel = 'SOLAPI_KAKAO_BIZMESSAGE' AND callback_operation_id = 'receiveSolapiKakaoCallback' AND authentication_method = 'SOLAPI_SIGNATURE' OR channel = 'TWILIO_VOICE' AND callback_operation_id = 'receiveTwilioVoiceCallback' AND authentication_method = 'TWILIO_SIGNATURE');
ALTER TABLE ops.communication_callback_events ADD CONSTRAINT g_ck_ops_communication_callback_events_6 CHECK (http_method = 'POST');
ALTER TABLE ops.communication_callback_events ADD CONSTRAINT g_ck_ops_communication_callback_events_7 CHECK (callback_operation_id = 'acceptSmtpDsn' AND request_content_type = 'multipart/report; report-type=delivery-status' OR callback_operation_id IN ('receiveTelegramWebhook','receiveWhatsAppWebhook','receiveLineWebhook','receiveSolapiSmsCallback','receiveSolapiKakaoCallback') AND request_content_type = 'application/json' OR callback_operation_id = 'receiveTwilioVoiceCallback' AND request_content_type = 'application/x-www-form-urlencoded');
ALTER TABLE ops.communication_callback_events ADD CONSTRAINT g_ck_ops_communication_callback_events_8 CHECK (processing_disposition IN ('AUTHENTICATED_APPLIED','AUTHENTICATED_PARTIAL','AUTHENTICATED_STALE','AUTHENTICATED_UNMATCHED','AUTHENTICATED_PARSE_FAILED'));
ALTER TABLE ops.communication_callback_events ADD CONSTRAINT g_ck_ops_communication_callback_events_9 CHECK (callback_operation_id = 'acceptSmtpDsn' AND request_body_length BETWEEN 1 AND 10485760 OR callback_operation_id IN ('receiveTelegramWebhook','receiveWhatsAppWebhook','receiveLineWebhook','receiveSolapiSmsCallback','receiveSolapiKakaoCallback') AND request_body_length BETWEEN 2 AND 2097152 OR callback_operation_id = 'receiveTwilioVoiceCallback' AND request_body_length BETWEEN 1 AND 262144);
ALTER TABLE ops.communication_callback_events ADD CONSTRAINT g_ck_ops_communication_callback_events_10 CHECK (octet_length(request_body_ciphertext) >= request_body_length AND octet_length(request_body_ciphertext) <= request_body_length + 65536);
ALTER TABLE ops.communication_callback_events ADD CONSTRAINT g_ck_ops_communication_callback_events_11 CHECK (length(request_encryption_key_id) BETWEEN 1 AND 200 AND length(acknowledgement_encryption_key_id) BETWEEN 1 AND 200);
ALTER TABLE ops.communication_callback_events ADD CONSTRAINT g_ck_ops_communication_callback_events_12 CHECK (item_count BETWEEN 0 AND 1000 AND applied_item_count BETWEEN 0 AND item_count AND stale_item_count BETWEEN 0 AND item_count AND unmatched_item_count BETWEEN 0 AND item_count);
ALTER TABLE ops.communication_callback_events ADD CONSTRAINT g_ck_ops_communication_callback_events_13 CHECK (applied_item_count + stale_item_count + unmatched_item_count = item_count);
ALTER TABLE ops.communication_callback_events ADD CONSTRAINT g_ck_ops_communication_callback_events_14 CHECK (processing_disposition = 'AUTHENTICATED_PARSE_FAILED' AND item_count = 0 OR processing_disposition <> 'AUTHENTICATED_PARSE_FAILED' AND item_count > 0);
ALTER TABLE ops.communication_callback_events ADD CONSTRAINT g_ck_ops_communication_callback_events_15 CHECK (processing_disposition = 'AUTHENTICATED_PARSE_FAILED' OR callback_operation_id IN ('acceptSmtpDsn','receiveTelegramWebhook','receiveSolapiSmsCallback','receiveSolapiKakaoCallback','receiveTwilioVoiceCallback') AND item_count = 1 OR callback_operation_id IN ('receiveWhatsAppWebhook','receiveLineWebhook') AND item_count BETWEEN 1 AND 1000);
ALTER TABLE ops.communication_callback_events ADD CONSTRAINT g_ck_ops_communication_callback_events_16 CHECK (processing_disposition = 'AUTHENTICATED_APPLIED' AND applied_item_count = item_count OR processing_disposition = 'AUTHENTICATED_PARTIAL' AND applied_item_count > 0 AND applied_item_count < item_count OR processing_disposition = 'AUTHENTICATED_STALE' AND stale_item_count = item_count OR processing_disposition = 'AUTHENTICATED_UNMATCHED' AND unmatched_item_count = item_count OR processing_disposition = 'AUTHENTICATED_PARSE_FAILED');
ALTER TABLE ops.communication_callback_events ADD CONSTRAINT g_ck_ops_communication_callback_events_17 CHECK (acknowledgement_http_status BETWEEN 200 AND 599 AND acknowledgement_body_length BETWEEN 0 AND 1048576 AND octet_length(acknowledgement_body_ciphertext) >= acknowledgement_body_length);
ALTER TABLE ops.communication_callback_events ADD CONSTRAINT g_ck_ops_communication_callback_events_18 CHECK (length(acknowledgement_content_type) BETWEEN 1 AND 200);
ALTER TABLE ops.communication_callback_events ADD CONSTRAINT g_ck_ops_communication_callback_events_19 CHECK (ops.communication_callback_auth_evidence_is_valid(authentication_evidence, authentication_method, authentication_evidence_digest));
ALTER TABLE ops.communication_callback_events ADD CONSTRAINT g_ck_ops_communication_callback_events_20 CHECK (ops.communication_callback_items_are_valid(normalized_items, item_count, normalized_item_set_digest));
ALTER TABLE ops.communication_callback_events ADD CONSTRAINT g_ck_ops_communication_callback_events_21 CHECK (processed_at >= received_at);
ALTER TABLE ops.communication_callback_events ADD CONSTRAINT g_ck_ops_communication_callback_events_22 CHECK (ops.is_lower_sha256(provider_configuration_digest) AND ops.is_lower_sha256(provider_preflight_receipt_digest) AND ops.is_lower_sha256(callback_request_digest) AND ops.is_lower_sha256(request_target_digest) AND ops.is_lower_sha256(request_header_digest) AND ops.is_lower_sha256(request_body_sha256) AND ops.is_lower_sha256(authentication_evidence_digest) AND (provider_request_identity_hmac IS NULL OR ops.is_lower_sha256(provider_request_identity_hmac)) AND ops.is_lower_sha256(replay_key_digest) AND ops.is_lower_sha256(normalized_item_set_digest) AND ops.is_lower_sha256(acknowledgement_body_sha256) AND ops.is_lower_sha256(acknowledgement_digest) AND ops.is_lower_sha256(verification_receipt_digest) AND ops.is_lower_sha256(callback_digest));
REVOKE ALL ON ops.communication_callback_events FROM PUBLIC;
REVOKE ALL ON ops.communication_callback_events FROM gurine_workflow_worker;
REVOKE ALL ON ops.communication_callback_events FROM gurine_control_api;
REVOKE ALL ON ops.communication_callback_events FROM gurine_analysis_worker;
REVOKE ALL ON ops.communication_callback_events FROM gurine_public_projector;
REVOKE ALL ON ops.communication_callback_events FROM gurine_notification_worker;
REVOKE ALL ON ops.communication_callback_events FROM gurine_submission_api;
REVOKE ALL ON ops.communication_callback_events FROM gurine_auditor;
GRANT SELECT(id, provider_preflight_receipt_id, provider_config_id, provider_config_version, provider_configuration_digest, provider_preflight_receipt_digest, integration_id, channel, callback_operation_id, callback_request_digest, http_method, request_content_type, request_target_digest, request_header_digest, request_body_sha256, request_body_length, authentication_method, authentication_evidence_digest, provider_request_identity_hmac, replay_key_digest, normalized_items, normalized_item_set_digest, item_count, applied_item_count, stale_item_count, unmatched_item_count, processing_disposition, acknowledgement_http_status, acknowledgement_content_type, acknowledgement_headers, acknowledgement_body_sha256, acknowledgement_body_length, acknowledgement_digest, verification_receipt_digest, callback_digest, received_at, processed_at) ON ops.communication_callback_events TO gurine_control_api;
GRANT SELECT ON ops.communication_callback_events TO gurine_notification_worker;
GRANT SELECT(id, provider_preflight_receipt_id, provider_config_id, provider_config_version, provider_configuration_digest, provider_preflight_receipt_digest, integration_id, channel, callback_operation_id, callback_request_digest, request_content_type, request_body_sha256, request_body_length, normalized_items, normalized_item_set_digest, item_count, applied_item_count, stale_item_count, unmatched_item_count, processing_disposition, acknowledgement_digest, verification_receipt_digest, callback_digest, received_at, processed_at) ON ops.communication_callback_events TO gurine_workflow_worker;
GRANT SELECT(id, provider_preflight_receipt_id, provider_config_id, provider_config_version, provider_configuration_digest, provider_preflight_receipt_digest, integration_id, channel, callback_operation_id, callback_request_digest, http_method, request_content_type, request_target_digest, request_header_digest, request_body_sha256, request_body_length, authentication_method, authentication_evidence_digest, provider_request_identity_hmac, replay_key_digest, normalized_item_set_digest, item_count, applied_item_count, stale_item_count, unmatched_item_count, processing_disposition, acknowledgement_http_status, acknowledgement_content_type, acknowledgement_body_sha256, acknowledgement_body_length, acknowledgement_digest, verification_receipt_digest, callback_digest, received_at, processed_at) ON ops.communication_callback_events TO gurine_auditor;
CREATE TRIGGER ops_communication_callback_events_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.communication_callback_events FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.communication_reconciliation_decisions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  delivery_id uuid NOT NULL,
  decision_sequence bigint NOT NULL,
  expected_delivery_version bigint NOT NULL,
  prior_state text NOT NULL,
  resolution text NOT NULL,
  resulting_state text NOT NULL,
  evidence_kind text NOT NULL,
  evidence jsonb NOT NULL,
  evidence_digest char(64) NOT NULL,
  safe_retry_kind text,
  safe_retry_proof jsonb,
  safe_retry_proof_digest char(64),
  safe_retry_pre_egress_receipt_id uuid,
  safe_retry_pre_egress_receipt_sequence bigint,
  safe_retry_pre_egress_receipt_digest char(64),
  safe_retry_pre_egress_evidence_kind text,
  safe_retry_pre_egress_applied boolean,
  provider_lookup_receipt_id uuid,
  provider_lookup_receipt_delivery_id uuid,
  provider_lookup_receipt_sequence bigint,
  provider_lookup_receipt_digest char(64),
  provider_lookup_receipt_evidence_kind text,
  provider_lookup_receipt_applied boolean,
  safe_retry_provider_preflight_receipt_id uuid,
  safe_retry_provider_config_id uuid,
  safe_retry_provider_config_version bigint,
  safe_retry_provider_configuration_digest char(64),
  safe_retry_provider_preflight_receipt_digest char(64),
  safe_retry_provider_idempotency_key_sha256 char(64),
  safe_retry_request_sha256 char(64),
  callback_event_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
  attempt_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
  actor_id uuid NOT NULL,
  capability text NOT NULL,
  assurance text NOT NULL,
  assurance_receipt_digest char(64) NOT NULL,
  reason_code text NOT NULL,
  reason text NOT NULL,
  idempotency_key_hash char(64) NOT NULL,
  request_digest char(64) NOT NULL,
  request_id uuid NOT NULL,
  trace_id text NOT NULL,
  decision_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL,
  outbox_event_id uuid NOT NULL,
  receipt_digest char(64) NOT NULL,
  decided_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_ops_communication_reconciliation_decisions_1 PRIMARY KEY (id)
);
ALTER TABLE ops.communication_reconciliation_decisions OWNER TO gurine_migrator;
ALTER TABLE ops.communication_reconciliation_decisions ADD CONSTRAINT communication_reconciliation_sequence_uq UNIQUE (delivery_id, decision_sequence);
ALTER TABLE ops.communication_reconciliation_decisions ADD CONSTRAINT communication_reconciliation_expected_version_uq UNIQUE (delivery_id, expected_delivery_version);
ALTER TABLE ops.communication_reconciliation_decisions ADD CONSTRAINT communication_reconciliation_idempotency_uq UNIQUE (idempotency_key_hash);
ALTER TABLE ops.communication_reconciliation_decisions ADD CONSTRAINT communication_reconciliation_decision_digest_uq UNIQUE (decision_digest);
ALTER TABLE ops.communication_reconciliation_decisions ADD CONSTRAINT communication_reconciliation_receipt_digest_uq UNIQUE (receipt_digest);
ALTER TABLE ops.communication_reconciliation_decisions ADD CONSTRAINT communication_reconciliation_safe_retry_authority_uq UNIQUE (id, delivery_id, decision_sequence, resulting_state, safe_retry_kind, safe_retry_proof_digest, receipt_digest);
ALTER TABLE ops.communication_reconciliation_decisions ADD CONSTRAINT g_ck_ops_communication_reconciliation_decisions_1 CHECK (decision_sequence > 0 AND expected_delivery_version > 0);
ALTER TABLE ops.communication_reconciliation_decisions ADD CONSTRAINT g_ck_ops_communication_reconciliation_decisions_2 CHECK (prior_state = 'RECONCILIATION_REQUIRED');
ALTER TABLE ops.communication_reconciliation_decisions ADD CONSTRAINT g_ck_ops_communication_reconciliation_decisions_3 CHECK (resolution IN ('NOT_TRANSMITTED','PROVIDER_ACCEPTED','DELIVERED','FAILED_PERMANENT'));
ALTER TABLE ops.communication_reconciliation_decisions ADD CONSTRAINT g_ck_ops_communication_reconciliation_decisions_4 CHECK (resulting_state IN ('RETRY_SCHEDULED','CANCELLED','PROVIDER_ACCEPTED','DELIVERED','FAILED_PERMANENT'));
ALTER TABLE ops.communication_reconciliation_decisions ADD CONSTRAINT g_ck_ops_communication_reconciliation_decisions_5 CHECK (evidence_kind IN ('NO_PROVIDER_ATTEMPT','AUTHENTICATED_PROVIDER_LOOKUP','SIGNED_PROVIDER_CALLBACK','AUTHENTICATED_PROVIDER_POLL','OFFICIAL_CHANNEL_RECEIPT'));
ALTER TABLE ops.communication_reconciliation_decisions ADD CONSTRAINT g_ck_ops_communication_reconciliation_decisions_6 CHECK (resolution = 'NOT_TRANSMITTED' AND resulting_state IN ('RETRY_SCHEDULED','CANCELLED') AND safe_retry_kind IS NOT NULL AND safe_retry_proof IS NOT NULL AND safe_retry_proof_digest IS NOT NULL OR resolution = 'PROVIDER_ACCEPTED' AND resulting_state = 'PROVIDER_ACCEPTED' AND safe_retry_kind IS NULL AND safe_retry_proof IS NULL AND safe_retry_proof_digest IS NULL OR resolution = 'DELIVERED' AND resulting_state = 'DELIVERED' AND safe_retry_kind IS NULL AND safe_retry_proof IS NULL AND safe_retry_proof_digest IS NULL OR resolution = 'FAILED_PERMANENT' AND resulting_state = 'FAILED_PERMANENT' AND safe_retry_kind IS NULL AND safe_retry_proof IS NULL AND safe_retry_proof_digest IS NULL);
ALTER TABLE ops.communication_reconciliation_decisions ADD CONSTRAINT g_ck_ops_communication_reconciliation_decisions_7 CHECK (safe_retry_kind IS NULL OR safe_retry_kind IN ('NO_PROVIDER_ATTEMPT','PROVIDER_LOOKUP_NOT_FOUND','PROVIDER_IDEMPOTENT_REPLAY_SAFE'));
ALTER TABLE ops.communication_reconciliation_decisions ADD CONSTRAINT g_ck_ops_communication_reconciliation_decisions_8 CHECK (safe_retry_kind IS NULL OR ops.communication_safe_retry_proof_is_valid(safe_retry_proof,safe_retry_kind,safe_retry_proof_digest));
ALTER TABLE ops.communication_reconciliation_decisions ADD CONSTRAINT g_ck_ops_communication_reconciliation_decisions_9 CHECK (safe_retry_kind = 'NO_PROVIDER_ATTEMPT' AND num_nonnulls(safe_retry_pre_egress_receipt_id,safe_retry_pre_egress_receipt_sequence,safe_retry_pre_egress_receipt_digest,safe_retry_pre_egress_evidence_kind,safe_retry_pre_egress_applied) = 5 AND safe_retry_pre_egress_evidence_kind = 'PRE_DISPATCH_FENCE' AND safe_retry_pre_egress_applied AND num_nonnulls(provider_lookup_receipt_id,provider_lookup_receipt_delivery_id,provider_lookup_receipt_sequence,provider_lookup_receipt_digest,provider_lookup_receipt_evidence_kind,provider_lookup_receipt_applied,safe_retry_provider_preflight_receipt_id) = 0 OR safe_retry_kind = 'PROVIDER_LOOKUP_NOT_FOUND' AND num_nonnulls(provider_lookup_receipt_id,provider_lookup_receipt_delivery_id,provider_lookup_receipt_sequence,provider_lookup_receipt_digest,provider_lookup_receipt_evidence_kind,provider_lookup_receipt_applied,safe_retry_provider_idempotency_key_sha256,safe_retry_request_sha256) = 8 AND provider_lookup_receipt_evidence_kind = 'AUTHENTICATED_PROVIDER_POLL' AND provider_lookup_receipt_applied = false AND safe_retry_pre_egress_receipt_id IS NULL AND safe_retry_provider_preflight_receipt_id IS NULL OR safe_retry_kind = 'PROVIDER_IDEMPOTENT_REPLAY_SAFE' AND num_nonnulls(provider_lookup_receipt_id,provider_lookup_receipt_delivery_id,provider_lookup_receipt_sequence,provider_lookup_receipt_digest,provider_lookup_receipt_evidence_kind,provider_lookup_receipt_applied,safe_retry_provider_preflight_receipt_id,safe_retry_provider_config_id,safe_retry_provider_config_version,safe_retry_provider_configuration_digest,safe_retry_provider_preflight_receipt_digest,safe_retry_provider_idempotency_key_sha256,safe_retry_request_sha256) = 13 AND provider_lookup_receipt_evidence_kind = 'AUTHENTICATED_PROVIDER_POLL' AND provider_lookup_receipt_applied = false AND safe_retry_pre_egress_receipt_id IS NULL OR safe_retry_kind IS NULL AND num_nonnulls(safe_retry_pre_egress_receipt_id,safe_retry_pre_egress_receipt_sequence,safe_retry_pre_egress_receipt_digest,safe_retry_pre_egress_evidence_kind,safe_retry_pre_egress_applied,provider_lookup_receipt_id,provider_lookup_receipt_delivery_id,provider_lookup_receipt_sequence,provider_lookup_receipt_digest,provider_lookup_receipt_evidence_kind,provider_lookup_receipt_applied,safe_retry_provider_preflight_receipt_id,safe_retry_provider_config_id,safe_retry_provider_config_version,safe_retry_provider_configuration_digest,safe_retry_provider_preflight_receipt_digest,safe_retry_provider_idempotency_key_sha256,safe_retry_request_sha256) = 0);
ALTER TABLE ops.communication_reconciliation_decisions ADD CONSTRAINT g_ck_ops_communication_reconciliation_decisions_10 CHECK (resolution <> 'DELIVERED' OR evidence->>'kind' IN ('SIGNED_PROVIDER_CALLBACK','AUTHENTICATED_PROVIDER_POLL','OFFICIAL_CHANNEL_RECEIPT'));
ALTER TABLE ops.communication_reconciliation_decisions ADD CONSTRAINT g_ck_ops_communication_reconciliation_decisions_11 CHECK (num_nonnulls(provider_lookup_receipt_id,provider_lookup_receipt_delivery_id,provider_lookup_receipt_sequence,provider_lookup_receipt_digest,provider_lookup_receipt_evidence_kind,provider_lookup_receipt_applied) IN (0,6));
ALTER TABLE ops.communication_reconciliation_decisions ADD CONSTRAINT g_ck_ops_communication_reconciliation_decisions_12 CHECK (capability = 'communications.operate' AND assurance = 'STEP_UP');
ALTER TABLE ops.communication_reconciliation_decisions ADD CONSTRAINT g_ck_ops_communication_reconciliation_decisions_13 CHECK (length(reason_code) BETWEEN 1 AND 100 AND length(reason) BETWEEN 1 AND 4000 AND length(trace_id) BETWEEN 1 AND 200);
ALTER TABLE ops.communication_reconciliation_decisions ADD CONSTRAINT g_ck_ops_communication_reconciliation_decisions_14 CHECK (ops.uuid_array_is_unique(callback_event_ids) AND ops.uuid_array_is_unique(attempt_ids));
ALTER TABLE ops.communication_reconciliation_decisions ADD CONSTRAINT g_ck_ops_communication_reconciliation_decisions_15 CHECK (cardinality(callback_event_ids) + cardinality(attempt_ids) > 0);
ALTER TABLE ops.communication_reconciliation_decisions ADD CONSTRAINT g_ck_ops_communication_reconciliation_decisions_16 CHECK (ops.is_lower_sha256(evidence_digest) AND (safe_retry_proof_digest IS NULL OR ops.is_lower_sha256(safe_retry_proof_digest)) AND (safe_retry_pre_egress_receipt_digest IS NULL OR ops.is_lower_sha256(safe_retry_pre_egress_receipt_digest)) AND (provider_lookup_receipt_digest IS NULL OR ops.is_lower_sha256(provider_lookup_receipt_digest)) AND (safe_retry_provider_configuration_digest IS NULL OR ops.is_lower_sha256(safe_retry_provider_configuration_digest)) AND (safe_retry_provider_preflight_receipt_digest IS NULL OR ops.is_lower_sha256(safe_retry_provider_preflight_receipt_digest)) AND (safe_retry_provider_idempotency_key_sha256 IS NULL OR ops.is_lower_sha256(safe_retry_provider_idempotency_key_sha256)) AND (safe_retry_request_sha256 IS NULL OR ops.is_lower_sha256(safe_retry_request_sha256)) AND ops.is_lower_sha256(assurance_receipt_digest) AND ops.is_lower_sha256(idempotency_key_hash) AND ops.is_lower_sha256(request_digest) AND ops.is_lower_sha256(decision_digest) AND ops.is_lower_sha256(receipt_digest));
REVOKE ALL ON ops.communication_reconciliation_decisions FROM PUBLIC;
REVOKE ALL ON ops.communication_reconciliation_decisions FROM gurine_workflow_worker;
REVOKE ALL ON ops.communication_reconciliation_decisions FROM gurine_control_api;
REVOKE ALL ON ops.communication_reconciliation_decisions FROM gurine_analysis_worker;
REVOKE ALL ON ops.communication_reconciliation_decisions FROM gurine_public_projector;
REVOKE ALL ON ops.communication_reconciliation_decisions FROM gurine_notification_worker;
REVOKE ALL ON ops.communication_reconciliation_decisions FROM gurine_submission_api;
REVOKE ALL ON ops.communication_reconciliation_decisions FROM gurine_auditor;
GRANT SELECT ON ops.communication_reconciliation_decisions TO gurine_control_api;
GRANT SELECT ON ops.communication_reconciliation_decisions TO gurine_notification_worker;
GRANT SELECT ON ops.communication_reconciliation_decisions TO gurine_workflow_worker;
GRANT SELECT ON ops.communication_reconciliation_decisions TO gurine_auditor;
CREATE TRIGGER ops_communication_reconciliation_decisions_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.communication_reconciliation_decisions FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.outbound_delivery_receipts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  delivery_id uuid NOT NULL,
  receipt_sequence bigint NOT NULL,
  event_aggregate_version bigint,
  prior_delivery_version bigint NOT NULL,
  delivery_version bigint NOT NULL,
  attempt_id uuid,
  callback_event_id uuid,
  callback_item_ordinal integer,
  callback_item_digest char(64),
  reconciliation_decision_id uuid,
  source_kind text NOT NULL,
  observation_key_digest char(64) NOT NULL,
  projection_disposition text NOT NULL,
  evidence_kind text NOT NULL,
  evidence_rank smallint NOT NULL,
  prior_state text NOT NULL,
  asserted_state text NOT NULL,
  resulting_state text NOT NULL,
  prior_proof_level text NOT NULL,
  resulting_proof_level text NOT NULL,
  applied boolean NOT NULL,
  provider_event_identity_hash char(64),
  provider_evidence_digest char(64) NOT NULL,
  rendering_digest char(64) NOT NULL,
  endpoint_id uuid NOT NULL,
  endpoint_version bigint NOT NULL,
  endpoint_snapshot_digest char(64) NOT NULL,
  endpoint_identity_hash char(64) NOT NULL,
  provider_preflight_receipt_id uuid NOT NULL,
  provider_config_id uuid NOT NULL,
  provider_config_version bigint NOT NULL,
  provider_configuration_digest char(64) NOT NULL,
  provider_preflight_receipt_digest char(64) NOT NULL,
  provider_identity_hash char(64) NOT NULL,
  authorization_snapshot_digest char(64) NOT NULL,
  activation_receipt_digest char(64) NOT NULL,
  budget_reservation_id uuid NOT NULL,
  cost_fact_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
  provider_occurred_at timestamptz,
  observed_at timestamptz NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  actor_type text NOT NULL,
  actor_id uuid,
  request_id uuid NOT NULL,
  trace_id text NOT NULL,
  previous_receipt_digest char(64),
  receipt_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL,
  outbox_event_id uuid,
  CONSTRAINT g_pk_ops_outbound_delivery_receipts_1 PRIMARY KEY (id)
);
ALTER TABLE ops.outbound_delivery_receipts OWNER TO gurine_migrator;
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT outbound_delivery_receipt_sequence_uq UNIQUE (delivery_id, receipt_sequence);
CREATE UNIQUE INDEX outbound_delivery_receipt_event_version_uq ON ops.outbound_delivery_receipts (delivery_id, event_aggregate_version) WHERE event_aggregate_version IS NOT NULL;
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT outbound_delivery_observation_uq UNIQUE (delivery_id, observation_key_digest);
CREATE UNIQUE INDEX outbound_delivery_applied_version_uq ON ops.outbound_delivery_receipts (delivery_id, delivery_version) WHERE applied;
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT outbound_delivery_receipt_digest_uq UNIQUE (receipt_digest);
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT outbound_delivery_receipt_exact_binding_uq UNIQUE (id, delivery_id, receipt_sequence, receipt_digest, resulting_state, applied);
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT outbound_delivery_receipt_safe_retry_evidence_uq UNIQUE (id, delivery_id, receipt_sequence, receipt_digest, evidence_kind, applied);
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT outbound_delivery_receipt_paid_terminal_uq UNIQUE (id, delivery_id, receipt_sequence, receipt_digest, resulting_state, applied, projection_disposition, resulting_proof_level, observed_at);
CREATE UNIQUE INDEX outbound_delivery_callback_item_receipt_uq ON ops.outbound_delivery_receipts (callback_event_id, callback_item_ordinal) WHERE callback_event_id IS NOT NULL;
CREATE UNIQUE INDEX outbound_delivery_reconciliation_receipt_uq ON ops.outbound_delivery_receipts (reconciliation_decision_id) WHERE reconciliation_decision_id IS NOT NULL;
CREATE UNIQUE INDEX outbound_delivery_receipt_outbox_uq ON ops.outbound_delivery_receipts (outbox_event_id) WHERE outbox_event_id IS NOT NULL;
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_ck_ops_outbound_delivery_receipts_1 CHECK (receipt_sequence > 0 AND (event_aggregate_version IS NULL OR event_aggregate_version > 1) AND prior_delivery_version > 0 AND delivery_version > 0 AND endpoint_version > 0 AND provider_config_version > 0);
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_ck_ops_outbound_delivery_receipts_2 CHECK (evidence_kind IN ('PRE_DISPATCH_FENCE','PROVIDER_REQUEST_COMMITTED','PROVIDER_RESPONSE','SIGNED_PROVIDER_CALLBACK','AUTHENTICATED_PROVIDER_POLL','OFFICIAL_CHANNEL_RECEIPT','RECONCILIATION_PROOF','CANCELLATION_PROOF'));
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_ck_ops_outbound_delivery_receipts_3 CHECK (prior_state IN ('QUEUED','SENDING','PROVIDER_ACCEPTED','DELIVERED','READ','RETRY_SCHEDULED','FAILED_PERMANENT','RECONCILIATION_REQUIRED','SUPPRESSED','CANCELLED'));
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_ck_ops_outbound_delivery_receipts_4 CHECK (asserted_state IN ('QUEUED','SENDING','PROVIDER_ACCEPTED','DELIVERED','READ','RETRY_SCHEDULED','FAILED_PERMANENT','RECONCILIATION_REQUIRED','SUPPRESSED','CANCELLED'));
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_ck_ops_outbound_delivery_receipts_5 CHECK (resulting_state IN ('QUEUED','SENDING','PROVIDER_ACCEPTED','DELIVERED','READ','RETRY_SCHEDULED','FAILED_PERMANENT','RECONCILIATION_REQUIRED','SUPPRESSED','CANCELLED'));
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_ck_ops_outbound_delivery_receipts_6 CHECK (evidence_rank BETWEEN 0 AND 100);
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_ck_ops_outbound_delivery_receipts_7 CHECK (source_kind IN ('DISPATCH_FENCE','PROVIDER_RESPONSE','PROVIDER_CALLBACK','PROVIDER_POLL','RECONCILIATION_DECISION','CANCELLATION','SUPPRESSION'));
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_ck_ops_outbound_delivery_receipts_8 CHECK (projection_disposition IN ('APPLIED','STALE_STORED'));
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_ck_ops_outbound_delivery_receipts_9 CHECK (prior_proof_level IN ('NONE','PROVIDER_ACCEPTED','DELIVERED','READ') AND resulting_proof_level IN ('NONE','PROVIDER_ACCEPTED','DELIVERED','READ'));
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_ck_ops_outbound_delivery_receipts_10 CHECK (cardinality(cost_fact_ids) <= 100 AND ops.uuid_array_is_unique(cost_fact_ids));
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_ck_ops_outbound_delivery_receipts_11 CHECK (recorded_at >= observed_at);
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_ck_ops_outbound_delivery_receipts_12 CHECK (applied AND resulting_state = asserted_state OR NOT applied AND resulting_state = prior_state);
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_ck_ops_outbound_delivery_receipts_13 CHECK (applied AND projection_disposition = 'APPLIED' AND delivery_version = prior_delivery_version + 1 OR NOT applied AND projection_disposition = 'STALE_STORED' AND delivery_version = prior_delivery_version);
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_ck_ops_outbound_delivery_receipts_14 CHECK (applied AND event_aggregate_version IS NOT NULL AND outbox_event_id IS NOT NULL OR NOT applied AND event_aggregate_version IS NULL AND outbox_event_id IS NULL);
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_ck_ops_outbound_delivery_receipts_15 CHECK (applied AND ops.delivery_proof_rank(resulting_proof_level) >= ops.delivery_proof_rank(prior_proof_level) OR NOT applied AND resulting_proof_level = prior_proof_level);
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_ck_ops_outbound_delivery_receipts_16 CHECK (receipt_sequence = 1 AND previous_receipt_digest IS NULL OR receipt_sequence > 1 AND previous_receipt_digest IS NOT NULL);
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_ck_ops_outbound_delivery_receipts_17 CHECK (actor_type IN ('AUTHORIZED_SERVICE','HUMAN_USER','PROVIDER_CALLBACK'));
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_ck_ops_outbound_delivery_receipts_18 CHECK (actor_type = 'HUMAN_USER' AND actor_id IS NOT NULL OR actor_type <> 'HUMAN_USER' AND actor_id IS NULL);
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_ck_ops_outbound_delivery_receipts_19 CHECK (length(trace_id) BETWEEN 1 AND 200);
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_ck_ops_outbound_delivery_receipts_20 CHECK (source_kind = 'PROVIDER_CALLBACK' AND callback_event_id IS NOT NULL OR source_kind <> 'PROVIDER_CALLBACK');
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_ck_ops_outbound_delivery_receipts_21 CHECK (source_kind = 'PROVIDER_CALLBACK' AND callback_item_ordinal IS NOT NULL AND callback_item_ordinal >= 0 AND callback_item_digest IS NOT NULL OR source_kind <> 'PROVIDER_CALLBACK' AND callback_item_ordinal IS NULL AND callback_item_digest IS NULL);
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_ck_ops_outbound_delivery_receipts_22 CHECK (source_kind = 'RECONCILIATION_DECISION' AND reconciliation_decision_id IS NOT NULL OR source_kind <> 'RECONCILIATION_DECISION');
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_ck_ops_outbound_delivery_receipts_23 CHECK (source_kind IN ('PROVIDER_RESPONSE','DISPATCH_FENCE') AND attempt_id IS NOT NULL OR source_kind NOT IN ('PROVIDER_RESPONSE','DISPATCH_FENCE'));
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_ck_ops_outbound_delivery_receipts_24 CHECK (resulting_state <> 'READ' OR evidence_kind IN ('SIGNED_PROVIDER_CALLBACK','AUTHENTICATED_PROVIDER_POLL'));
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_ck_ops_outbound_delivery_receipts_25 CHECK (ops.is_lower_sha256(observation_key_digest) AND (callback_item_digest IS NULL OR ops.is_lower_sha256(callback_item_digest)) AND (provider_event_identity_hash IS NULL OR ops.is_lower_sha256(provider_event_identity_hash)) AND ops.is_lower_sha256(provider_evidence_digest) AND ops.is_lower_sha256(rendering_digest) AND ops.is_lower_sha256(endpoint_snapshot_digest) AND ops.is_lower_sha256(endpoint_identity_hash) AND ops.is_lower_sha256(provider_configuration_digest) AND ops.is_lower_sha256(provider_preflight_receipt_digest) AND ops.is_lower_sha256(provider_identity_hash) AND ops.is_lower_sha256(authorization_snapshot_digest) AND ops.is_lower_sha256(activation_receipt_digest) AND (previous_receipt_digest IS NULL OR ops.is_lower_sha256(previous_receipt_digest)) AND ops.is_lower_sha256(receipt_digest));
REVOKE ALL ON ops.outbound_delivery_receipts FROM PUBLIC;
REVOKE ALL ON ops.outbound_delivery_receipts FROM gurine_workflow_worker;
REVOKE ALL ON ops.outbound_delivery_receipts FROM gurine_control_api;
REVOKE ALL ON ops.outbound_delivery_receipts FROM gurine_analysis_worker;
REVOKE ALL ON ops.outbound_delivery_receipts FROM gurine_public_projector;
REVOKE ALL ON ops.outbound_delivery_receipts FROM gurine_notification_worker;
REVOKE ALL ON ops.outbound_delivery_receipts FROM gurine_submission_api;
REVOKE ALL ON ops.outbound_delivery_receipts FROM gurine_auditor;
GRANT SELECT ON ops.outbound_delivery_receipts TO gurine_control_api;
GRANT SELECT ON ops.outbound_delivery_receipts TO gurine_notification_worker;
GRANT SELECT ON ops.outbound_delivery_receipts TO gurine_workflow_worker;
GRANT SELECT ON ops.outbound_delivery_receipts TO gurine_auditor;
CREATE TRIGGER ops_outbound_delivery_receipts_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.outbound_delivery_receipts FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE editorial.response_request_sent_receipts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  source_event_id uuid NOT NULL,
  source_event_envelope_digest char(64) NOT NULL,
  response_request_id uuid NOT NULL,
  prior_request_version bigint NOT NULL,
  request_version bigint NOT NULL,
  response_request_binding_digest char(64) NOT NULL,
  scope_digest char(64) NOT NULL,
  prior_state text NOT NULL DEFAULT 'DRAFT',
  state text NOT NULL DEFAULT 'SENT',
  communication_intent_id uuid NOT NULL,
  communication_intent_digest char(64) NOT NULL,
  rendering_id uuid NOT NULL,
  rendering_digest char(64) NOT NULL,
  rendered_sha256 char(64) NOT NULL,
  response_access_token_id uuid NOT NULL,
  access_artifact_binding_digest char(64) NOT NULL,
  endpoint_id uuid NOT NULL,
  endpoint_version bigint NOT NULL,
  endpoint_snapshot_digest char(64) NOT NULL,
  channel text NOT NULL,
  provider_config_id uuid NOT NULL,
  provider_config_version bigint NOT NULL,
  provider_configuration_digest char(64) NOT NULL,
  provider_preflight_receipt_id uuid NOT NULL,
  provider_preflight_receipt_digest char(64) NOT NULL,
  delivery_id uuid NOT NULL,
  delivery_object_type text NOT NULL DEFAULT 'RESPONSE_REQUEST',
  delivery_version bigint NOT NULL,
  delivery_receipt_id uuid NOT NULL,
  delivery_receipt_sequence bigint NOT NULL,
  delivery_receipt_digest char(64) NOT NULL,
  delivery_resulting_state text NOT NULL,
  delivery_receipt_applied boolean NOT NULL,
  acceptance_evidence_kind text NOT NULL,
  provider_evidence_digest char(64) NOT NULL,
  provider_accepted_at timestamptz NOT NULL,
  audit_event_id uuid NOT NULL,
  outbox_event_id uuid NOT NULL,
  receipt_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_editorial_response_request_sent_receipts_1 PRIMARY KEY (id)
);
ALTER TABLE editorial.response_request_sent_receipts OWNER TO gurine_migrator;
ALTER TABLE editorial.response_request_sent_receipts ADD CONSTRAINT response_request_sent_once_uq UNIQUE (response_request_id);
ALTER TABLE editorial.response_request_sent_receipts ADD CONSTRAINT response_request_sent_source_event_uq UNIQUE (source_event_id);
ALTER TABLE editorial.response_request_sent_receipts ADD CONSTRAINT response_request_sent_delivery_receipt_uq UNIQUE (delivery_receipt_id);
ALTER TABLE editorial.response_request_sent_receipts ADD CONSTRAINT response_request_sent_receipt_digest_uq UNIQUE (receipt_digest);
ALTER TABLE editorial.response_request_sent_receipts ADD CONSTRAINT response_request_sent_outbox_uq UNIQUE (outbox_event_id);
ALTER TABLE editorial.response_request_sent_receipts ADD CONSTRAINT response_request_sent_exact_binding_uq UNIQUE (id, response_request_id, receipt_digest);
ALTER TABLE editorial.response_request_sent_receipts ADD CONSTRAINT g_ck_editorial_response_request_sent_receipts_1 CHECK (prior_request_version > 0 AND request_version = prior_request_version + 1 AND endpoint_version > 0 AND provider_config_version > 0 AND delivery_version > 0 AND delivery_receipt_sequence > 0);
ALTER TABLE editorial.response_request_sent_receipts ADD CONSTRAINT g_ck_editorial_response_request_sent_receipts_2 CHECK (prior_state = 'DRAFT' AND state = 'SENT');
ALTER TABLE editorial.response_request_sent_receipts ADD CONSTRAINT g_ck_editorial_response_request_sent_receipts_3 CHECK (delivery_object_type = 'RESPONSE_REQUEST');
ALTER TABLE editorial.response_request_sent_receipts ADD CONSTRAINT g_ck_editorial_response_request_sent_receipts_4 CHECK (delivery_receipt_applied AND delivery_resulting_state IN ('PROVIDER_ACCEPTED','DELIVERED','READ'));
ALTER TABLE editorial.response_request_sent_receipts ADD CONSTRAINT g_ck_editorial_response_request_sent_receipts_5 CHECK (acceptance_evidence_kind IN ('PROVIDER_RESPONSE','SIGNED_PROVIDER_CALLBACK','AUTHENTICATED_PROVIDER_POLL','OFFICIAL_CHANNEL_RECEIPT','RECONCILIATION_PROOF'));
ALTER TABLE editorial.response_request_sent_receipts ADD CONSTRAINT g_ck_editorial_response_request_sent_receipts_6 CHECK (provider_accepted_at <= created_at);
ALTER TABLE editorial.response_request_sent_receipts ADD CONSTRAINT g_ck_editorial_response_request_sent_receipts_7 CHECK (channel IN ('SMTP_EMAIL','TELEGRAM_BOT_API','META_WHATSAPP_BUSINESS_CLOUD','LINE_MESSAGING_API','SOLAPI_SMS','SOLAPI_KAKAO_BIZMESSAGE','TWILIO_VOICE','SIGNED_WEBHOOK'));
ALTER TABLE editorial.response_request_sent_receipts ADD CONSTRAINT g_ck_editorial_response_request_sent_receipts_8 CHECK (ops.is_lower_sha256(source_event_envelope_digest) AND ops.is_lower_sha256(response_request_binding_digest) AND ops.is_lower_sha256(scope_digest) AND ops.is_lower_sha256(communication_intent_digest) AND ops.is_lower_sha256(rendering_digest) AND ops.is_lower_sha256(rendered_sha256) AND ops.is_lower_sha256(access_artifact_binding_digest) AND ops.is_lower_sha256(endpoint_snapshot_digest) AND ops.is_lower_sha256(provider_configuration_digest) AND ops.is_lower_sha256(provider_preflight_receipt_digest) AND ops.is_lower_sha256(delivery_receipt_digest) AND ops.is_lower_sha256(provider_evidence_digest) AND ops.is_lower_sha256(receipt_digest));
REVOKE ALL ON editorial.response_request_sent_receipts FROM PUBLIC;
REVOKE ALL ON editorial.response_request_sent_receipts FROM gurine_workflow_worker;
REVOKE ALL ON editorial.response_request_sent_receipts FROM gurine_control_api;
REVOKE ALL ON editorial.response_request_sent_receipts FROM gurine_analysis_worker;
REVOKE ALL ON editorial.response_request_sent_receipts FROM gurine_public_projector;
REVOKE ALL ON editorial.response_request_sent_receipts FROM gurine_notification_worker;
REVOKE ALL ON editorial.response_request_sent_receipts FROM gurine_submission_api;
REVOKE ALL ON editorial.response_request_sent_receipts FROM gurine_auditor;
GRANT SELECT ON editorial.response_request_sent_receipts TO gurine_control_api;
GRANT SELECT ON editorial.response_request_sent_receipts TO gurine_notification_worker;
GRANT SELECT ON editorial.response_request_sent_receipts TO gurine_workflow_worker;
GRANT SELECT ON editorial.response_request_sent_receipts TO gurine_auditor;
CREATE TRIGGER editorial_response_request_sent_receipts_immutable_mutation_guard BEFORE UPDATE OR DELETE ON editorial.response_request_sent_receipts FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.business_calendar_versions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  calendar_id uuid NOT NULL,
  version bigint NOT NULL,
  timezone text NOT NULL,
  weekend_days smallint[] NOT NULL,
  holiday_dates date[] NOT NULL DEFAULT '{}'::date[],
  holiday_set_digest char(64) NOT NULL,
  policy_digest char(64) NOT NULL,
  calendar_digest char(64) NOT NULL,
  approval_proposal_id uuid NOT NULL,
  approval_proposal_version bigint NOT NULL,
  approval_digest char(64) NOT NULL,
  execution_receipt_id uuid NOT NULL,
  execution_receipt_digest char(64) NOT NULL,
  effective_at timestamptz NOT NULL,
  review_expires_at timestamptz NOT NULL,
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_ops_business_calendar_versions_1 PRIMARY KEY (id)
);
ALTER TABLE ops.business_calendar_versions OWNER TO gurine_migrator;
ALTER TABLE ops.business_calendar_versions ADD CONSTRAINT business_calendar_version_uq UNIQUE (calendar_id, version);
ALTER TABLE ops.business_calendar_versions ADD CONSTRAINT business_calendar_effective_at_uq UNIQUE (calendar_id, effective_at);
ALTER TABLE ops.business_calendar_versions ADD CONSTRAINT business_calendar_digest_uq UNIQUE (calendar_digest);
ALTER TABLE ops.business_calendar_versions ADD CONSTRAINT business_calendar_execution_receipt_uq UNIQUE (execution_receipt_id);
ALTER TABLE ops.business_calendar_versions ADD CONSTRAINT g_ck_ops_business_calendar_versions_1 CHECK (version > 0 AND approval_proposal_version > 0);
ALTER TABLE ops.business_calendar_versions ADD CONSTRAINT g_ck_ops_business_calendar_versions_2 CHECK (length(timezone) BETWEEN 1 AND 64 AND timezone !~ '\\s');
ALTER TABLE ops.business_calendar_versions ADD CONSTRAINT g_ck_ops_business_calendar_versions_3 CHECK (cardinality(weekend_days) BETWEEN 1 AND 6 AND ops.smallint_array_is_unique(weekend_days) AND weekend_days <@ ARRAY[0,1,2,3,4,5,6]::smallint[]);
ALTER TABLE ops.business_calendar_versions ADD CONSTRAINT g_ck_ops_business_calendar_versions_4 CHECK (cardinality(holiday_dates) <= 5000 AND ops.date_array_is_sorted_unique(holiday_dates));
ALTER TABLE ops.business_calendar_versions ADD CONSTRAINT g_ck_ops_business_calendar_versions_5 CHECK (review_expires_at > effective_at);
ALTER TABLE ops.business_calendar_versions ADD CONSTRAINT g_ck_ops_business_calendar_versions_6 CHECK (ops.is_lower_sha256(holiday_set_digest) AND ops.is_lower_sha256(policy_digest) AND ops.is_lower_sha256(calendar_digest) AND ops.is_lower_sha256(approval_digest) AND ops.is_lower_sha256(execution_receipt_digest));
REVOKE ALL ON ops.business_calendar_versions FROM PUBLIC;
REVOKE ALL ON ops.business_calendar_versions FROM gurine_workflow_worker;
REVOKE ALL ON ops.business_calendar_versions FROM gurine_control_api;
REVOKE ALL ON ops.business_calendar_versions FROM gurine_analysis_worker;
REVOKE ALL ON ops.business_calendar_versions FROM gurine_public_projector;
REVOKE ALL ON ops.business_calendar_versions FROM gurine_notification_worker;
REVOKE ALL ON ops.business_calendar_versions FROM gurine_submission_api;
REVOKE ALL ON ops.business_calendar_versions FROM gurine_auditor;
GRANT SELECT ON ops.business_calendar_versions TO gurine_control_api;
GRANT SELECT ON ops.business_calendar_versions TO gurine_notification_worker;
GRANT SELECT ON ops.business_calendar_versions TO gurine_workflow_worker;
GRANT SELECT ON ops.business_calendar_versions TO gurine_scheduler;
GRANT SELECT ON ops.business_calendar_versions TO gurine_auditor;
CREATE TRIGGER ops_business_calendar_versions_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.business_calendar_versions FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE editorial.response_delivery_clock_decisions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  response_request_id uuid NOT NULL,
  response_request_version bigint NOT NULL,
  response_request_binding_digest char(64) NOT NULL,
  clock_revision bigint NOT NULL DEFAULT 1,
  communication_intent_id uuid NOT NULL,
  intent_source_decision_digest char(64) NOT NULL,
  delivery_source_object_type text NOT NULL DEFAULT 'RESPONSE_REQUEST',
  outbound_delivery_id uuid NOT NULL,
  delivery_receipt_id uuid NOT NULL,
  delivery_receipt_sequence bigint NOT NULL,
  delivery_receipt_digest char(64) NOT NULL,
  delivery_resulting_state text NOT NULL,
  delivery_receipt_applied boolean NOT NULL,
  evidence_kind text NOT NULL,
  rendering_digest char(64) NOT NULL,
  endpoint_identity_hash char(64) NOT NULL,
  provider_identity_hash char(64) NOT NULL,
  evidence_digest char(64) NOT NULL,
  verified_delivery_at timestamptz NOT NULL,
  calendar_version_id uuid NOT NULL,
  calendar_digest char(64) NOT NULL,
  policy_digest char(64) NOT NULL,
  window_business_days smallint NOT NULL DEFAULT 5,
  timezone text NOT NULL,
  due_at timestamptz NOT NULL,
  decision_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL,
  outbox_event_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_editorial_response_delivery_clock_decisions_1 PRIMARY KEY (id)
);
ALTER TABLE editorial.response_delivery_clock_decisions OWNER TO gurine_migrator;
ALTER TABLE editorial.response_delivery_clock_decisions ADD CONSTRAINT response_delivery_single_clock_uq UNIQUE (response_request_id);
ALTER TABLE editorial.response_delivery_clock_decisions ADD CONSTRAINT response_delivery_receipt_clock_uq UNIQUE (outbound_delivery_id, delivery_receipt_id);
ALTER TABLE editorial.response_delivery_clock_decisions ADD CONSTRAINT response_delivery_clock_decision_digest_uq UNIQUE (decision_digest);
ALTER TABLE editorial.response_delivery_clock_decisions ADD CONSTRAINT response_delivery_clock_outbox_uq UNIQUE (outbox_event_id);
ALTER TABLE editorial.response_delivery_clock_decisions ADD CONSTRAINT g_ck_editorial_response_delivery_clock_decisions_1 CHECK (response_request_version > 0 AND clock_revision = 1 AND delivery_receipt_sequence > 0);
ALTER TABLE editorial.response_delivery_clock_decisions ADD CONSTRAINT g_ck_editorial_response_delivery_clock_decisions_2 CHECK (delivery_source_object_type = 'RESPONSE_REQUEST');
ALTER TABLE editorial.response_delivery_clock_decisions ADD CONSTRAINT g_ck_editorial_response_delivery_clock_decisions_3 CHECK (delivery_receipt_applied AND delivery_resulting_state IN ('DELIVERED','READ'));
ALTER TABLE editorial.response_delivery_clock_decisions ADD CONSTRAINT g_ck_editorial_response_delivery_clock_decisions_4 CHECK (evidence_kind IN ('SIGNED_PROVIDER_DELIVERY_CALLBACK','AUTHENTICATED_PROVIDER_POLL','OFFICIAL_CHANNEL_RECEIPT'));
ALTER TABLE editorial.response_delivery_clock_decisions ADD CONSTRAINT g_ck_editorial_response_delivery_clock_decisions_5 CHECK (window_business_days = 5);
ALTER TABLE editorial.response_delivery_clock_decisions ADD CONSTRAINT g_ck_editorial_response_delivery_clock_decisions_6 CHECK (length(timezone) BETWEEN 1 AND 64);
ALTER TABLE editorial.response_delivery_clock_decisions ADD CONSTRAINT g_ck_editorial_response_delivery_clock_decisions_7 CHECK (due_at > verified_delivery_at);
ALTER TABLE editorial.response_delivery_clock_decisions ADD CONSTRAINT g_ck_editorial_response_delivery_clock_decisions_8 CHECK (ops.is_lower_sha256(response_request_binding_digest) AND ops.is_lower_sha256(intent_source_decision_digest) AND ops.is_lower_sha256(delivery_receipt_digest) AND ops.is_lower_sha256(rendering_digest) AND ops.is_lower_sha256(endpoint_identity_hash) AND ops.is_lower_sha256(provider_identity_hash) AND ops.is_lower_sha256(evidence_digest) AND ops.is_lower_sha256(calendar_digest) AND ops.is_lower_sha256(policy_digest) AND ops.is_lower_sha256(decision_digest));
REVOKE ALL ON editorial.response_delivery_clock_decisions FROM PUBLIC;
REVOKE ALL ON editorial.response_delivery_clock_decisions FROM gurine_workflow_worker;
REVOKE ALL ON editorial.response_delivery_clock_decisions FROM gurine_control_api;
REVOKE ALL ON editorial.response_delivery_clock_decisions FROM gurine_analysis_worker;
REVOKE ALL ON editorial.response_delivery_clock_decisions FROM gurine_public_projector;
REVOKE ALL ON editorial.response_delivery_clock_decisions FROM gurine_notification_worker;
REVOKE ALL ON editorial.response_delivery_clock_decisions FROM gurine_submission_api;
REVOKE ALL ON editorial.response_delivery_clock_decisions FROM gurine_auditor;
GRANT SELECT ON editorial.response_delivery_clock_decisions TO gurine_control_api;
GRANT SELECT ON editorial.response_delivery_clock_decisions TO gurine_notification_worker;
GRANT SELECT ON editorial.response_delivery_clock_decisions TO gurine_workflow_worker;
GRANT SELECT ON editorial.response_delivery_clock_decisions TO gurine_scheduler;
GRANT SELECT ON editorial.response_delivery_clock_decisions TO gurine_auditor;
CREATE TRIGGER editorial_response_delivery_clock_decisions_immutable_mutation_guard BEFORE UPDATE OR DELETE ON editorial.response_delivery_clock_decisions FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE editorial.response_extension_decisions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  extension_request_id uuid NOT NULL,
  extension_request_version bigint NOT NULL,
  response_request_id uuid NOT NULL,
  response_request_version bigint NOT NULL,
  clock_decision_id uuid NOT NULL,
  decision_sequence bigint NOT NULL,
  decision text NOT NULL,
  requested_due_at timestamptz NOT NULL,
  prior_effective_due_at timestamptz NOT NULL,
  new_due_at timestamptz,
  calendar_version_id uuid NOT NULL,
  calendar_digest char(64) NOT NULL,
  reason_code text NOT NULL,
  reason text NOT NULL,
  actor_id uuid NOT NULL,
  capability text NOT NULL,
  assurance text NOT NULL,
  decision_digest char(64) NOT NULL,
  idempotency_key_hash char(64) NOT NULL,
  request_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL,
  outbox_event_id uuid NOT NULL,
  receipt_digest char(64) NOT NULL,
  decided_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_editorial_response_extension_decisions_1 PRIMARY KEY (id)
);
ALTER TABLE editorial.response_extension_decisions OWNER TO gurine_migrator;
ALTER TABLE editorial.response_extension_decisions ADD CONSTRAINT response_extension_single_decision_uq UNIQUE (extension_request_id);
ALTER TABLE editorial.response_extension_decisions ADD CONSTRAINT response_extension_sequence_uq UNIQUE (response_request_id, decision_sequence);
ALTER TABLE editorial.response_extension_decisions ADD CONSTRAINT response_extension_idempotency_uq UNIQUE (idempotency_key_hash);
ALTER TABLE editorial.response_extension_decisions ADD CONSTRAINT response_extension_decision_digest_uq UNIQUE (decision_digest);
ALTER TABLE editorial.response_extension_decisions ADD CONSTRAINT response_extension_receipt_digest_uq UNIQUE (receipt_digest);
ALTER TABLE editorial.response_extension_decisions ADD CONSTRAINT response_extension_outbox_uq UNIQUE (outbox_event_id);
ALTER TABLE editorial.response_extension_decisions ADD CONSTRAINT g_ck_editorial_response_extension_decisions_1 CHECK (extension_request_version > 0 AND response_request_version > 0 AND decision_sequence > 0);
ALTER TABLE editorial.response_extension_decisions ADD CONSTRAINT g_ck_editorial_response_extension_decisions_2 CHECK (decision IN ('APPROVE','REJECT'));
ALTER TABLE editorial.response_extension_decisions ADD CONSTRAINT g_ck_editorial_response_extension_decisions_3 CHECK (decision = 'APPROVE' AND new_due_at IS NOT NULL AND new_due_at > prior_effective_due_at OR decision = 'REJECT' AND new_due_at IS NULL);
ALTER TABLE editorial.response_extension_decisions ADD CONSTRAINT g_ck_editorial_response_extension_decisions_4 CHECK (capability = 'responses.policy.manage' AND assurance = 'STEP_UP');
ALTER TABLE editorial.response_extension_decisions ADD CONSTRAINT g_ck_editorial_response_extension_decisions_5 CHECK (length(reason_code) BETWEEN 1 AND 100 AND length(reason) BETWEEN 1 AND 4000);
ALTER TABLE editorial.response_extension_decisions ADD CONSTRAINT g_ck_editorial_response_extension_decisions_6 CHECK (ops.is_lower_sha256(calendar_digest) AND ops.is_lower_sha256(decision_digest) AND ops.is_lower_sha256(idempotency_key_hash) AND ops.is_lower_sha256(request_digest) AND ops.is_lower_sha256(receipt_digest));
REVOKE ALL ON editorial.response_extension_decisions FROM PUBLIC;
REVOKE ALL ON editorial.response_extension_decisions FROM gurine_workflow_worker;
REVOKE ALL ON editorial.response_extension_decisions FROM gurine_control_api;
REVOKE ALL ON editorial.response_extension_decisions FROM gurine_analysis_worker;
REVOKE ALL ON editorial.response_extension_decisions FROM gurine_public_projector;
REVOKE ALL ON editorial.response_extension_decisions FROM gurine_notification_worker;
REVOKE ALL ON editorial.response_extension_decisions FROM gurine_submission_api;
REVOKE ALL ON editorial.response_extension_decisions FROM gurine_auditor;
GRANT SELECT ON editorial.response_extension_decisions TO gurine_control_api;
GRANT SELECT ON editorial.response_extension_decisions TO gurine_notification_worker;
GRANT SELECT ON editorial.response_extension_decisions TO gurine_workflow_worker;
GRANT SELECT ON editorial.response_extension_decisions TO gurine_scheduler;
GRANT SELECT ON editorial.response_extension_decisions TO gurine_auditor;
CREATE TRIGGER editorial_response_extension_decisions_immutable_mutation_guard BEFORE UPDATE OR DELETE ON editorial.response_extension_decisions FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE intake.appeals (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  response_request_id uuid NOT NULL,
  response_submission_id uuid NOT NULL,
  expected_receipt_version bigint NOT NULL,
  prior_decision_kind text NOT NULL,
  prior_decision_id uuid NOT NULL,
  prior_receipt_digest char(64) NOT NULL,
  reason_code text NOT NULL,
  requested_outcome text NOT NULL,
  statement_ciphertext bytea NOT NULL,
  statement_sha256 char(64) NOT NULL,
  encryption_key_id text NOT NULL,
  supporting_attachment_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
  supporting_attachment_set_digest char(64) NOT NULL,
  attestation boolean NOT NULL,
  privacy_consent boolean NOT NULL,
  initial_state text NOT NULL DEFAULT 'RECEIVED',
  appeal_digest char(64) NOT NULL,
  review_due_at timestamptz NOT NULL,
  appeal_window_expires_at timestamptz NOT NULL,
  idempotency_key_hash char(64) NOT NULL,
  request_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL,
  outbox_event_id uuid NOT NULL,
  receipt_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_intake_appeals_1 PRIMARY KEY (id)
);
ALTER TABLE intake.appeals OWNER TO gurine_migrator;
ALTER TABLE intake.appeals ADD CONSTRAINT response_appeal_idempotency_uq UNIQUE (idempotency_key_hash);
ALTER TABLE intake.appeals ADD CONSTRAINT response_appeal_digest_uq UNIQUE (appeal_digest);
ALTER TABLE intake.appeals ADD CONSTRAINT response_appeal_receipt_digest_uq UNIQUE (receipt_digest);
ALTER TABLE intake.appeals ADD CONSTRAINT response_appeal_scope_receipt_uq UNIQUE (id, response_submission_id, response_request_id, receipt_digest);
ALTER TABLE intake.appeals ADD CONSTRAINT response_appeal_outbox_uq UNIQUE (outbox_event_id);
ALTER TABLE intake.appeals ADD CONSTRAINT g_ck_intake_appeals_1 CHECK (expected_receipt_version > 0);
ALTER TABLE intake.appeals ADD CONSTRAINT g_ck_intake_appeals_2 CHECK (prior_decision_kind IN ('DELIVERY_STATUS','DELIVERY_CLOCK','EXTENSION','PUBLICATION_EXCERPT','CONSENT'));
ALTER TABLE intake.appeals ADD CONSTRAINT g_ck_intake_appeals_3 CHECK (reason_code IN ('DELIVERY_DISPUTE','SCOPE_DISPUTE','CONSENT_DISPUTE','PUBLICATION_EXCERPT_DISPUTE','DEADLINE_DISPUTE','OTHER'));
ALTER TABLE intake.appeals ADD CONSTRAINT g_ck_intake_appeals_4 CHECK (requested_outcome IN ('REOPEN_RESPONSE','REVIEW_EXCERPT','CORRECT_STATUS','EXTEND_DEADLINE','HUMAN_REVIEW'));
ALTER TABLE intake.appeals ADD CONSTRAINT g_ck_intake_appeals_5 CHECK (octet_length(statement_ciphertext) BETWEEN 1 AND 65536);
ALTER TABLE intake.appeals ADD CONSTRAINT g_ck_intake_appeals_6 CHECK (length(encryption_key_id) BETWEEN 1 AND 200);
ALTER TABLE intake.appeals ADD CONSTRAINT g_ck_intake_appeals_7 CHECK (cardinality(supporting_attachment_ids) BETWEEN 0 AND 20 AND ops.uuid_array_is_unique(supporting_attachment_ids));
ALTER TABLE intake.appeals ADD CONSTRAINT g_ck_intake_appeals_8 CHECK (attestation AND privacy_consent);
ALTER TABLE intake.appeals ADD CONSTRAINT g_ck_intake_appeals_9 CHECK (initial_state = 'RECEIVED');
ALTER TABLE intake.appeals ADD CONSTRAINT g_ck_intake_appeals_10 CHECK (review_due_at > created_at AND appeal_window_expires_at > created_at);
ALTER TABLE intake.appeals ADD CONSTRAINT g_ck_intake_appeals_11 CHECK (ops.is_lower_sha256(prior_receipt_digest) AND ops.is_lower_sha256(statement_sha256) AND ops.is_lower_sha256(supporting_attachment_set_digest) AND ops.is_lower_sha256(appeal_digest) AND ops.is_lower_sha256(idempotency_key_hash) AND ops.is_lower_sha256(request_digest) AND ops.is_lower_sha256(receipt_digest));
REVOKE ALL ON intake.appeals FROM PUBLIC;
REVOKE ALL ON intake.appeals FROM gurine_workflow_worker;
REVOKE ALL ON intake.appeals FROM gurine_control_api;
REVOKE ALL ON intake.appeals FROM gurine_analysis_worker;
REVOKE ALL ON intake.appeals FROM gurine_public_projector;
REVOKE ALL ON intake.appeals FROM gurine_notification_worker;
REVOKE ALL ON intake.appeals FROM gurine_submission_api;
REVOKE ALL ON intake.appeals FROM gurine_auditor;
GRANT SELECT ON intake.appeals TO gurine_control_api;
GRANT SELECT(id, response_request_id, response_submission_id, reason_code, requested_outcome, review_due_at, receipt_digest, created_at) ON intake.appeals TO gurine_notification_worker;
ALTER TABLE intake.appeals ENABLE ROW LEVEL SECURITY;
CREATE POLICY response_appeal_receipt_scope ON intake.appeals TO gurine_submission_api USING (response_submission_id::text = current_setting('gurine.response_submission_id', true)) WITH CHECK (response_submission_id::text = current_setting('gurine.response_submission_id', true));
CREATE POLICY response_appeal_control_read ON intake.appeals TO gurine_control_api USING (response_submission_id::text = current_setting('gurine.response_submission_id', true));
CREATE POLICY response_appeal_notification_read ON intake.appeals TO gurine_notification_worker USING (response_submission_id::text = current_setting('gurine.response_submission_id', true));
CREATE TRIGGER intake_appeals_immutable_mutation_guard BEFORE UPDATE OR DELETE ON intake.appeals FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE intake.appeal_decisions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  appeal_id uuid NOT NULL,
  decision_sequence bigint NOT NULL,
  expected_prior_sequence bigint NOT NULL,
  prior_state text NOT NULL,
  state text NOT NULL,
  decision_kind text NOT NULL,
  reason_code text NOT NULL,
  reason_ciphertext bytea NOT NULL,
  reason_sha256 char(64) NOT NULL,
  encryption_key_id text NOT NULL,
  evidence_receipt_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
  evidence_set_digest char(64) NOT NULL,
  information_task_id uuid,
  information_task_digest char(64),
  actor_id uuid NOT NULL,
  capability text NOT NULL,
  assurance text NOT NULL,
  idempotency_key_hash char(64) NOT NULL,
  request_digest char(64) NOT NULL,
  decision_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL,
  outbox_event_id uuid NOT NULL,
  receipt_digest char(64) NOT NULL,
  decided_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_intake_appeal_decisions_1 PRIMARY KEY (id)
);
ALTER TABLE intake.appeal_decisions OWNER TO gurine_migrator;
ALTER TABLE intake.appeal_decisions ADD CONSTRAINT response_appeal_decision_sequence_uq UNIQUE (appeal_id, decision_sequence);
ALTER TABLE intake.appeal_decisions ADD CONSTRAINT response_appeal_decision_idempotency_uq UNIQUE (idempotency_key_hash);
ALTER TABLE intake.appeal_decisions ADD CONSTRAINT response_appeal_decision_digest_uq UNIQUE (decision_digest);
ALTER TABLE intake.appeal_decisions ADD CONSTRAINT response_appeal_decision_receipt_uq UNIQUE (receipt_digest);
ALTER TABLE intake.appeal_decisions ADD CONSTRAINT response_appeal_decision_outbox_uq UNIQUE (outbox_event_id);
ALTER TABLE intake.appeal_decisions ADD CONSTRAINT g_ck_intake_appeal_decisions_1 CHECK (decision_sequence > 0 AND expected_prior_sequence >= 0 AND decision_sequence = expected_prior_sequence + 1);
ALTER TABLE intake.appeal_decisions ADD CONSTRAINT g_ck_intake_appeal_decisions_2 CHECK (prior_state IN ('RECEIVED','REVIEW'));
ALTER TABLE intake.appeal_decisions ADD CONSTRAINT g_ck_intake_appeal_decisions_3 CHECK (state IN ('REVIEW','RESOLVED','REJECTED','DUPLICATE','WITHDRAWN'));
ALTER TABLE intake.appeal_decisions ADD CONSTRAINT g_ck_intake_appeal_decisions_4 CHECK (decision_kind IN ('START_REVIEW','RESOLVE','REJECT','MARK_DUPLICATE','WITHDRAW'));
ALTER TABLE intake.appeal_decisions ADD CONSTRAINT g_ck_intake_appeal_decisions_5 CHECK (prior_state = 'RECEIVED' AND decision_kind IN ('START_REVIEW','REJECT','MARK_DUPLICATE','WITHDRAW') OR prior_state = 'REVIEW' AND decision_kind IN ('RESOLVE','REJECT','MARK_DUPLICATE','WITHDRAW'));
ALTER TABLE intake.appeal_decisions ADD CONSTRAINT g_ck_intake_appeal_decisions_6 CHECK (decision_kind = 'START_REVIEW' AND state = 'REVIEW' OR decision_kind = 'RESOLVE' AND state = 'RESOLVED' OR decision_kind = 'REJECT' AND state = 'REJECTED' OR decision_kind = 'MARK_DUPLICATE' AND state = 'DUPLICATE' OR decision_kind = 'WITHDRAW' AND state = 'WITHDRAWN');
ALTER TABLE intake.appeal_decisions ADD CONSTRAINT g_ck_intake_appeal_decisions_7 CHECK (length(reason_code) BETWEEN 1 AND 100 AND octet_length(reason_ciphertext) BETWEEN 1 AND 65536 AND length(encryption_key_id) BETWEEN 1 AND 200);
ALTER TABLE intake.appeal_decisions ADD CONSTRAINT g_ck_intake_appeal_decisions_8 CHECK (cardinality(evidence_receipt_ids) BETWEEN 0 AND 100 AND ops.uuid_array_is_unique(evidence_receipt_ids));
ALTER TABLE intake.appeal_decisions ADD CONSTRAINT g_ck_intake_appeal_decisions_9 CHECK ((information_task_id IS NULL) = (information_task_digest IS NULL));
ALTER TABLE intake.appeal_decisions ADD CONSTRAINT g_ck_intake_appeal_decisions_10 CHECK (state <> 'RESOLVED' OR cardinality(evidence_receipt_ids) > 0);
ALTER TABLE intake.appeal_decisions ADD CONSTRAINT g_ck_intake_appeal_decisions_11 CHECK (capability = 'responses.review' AND assurance = 'STEP_UP');
ALTER TABLE intake.appeal_decisions ADD CONSTRAINT g_ck_intake_appeal_decisions_12 CHECK (ops.is_lower_sha256(reason_sha256) AND ops.is_lower_sha256(evidence_set_digest) AND (information_task_digest IS NULL OR ops.is_lower_sha256(information_task_digest)) AND ops.is_lower_sha256(idempotency_key_hash) AND ops.is_lower_sha256(request_digest) AND ops.is_lower_sha256(decision_digest) AND ops.is_lower_sha256(receipt_digest));
REVOKE ALL ON intake.appeal_decisions FROM PUBLIC;
REVOKE ALL ON intake.appeal_decisions FROM gurine_workflow_worker;
REVOKE ALL ON intake.appeal_decisions FROM gurine_control_api;
REVOKE ALL ON intake.appeal_decisions FROM gurine_analysis_worker;
REVOKE ALL ON intake.appeal_decisions FROM gurine_public_projector;
REVOKE ALL ON intake.appeal_decisions FROM gurine_notification_worker;
REVOKE ALL ON intake.appeal_decisions FROM gurine_submission_api;
REVOKE ALL ON intake.appeal_decisions FROM gurine_auditor;
GRANT SELECT ON intake.appeal_decisions TO gurine_control_api;
GRANT SELECT(id, appeal_id, decision_sequence, prior_state, state, decision_kind, evidence_set_digest, information_task_id, decision_digest, receipt_digest, decided_at) ON intake.appeal_decisions TO gurine_notification_worker;
ALTER TABLE intake.appeal_decisions ENABLE ROW LEVEL SECURITY;
CREATE POLICY response_appeal_decision_receipt_scope ON intake.appeal_decisions TO gurine_submission_api USING (EXISTS (SELECT 1 FROM intake.appeals a WHERE a.id = appeal_id AND a.response_submission_id::text = current_setting('gurine.response_submission_id', true)));
CREATE POLICY response_appeal_decision_control_read ON intake.appeal_decisions TO gurine_control_api USING (EXISTS (SELECT 1 FROM intake.appeals a WHERE a.id = appeal_id AND a.response_submission_id::text = current_setting('gurine.response_submission_id', true)));
CREATE POLICY response_appeal_decision_notification_read ON intake.appeal_decisions TO gurine_notification_worker USING (EXISTS (SELECT 1 FROM intake.appeals a WHERE a.id = appeal_id AND a.response_submission_id::text = current_setting('gurine.response_submission_id', true)));
CREATE TRIGGER intake_appeal_decisions_immutable_mutation_guard BEFORE UPDATE OR DELETE ON intake.appeal_decisions FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
ALTER TABLE intake.communication_endpoints ADD CONSTRAINT g_fk_intake_communication_endpoints_1 FOREIGN KEY (subject_id) REFERENCES intake.communication_subjects (id) ON DELETE RESTRICT;
ALTER TABLE intake.communication_endpoint_verifications ADD CONSTRAINT g_fk_intake_communication_endpoint_verifications_1 FOREIGN KEY (subject_id, subject_origin_binding_digest) REFERENCES intake.communication_subjects (id, origin_binding_digest) ON DELETE RESTRICT;
ALTER TABLE intake.communication_endpoint_verifications ADD CONSTRAINT g_fk_intake_communication_endpoint_verifications_2 FOREIGN KEY (endpoint_id, subject_id) REFERENCES intake.communication_endpoints (id, subject_id) ON DELETE RESTRICT;
ALTER TABLE intake.communication_endpoint_verifications ADD CONSTRAINT g_fk_intake_communication_endpoint_verifications_3 FOREIGN KEY (subject_id, endpoint_id, endpoint_version, endpoint_snapshot_digest) REFERENCES intake.communication_endpoint_link_events (subject_id, endpoint_id, endpoint_version, endpoint_snapshot_digest) ON DELETE RESTRICT;
ALTER TABLE intake.communication_endpoint_link_events ADD CONSTRAINT g_fk_intake_communication_endpoint_link_events_1 FOREIGN KEY (subject_id, subject_origin_binding_digest) REFERENCES intake.communication_subjects (id, origin_binding_digest) ON DELETE RESTRICT;
ALTER TABLE intake.communication_endpoint_link_events ADD CONSTRAINT g_fk_intake_communication_endpoint_link_events_2 FOREIGN KEY (endpoint_id, subject_id) REFERENCES intake.communication_endpoints (id, subject_id) ON DELETE RESTRICT;
ALTER TABLE intake.communication_endpoint_link_events ADD CONSTRAINT g_fk_intake_communication_endpoint_link_events_4 FOREIGN KEY (verification_id) REFERENCES intake.communication_endpoint_verifications (id) ON DELETE RESTRICT;
ALTER TABLE intake.communication_authorization_events ADD CONSTRAINT g_fk_intake_communication_authorization_events_1 FOREIGN KEY (subject_id, subject_origin_binding_digest) REFERENCES intake.communication_subjects (id, origin_binding_digest) ON DELETE RESTRICT;
ALTER TABLE intake.communication_authorization_events ADD CONSTRAINT g_fk_intake_communication_authorization_events_2 FOREIGN KEY (subject_id, endpoint_id, endpoint_version, endpoint_snapshot_digest, channel) REFERENCES intake.communication_endpoint_link_events (subject_id, endpoint_id, endpoint_version, endpoint_snapshot_digest, channel) ON DELETE RESTRICT;
ALTER TABLE intake.communication_preferences ADD CONSTRAINT g_fk_intake_communication_preferences_1 FOREIGN KEY (subject_id) REFERENCES intake.communication_subjects (id) ON DELETE RESTRICT;
ALTER TABLE intake.communication_suppressions ADD CONSTRAINT g_fk_intake_communication_suppressions_1 FOREIGN KEY (subject_id) REFERENCES intake.communication_subjects (id) ON DELETE RESTRICT;
ALTER TABLE intake.communication_suppressions ADD CONSTRAINT g_fk_intake_communication_suppressions_2 FOREIGN KEY (endpoint_id, subject_id) REFERENCES intake.communication_endpoints (id, subject_id) ON DELETE RESTRICT;
ALTER TABLE intake.communication_suppressions ADD CONSTRAINT g_fk_intake_communication_suppressions_3 FOREIGN KEY (release_of_suppression_id) REFERENCES intake.communication_suppressions (id) ON DELETE RESTRICT;
ALTER TABLE intake.communication_opt_out_receipts ADD CONSTRAINT g_fk_intake_communication_opt_out_receipts_1 FOREIGN KEY (subject_id) REFERENCES intake.communication_subjects (id) ON DELETE RESTRICT;
ALTER TABLE intake.communication_opt_out_receipts ADD CONSTRAINT g_fk_intake_communication_opt_out_receipts_2 FOREIGN KEY (endpoint_id, subject_id) REFERENCES intake.communication_endpoints (id, subject_id) ON DELETE RESTRICT;
ALTER TABLE intake.communication_opt_out_receipts ADD CONSTRAINT g_fk_intake_communication_opt_out_receipts_3 FOREIGN KEY (authorization_event_id) REFERENCES intake.communication_authorization_events (id) ON DELETE RESTRICT;
ALTER TABLE intake.communication_opt_out_receipts ADD CONSTRAINT g_fk_intake_communication_opt_out_receipts_4 FOREIGN KEY (suppression_id) REFERENCES intake.communication_suppressions (id) ON DELETE RESTRICT;
ALTER TABLE intake.communication_opt_out_receipts ADD CONSTRAINT g_fk_intake_communication_opt_out_receipts_6 FOREIGN KEY (callback_event_id) REFERENCES ops.communication_callback_events (id) ON DELETE RESTRICT;
ALTER TABLE ops.communication_provider_configs ADD CONSTRAINT g_fk_ops_communication_provider_configs_4 FOREIGN KEY (latest_preflight_receipt_id) REFERENCES ops.communication_provider_preflight_receipts (id) ON DELETE RESTRICT;
ALTER TABLE ops.communication_provider_preflight_receipts ADD CONSTRAINT g_fk_ops_communication_provider_preflight_receipts_1 FOREIGN KEY (provider_config_id) REFERENCES ops.communication_provider_configs (id) ON DELETE RESTRICT;
ALTER TABLE ops.communication_intents ADD CONSTRAINT g_fk_ops_communication_intents_2 FOREIGN KEY (recipient_subject_id) REFERENCES intake.communication_subjects (id) ON DELETE RESTRICT;
ALTER TABLE ops.communication_renderings ADD CONSTRAINT g_fk_ops_communication_renderings_1 FOREIGN KEY (intent_id) REFERENCES ops.communication_intents (id) ON DELETE RESTRICT;
ALTER TABLE ops.communication_renderings ADD CONSTRAINT g_fk_ops_communication_renderings_2 FOREIGN KEY (endpoint_id, endpoint_version, endpoint_snapshot_digest, channel) REFERENCES intake.communication_endpoint_link_events (endpoint_id, endpoint_version, endpoint_snapshot_digest, channel) ON DELETE RESTRICT;
ALTER TABLE ops.outbound_delivery_attempts ADD CONSTRAINT g_fk_ops_outbound_delivery_attempts_2 FOREIGN KEY (endpoint_id, endpoint_version, endpoint_snapshot_digest) REFERENCES intake.communication_endpoint_link_events (endpoint_id, endpoint_version, endpoint_snapshot_digest) ON DELETE RESTRICT;
ALTER TABLE ops.outbound_delivery_attempts ADD CONSTRAINT g_fk_ops_outbound_delivery_attempts_3 FOREIGN KEY (provider_preflight_receipt_id, provider_config_id, provider_config_version, configuration_digest, provider_preflight_receipt_digest) REFERENCES ops.communication_provider_preflight_receipts (id, provider_config_id, provider_config_version, configuration_digest, receipt_digest) ON DELETE RESTRICT;
ALTER TABLE ops.outbound_delivery_attempts ADD CONSTRAINT outbound_delivery_attempt_safe_retry_decision_fk FOREIGN KEY (safe_retry_decision_id, delivery_id, safe_retry_decision_sequence, safe_retry_decision_resulting_state, safe_retry_kind, safe_retry_proof_digest, safe_retry_decision_receipt_digest) REFERENCES ops.communication_reconciliation_decisions (id, delivery_id, decision_sequence, resulting_state, safe_retry_kind, safe_retry_proof_digest, receipt_digest) ON DELETE RESTRICT;
ALTER TABLE ops.communication_callback_events ADD CONSTRAINT g_fk_ops_communication_callback_events_1 FOREIGN KEY (provider_preflight_receipt_id, provider_config_id, provider_config_version, provider_configuration_digest, provider_preflight_receipt_digest) REFERENCES ops.communication_provider_preflight_receipts (id, provider_config_id, provider_config_version, configuration_digest, receipt_digest) ON DELETE RESTRICT;
ALTER TABLE ops.communication_reconciliation_decisions ADD CONSTRAINT communication_reconciliation_provider_preflight_fk FOREIGN KEY (safe_retry_provider_preflight_receipt_id, safe_retry_provider_config_id, safe_retry_provider_config_version, safe_retry_provider_configuration_digest, safe_retry_provider_preflight_receipt_digest) REFERENCES ops.communication_provider_preflight_receipts (id, provider_config_id, provider_config_version, configuration_digest, receipt_digest) ON DELETE RESTRICT;
ALTER TABLE ops.communication_reconciliation_decisions ADD CONSTRAINT communication_reconciliation_pre_egress_receipt_fk FOREIGN KEY (safe_retry_pre_egress_receipt_id, delivery_id, safe_retry_pre_egress_receipt_sequence, safe_retry_pre_egress_receipt_digest, safe_retry_pre_egress_evidence_kind, safe_retry_pre_egress_applied) REFERENCES ops.outbound_delivery_receipts (id, delivery_id, receipt_sequence, receipt_digest, evidence_kind, applied) ON DELETE RESTRICT;
ALTER TABLE ops.communication_reconciliation_decisions ADD CONSTRAINT communication_reconciliation_provider_lookup_receipt_fk FOREIGN KEY (provider_lookup_receipt_id, provider_lookup_receipt_delivery_id, provider_lookup_receipt_sequence, provider_lookup_receipt_digest, provider_lookup_receipt_evidence_kind, provider_lookup_receipt_applied) REFERENCES ops.outbound_delivery_receipts (id, delivery_id, receipt_sequence, receipt_digest, evidence_kind, applied) ON DELETE RESTRICT;
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_fk_ops_outbound_delivery_receipts_2 FOREIGN KEY (attempt_id) REFERENCES ops.outbound_delivery_attempts (id) ON DELETE RESTRICT;
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_fk_ops_outbound_delivery_receipts_3 FOREIGN KEY (callback_event_id) REFERENCES ops.communication_callback_events (id) ON DELETE RESTRICT;
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_fk_ops_outbound_delivery_receipts_4 FOREIGN KEY (reconciliation_decision_id) REFERENCES ops.communication_reconciliation_decisions (id) ON DELETE RESTRICT;
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_fk_ops_outbound_delivery_receipts_5 FOREIGN KEY (endpoint_id, endpoint_version, endpoint_snapshot_digest) REFERENCES intake.communication_endpoint_link_events (endpoint_id, endpoint_version, endpoint_snapshot_digest) ON DELETE RESTRICT;
ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT g_fk_ops_outbound_delivery_receipts_6 FOREIGN KEY (provider_preflight_receipt_id, provider_config_id, provider_config_version, provider_configuration_digest, provider_preflight_receipt_digest) REFERENCES ops.communication_provider_preflight_receipts (id, provider_config_id, provider_config_version, configuration_digest, receipt_digest) ON DELETE RESTRICT;
ALTER TABLE editorial.response_request_sent_receipts ADD CONSTRAINT response_request_sent_intent_fk FOREIGN KEY (communication_intent_id, communication_intent_digest) REFERENCES ops.communication_intents (id, intent_digest) ON DELETE RESTRICT;
ALTER TABLE editorial.response_request_sent_receipts ADD CONSTRAINT response_request_sent_rendering_fk FOREIGN KEY (rendering_id, rendering_digest, rendered_sha256) REFERENCES ops.communication_renderings (id, rendering_digest, rendered_sha256) ON DELETE RESTRICT;
ALTER TABLE editorial.response_request_sent_receipts ADD CONSTRAINT response_request_sent_endpoint_fk FOREIGN KEY (endpoint_id, endpoint_version, endpoint_snapshot_digest, channel) REFERENCES intake.communication_endpoint_link_events (endpoint_id, endpoint_version, endpoint_snapshot_digest, channel) ON DELETE RESTRICT;
ALTER TABLE editorial.response_request_sent_receipts ADD CONSTRAINT response_request_sent_preflight_fk FOREIGN KEY (provider_preflight_receipt_id, provider_config_id, provider_config_version, provider_configuration_digest, provider_preflight_receipt_digest) REFERENCES ops.communication_provider_preflight_receipts (id, provider_config_id, provider_config_version, configuration_digest, receipt_digest) ON DELETE RESTRICT;
ALTER TABLE editorial.response_request_sent_receipts ADD CONSTRAINT response_request_sent_delivery_receipt_fk FOREIGN KEY (delivery_receipt_id, delivery_id, delivery_receipt_sequence, delivery_receipt_digest, delivery_resulting_state, delivery_receipt_applied) REFERENCES ops.outbound_delivery_receipts (id, delivery_id, receipt_sequence, receipt_digest, resulting_state, applied) ON DELETE RESTRICT;
ALTER TABLE editorial.response_delivery_clock_decisions ADD CONSTRAINT g_fk_editorial_response_delivery_clock_decisions_2 FOREIGN KEY (communication_intent_id, delivery_source_object_type, response_request_id, intent_source_decision_digest) REFERENCES ops.communication_intents (id, source_object_type, source_object_id, source_decision_digest) ON DELETE RESTRICT;
ALTER TABLE editorial.response_delivery_clock_decisions ADD CONSTRAINT g_fk_editorial_response_delivery_clock_decisions_4 FOREIGN KEY (delivery_receipt_id, outbound_delivery_id, delivery_receipt_sequence, delivery_receipt_digest, delivery_resulting_state, delivery_receipt_applied) REFERENCES ops.outbound_delivery_receipts (id, delivery_id, receipt_sequence, receipt_digest, resulting_state, applied) ON DELETE RESTRICT;
ALTER TABLE editorial.response_delivery_clock_decisions ADD CONSTRAINT g_fk_editorial_response_delivery_clock_decisions_5 FOREIGN KEY (calendar_version_id) REFERENCES ops.business_calendar_versions (id) ON DELETE RESTRICT;
ALTER TABLE editorial.response_extension_decisions ADD CONSTRAINT g_fk_editorial_response_extension_decisions_3 FOREIGN KEY (clock_decision_id) REFERENCES editorial.response_delivery_clock_decisions (id) ON DELETE RESTRICT;
ALTER TABLE editorial.response_extension_decisions ADD CONSTRAINT g_fk_editorial_response_extension_decisions_4 FOREIGN KEY (calendar_version_id) REFERENCES ops.business_calendar_versions (id) ON DELETE RESTRICT;
ALTER TABLE intake.appeal_decisions ADD CONSTRAINT g_fk_intake_appeal_decisions_1 FOREIGN KEY (appeal_id) REFERENCES intake.appeals (id) ON DELETE RESTRICT;
CREATE INDEX communication_subject_origin_lookup_idx ON intake.communication_subjects (origin_object_type, origin_object_id, profile_version);
CREATE INDEX communication_subject_active_idx ON intake.communication_subjects (status, updated_at, id) WHERE status = 'ACTIVE';
CREATE INDEX communication_endpoint_subject_state_idx ON intake.communication_endpoints (subject_id, state, channel, id);
CREATE INDEX communication_endpoint_hmac_lookup_idx ON intake.communication_endpoints (channel, endpoint_hmac, hmac_key_version);
CREATE INDEX communication_endpoint_active_idx ON intake.communication_endpoints (subject_id, channel, id) WHERE state = 'ACTIVE';
CREATE INDEX communication_endpoint_verification_lookup_idx ON intake.communication_endpoint_verifications (subject_id, endpoint_id, state, expires_at, id);
CREATE UNIQUE INDEX communication_endpoint_one_pending_challenge_idx ON intake.communication_endpoint_verifications (endpoint_id) WHERE state = 'PENDING';
CREATE INDEX communication_endpoint_verification_expiry_idx ON intake.communication_endpoint_verifications (expires_at, id) WHERE state = 'PENDING';
CREATE INDEX communication_endpoint_link_history_idx ON intake.communication_endpoint_link_events (endpoint_id, endpoint_sequence);
CREATE INDEX communication_subject_link_history_idx ON intake.communication_endpoint_link_events (subject_id, profile_version);
CREATE INDEX communication_authorization_effective_lookup_idx ON intake.communication_authorization_events (subject_id, endpoint_id, purpose, topic_scope_digest, effective_at, authorization_sequence);
CREATE INDEX communication_authorization_expiry_idx ON intake.communication_authorization_events (expires_at, id) WHERE expires_at IS NOT NULL;
CREATE INDEX communication_authorization_source_idx ON intake.communication_authorization_events (source_kind, source_id, source_version);
CREATE INDEX communication_preference_subject_idx ON intake.communication_preferences (subject_id, purpose, updated_at, id);
CREATE INDEX communication_suppression_dispatch_idx ON intake.communication_suppressions (subject_id, endpoint_id, purpose, topic_scope_digest, effective_at, id);
CREATE INDEX communication_suppression_key_idx ON intake.communication_suppressions (suppression_key_digest, effective_at, id);
CREATE INDEX communication_suppression_expiry_idx ON intake.communication_suppressions (expires_at, id) WHERE expires_at IS NOT NULL;
CREATE INDEX communication_opt_out_subject_idx ON intake.communication_opt_out_receipts (subject_id, endpoint_id, occurred_at DESC, id DESC);
CREATE INDEX communication_provider_routing_idx ON ops.communication_provider_configs (deployment_id, environment, channel, operational_state, id);
CREATE INDEX communication_provider_activation_expiry_idx ON ops.communication_provider_configs (activation_expires_at, id) WHERE operational_state = 'ACTIVE' AND activation_expires_at IS NOT NULL;
CREATE INDEX communication_provider_preflight_current_idx ON ops.communication_provider_preflight_receipts (provider_config_id, provider_config_version, completed_at DESC, id DESC);
CREATE INDEX communication_provider_preflight_expiry_idx ON ops.communication_provider_preflight_receipts (expires_at, id) WHERE result = 'PASS';
CREATE INDEX communication_intent_source_idx ON ops.communication_intents (source_event_id, source_object_type, source_object_id);
CREATE INDEX communication_intent_recipient_idx ON ops.communication_intents (recipient_subject_id, purpose, created_at DESC, id DESC);
CREATE INDEX communication_intent_materialization_idx ON ops.communication_intents (state, created_at, id) WHERE state = 'CREATED';
CREATE INDEX communication_rendering_intent_idx ON ops.communication_renderings (intent_id, endpoint_id, channel, rendering_revision DESC);
CREATE INDEX communication_rendering_review_idx ON ops.communication_renderings (state, expires_at, id) WHERE state IN ('DRAFT','AWAITING_APPROVAL');
CREATE UNIQUE INDEX communication_rendering_one_live_idx ON ops.communication_renderings (intent_id, endpoint_id, channel) WHERE state IN ('DRAFT','AWAITING_APPROVAL','APPROVED');
CREATE INDEX outbound_delivery_attempt_history_idx ON ops.outbound_delivery_attempts (delivery_id, attempt_ordinal);
CREATE INDEX outbound_delivery_attempt_lease_idx ON ops.outbound_delivery_attempts (lease_expires_at, fencing_token, id);
CREATE INDEX outbound_delivery_attempt_provider_idx ON ops.outbound_delivery_attempts (provider_config_id, provider_config_version, claimed_at, id);
CREATE INDEX communication_callback_request_idx ON ops.communication_callback_events (provider_config_id, callback_request_digest, received_at, id);
CREATE INDEX communication_callback_provider_request_idx ON ops.communication_callback_events (provider_config_id, provider_request_identity_hmac, received_at, id) WHERE provider_request_identity_hmac IS NOT NULL;
CREATE INDEX communication_callback_unmatched_idx ON ops.communication_callback_events (received_at, id) WHERE processing_disposition IN ('AUTHENTICATED_PARTIAL','AUTHENTICATED_UNMATCHED');
CREATE INDEX communication_reconciliation_history_idx ON ops.communication_reconciliation_decisions (delivery_id, decision_sequence);
CREATE INDEX communication_reconciliation_actor_idx ON ops.communication_reconciliation_decisions (actor_id, decided_at DESC, id DESC);
CREATE INDEX outbound_delivery_receipt_history_idx ON ops.outbound_delivery_receipts (delivery_id, receipt_sequence);
CREATE INDEX outbound_delivery_receipt_state_idx ON ops.outbound_delivery_receipts (resulting_state, recorded_at DESC, id DESC);
CREATE INDEX outbound_delivery_receipt_provider_event_idx ON ops.outbound_delivery_receipts (provider_event_identity_hash) WHERE provider_event_identity_hash IS NOT NULL;
CREATE INDEX response_request_sent_request_idx ON editorial.response_request_sent_receipts (response_request_id, request_version, id);
CREATE INDEX response_request_sent_delivery_idx ON editorial.response_request_sent_receipts (delivery_id, delivery_receipt_sequence, id);
CREATE INDEX response_request_sent_intent_idx ON editorial.response_request_sent_receipts (communication_intent_id, rendering_id, id);
CREATE INDEX business_calendar_current_idx ON ops.business_calendar_versions (calendar_id, effective_at DESC, version DESC, id DESC);
CREATE INDEX business_calendar_review_expiry_idx ON ops.business_calendar_versions (review_expires_at, calendar_id, version);
CREATE INDEX response_delivery_clock_due_idx ON editorial.response_delivery_clock_decisions (due_at, response_request_id);
CREATE INDEX response_delivery_clock_calendar_idx ON editorial.response_delivery_clock_decisions (calendar_version_id, verified_delivery_at, id);
CREATE INDEX response_extension_history_idx ON editorial.response_extension_decisions (response_request_id, decision_sequence);
CREATE INDEX response_extension_due_idx ON editorial.response_extension_decisions (new_due_at, response_request_id) WHERE decision = 'APPROVE';
CREATE INDEX response_appeal_submission_idx ON intake.appeals (response_submission_id, created_at DESC, id DESC);
CREATE INDEX response_appeal_request_idx ON intake.appeals (response_request_id, review_due_at, created_at, id);
CREATE INDEX response_appeal_queue_idx ON intake.appeals (review_due_at, created_at, id);
CREATE INDEX response_appeal_decision_history_idx ON intake.appeal_decisions (appeal_id, decision_sequence);
CREATE INDEX response_appeal_decision_actor_idx ON intake.appeal_decisions (actor_id, decided_at DESC, id DESC);
COMMIT;
