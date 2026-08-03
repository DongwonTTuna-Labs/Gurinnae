BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'gurine_migrator') THEN CREATE ROLE gurine_migrator NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'gurine_ingest_worker') THEN CREATE ROLE gurine_ingest_worker NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'gurine_analysis_worker') THEN CREATE ROLE gurine_analysis_worker NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'gurine_control_api') THEN CREATE ROLE gurine_control_api NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'gurine_submission_api') THEN CREATE ROLE gurine_submission_api NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'gurine_public_projector') THEN CREATE ROLE gurine_public_projector NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'gurine_public_api') THEN CREATE ROLE gurine_public_api NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'gurine_auditor') THEN CREATE ROLE gurine_auditor NOLOGIN; END IF;
END
$$;

-- The research-fetch SECURITY DEFINER owns this immutable ingest relation in
-- deployments; establish the same owner after the fixture roles exist.
ALTER TABLE raw.source_fetches OWNER TO gurine_migrator;

REVOKE ALL ON SCHEMA raw, core, editorial, intake, ops, public, extensions FROM PUBLIC;
GRANT USAGE ON SCHEMA extensions TO
  gurine_migrator, gurine_ingest_worker, gurine_analysis_worker,
  gurine_control_api, gurine_submission_api, gurine_public_projector,
  gurine_public_api, gurine_auditor;
REVOKE ALL ON ALL TABLES IN SCHEMA raw, core, editorial, intake, ops, public FROM PUBLIC;

GRANT USAGE ON SCHEMA raw, core, ops TO gurine_ingest_worker;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA raw TO gurine_ingest_worker;
GRANT SELECT, INSERT, UPDATE ON core.agencies, core.agency_identifiers, core.suppliers, core.supplier_identifiers,
  core.entity_aliases, core.contracts, core.contract_line_items, core.contract_changes, core.field_provenance,
  core.price_observations TO gurine_ingest_worker;
GRANT SELECT, INSERT, UPDATE ON ops.source_runs, ops.source_incidents, ops.jobs, ops.job_attempts, ops.outbox, ops.inbox
  TO gurine_ingest_worker;

GRANT USAGE ON SCHEMA raw, core, editorial, ops TO gurine_analysis_worker;
GRANT SELECT ON ALL TABLES IN SCHEMA raw, core TO gurine_analysis_worker;
GRANT SELECT, INSERT, UPDATE ON core.rule_runs, core.anomaly_signals TO gurine_analysis_worker;
GRANT SELECT, INSERT, UPDATE ON editorial.cases, editorial.case_signals, editorial.hypotheses,
  editorial.evidence, editorial.hypothesis_evidence, editorial.claims, editorial.claim_evidence
  TO gurine_analysis_worker;
GRANT SELECT, INSERT, UPDATE ON ops.jobs, ops.job_attempts, ops.outbox, ops.inbox, ops.cost_events
  TO gurine_analysis_worker;

GRANT USAGE ON SCHEMA core, editorial, intake, ops TO gurine_control_api;
GRANT SELECT ON ALL TABLES IN SCHEMA core TO gurine_control_api;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA editorial TO gurine_control_api;
GRANT SELECT ON ALL TABLES IN SCHEMA intake TO gurine_control_api;
GRANT SELECT, INSERT, UPDATE ON ops.users, ops.roles, ops.capabilities, ops.role_capabilities, ops.user_roles,
  ops.sessions, ops.idempotency_keys, ops.audit_events, ops.outbox, ops.jobs, ops.job_attempts, ops.source_runs,
  ops.source_incidents, ops.provider_configs, ops.cost_events, ops.budget_limits, ops.kill_switches, ops.notifications
  TO gurine_control_api;

GRANT USAGE ON SCHEMA intake, editorial, ops TO gurine_submission_api;
GRANT SELECT ON editorial.response_requests TO gurine_submission_api;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA intake TO gurine_submission_api;
GRANT SELECT, INSERT, UPDATE ON ops.idempotency_keys, ops.audit_events, ops.outbox TO gurine_submission_api;

GRANT USAGE ON SCHEMA editorial, public, ops TO gurine_public_projector;
GRANT SELECT ON ALL TABLES IN SCHEMA editorial TO gurine_public_projector;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO gurine_public_projector;
GRANT SELECT, INSERT, UPDATE ON ops.inbox, ops.audit_events TO gurine_public_projector;

GRANT USAGE ON SCHEMA public TO gurine_public_api;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO gurine_public_api;

GRANT USAGE ON SCHEMA ops TO gurine_auditor;
GRANT SELECT ON ops.audit_events TO gurine_auditor;

-- Explicitly prove public API cannot read private schemas.
REVOKE ALL ON SCHEMA raw, core, editorial, intake, ops FROM gurine_public_api;
REVOKE ALL ON ALL TABLES IN SCHEMA raw, core, editorial, intake, ops FROM gurine_public_api;

INSERT INTO ops.capabilities(code, description, risk_level) VALUES
  ('public.read', '공개 publication projection 읽기', 'LOW'),
  ('subscriptions.manage', '본인 이메일 구독 관리', 'MEDIUM'),
  ('response.submit', 'token 범위 소명 draft·제출', 'MEDIUM'),
  ('signals.read', '내부 signal과 계산 조회', 'MEDIUM'),
  ('signals.triage', 'signal triage 결정', 'HIGH'),
  ('cases.read', '내부 사건 조회', 'MEDIUM'),
  ('cases.assign', '사건·task 담당자 변경', 'MEDIUM'),
  ('cases.investigate', '가설·상태·조사 작업', 'HIGH'),
  ('evidence.create', '근거 생성·연결·metadata 수정', 'HIGH'),
  ('evidence.verify', '근거 검증·redaction 승인', 'HIGH'),
  ('claims.author', '공개 claim 작성·수정', 'HIGH'),
  ('responses.request', '외부 소명 요청 발송', 'HIGH'),
  ('responses.review', '제출 소명 검증·공개 excerpt', 'HIGH'),
  ('review.editorial', '독립 편집 검토', 'HIGH'),
  ('review.legal', '법률·개인정보 검토와 hold', 'HIGH'),
  ('publication.preview', '공개 preview 생성·조회', 'MEDIUM'),
  ('publication.publish', '승인된 snapshot 게시', 'CRITICAL'),
  ('publication.correct', '정정 revision 생성·해결', 'CRITICAL'),
  ('publication.retract', '철회 검토·게시', 'CRITICAL'),
  ('sources.read', '내부 source 운영 정보 조회', 'MEDIUM'),
  ('sources.operate', '수집·schema·backfill 조작', 'CRITICAL'),
  ('rules.read', '내부 규칙·평가 조회', 'MEDIUM'),
  ('rules.propose', '규칙 version·평가·shadow 제안', 'HIGH'),
  ('rules.activate', '규칙 production 활성화·rollback', 'CRITICAL'),
  ('jobs.operate', 'job retry/cancel/queue pause', 'CRITICAL'),
  ('budgets.manage', '비용 한도 변경', 'CRITICAL'),
  ('kill_switch.execute', '기능 중지·재개', 'CRITICAL'),
  ('audit.read', '민감 감사 로그 조회·export', 'HIGH'),
  ('users.manage', '사용자 provision·disable·session revoke', 'CRITICAL'),
  ('roles.grant', '역할·capability grant/revoke', 'CRITICAL')
ON CONFLICT (code) DO UPDATE
SET description = EXCLUDED.description,
    risk_level = EXCLUDED.risk_level;

INSERT INTO ops.roles(code, name, description, risk_level, system_role) VALUES
  ('ANONYMOUS', 'Anonymous', 'System-defined Gurine role', 'LOW', true),
  ('SUBSCRIBER', 'Subscriber', 'System-defined Gurine role', 'MEDIUM', true),
  ('RESPONSE_PARTY', 'Response Party', 'System-defined Gurine role', 'MEDIUM', true),
  ('TRIAGER', 'Triager', 'System-defined Gurine role', 'HIGH', true),
  ('INVESTIGATOR', 'Investigator', 'System-defined Gurine role', 'HIGH', true),
  ('EDITOR', 'Editor', 'System-defined Gurine role', 'CRITICAL', true),
  ('LEGAL_REVIEWER', 'Legal Reviewer', 'System-defined Gurine role', 'CRITICAL', true),
  ('PUBLISHER', 'Publisher', 'System-defined Gurine role', 'CRITICAL', true),
  ('DATA_OPERATOR', 'Data Operator', 'System-defined Gurine role', 'CRITICAL', true),
  ('RULE_ANALYST', 'Rule Analyst', 'System-defined Gurine role', 'HIGH', true),
  ('OPERATIONS', 'Operations', 'System-defined Gurine role', 'CRITICAL', true),
  ('SECURITY_ADMIN', 'Security Admin', 'System-defined Gurine role', 'CRITICAL', true),
  ('ACCESS_ADMIN', 'Access Admin', 'System-defined Gurine role', 'CRITICAL', true),
  ('AUDITOR', 'Auditor', 'System-defined Gurine role', 'HIGH', true),
  ('EXECUTIVE_APPROVER', 'Executive Approver', 'System-defined Gurine role', 'CRITICAL', true)
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    description = EXCLUDED.description,
    risk_level = EXCLUDED.risk_level,
    system_role = EXCLUDED.system_role;

INSERT INTO ops.role_capabilities(role_id, capability_code)
SELECT r.id, mapping.capability_code
FROM (
  VALUES
    ('ANONYMOUS', 'public.read'),
  ('SUBSCRIBER', 'public.read'),
  ('SUBSCRIBER', 'subscriptions.manage'),
  ('RESPONSE_PARTY', 'response.submit'),
  ('TRIAGER', 'signals.read'),
  ('TRIAGER', 'signals.triage'),
  ('TRIAGER', 'cases.read'),
  ('INVESTIGATOR', 'signals.read'),
  ('INVESTIGATOR', 'signals.triage'),
  ('INVESTIGATOR', 'cases.read'),
  ('INVESTIGATOR', 'cases.assign'),
  ('INVESTIGATOR', 'cases.investigate'),
  ('INVESTIGATOR', 'evidence.create'),
  ('INVESTIGATOR', 'evidence.verify'),
  ('INVESTIGATOR', 'claims.author'),
  ('INVESTIGATOR', 'responses.request'),
  ('INVESTIGATOR', 'publication.preview'),
  ('EDITOR', 'cases.read'),
  ('EDITOR', 'cases.assign'),
  ('EDITOR', 'evidence.create'),
  ('EDITOR', 'evidence.verify'),
  ('EDITOR', 'claims.author'),
  ('EDITOR', 'responses.request'),
  ('EDITOR', 'responses.review'),
  ('EDITOR', 'review.editorial'),
  ('EDITOR', 'publication.preview'),
  ('EDITOR', 'publication.correct'),
  ('LEGAL_REVIEWER', 'cases.read'),
  ('LEGAL_REVIEWER', 'evidence.verify'),
  ('LEGAL_REVIEWER', 'responses.review'),
  ('LEGAL_REVIEWER', 'review.legal'),
  ('LEGAL_REVIEWER', 'publication.preview'),
  ('LEGAL_REVIEWER', 'publication.correct'),
  ('LEGAL_REVIEWER', 'publication.retract'),
  ('LEGAL_REVIEWER', 'audit.read'),
  ('PUBLISHER', 'cases.read'),
  ('PUBLISHER', 'review.editorial'),
  ('PUBLISHER', 'publication.preview'),
  ('PUBLISHER', 'publication.publish'),
  ('PUBLISHER', 'publication.correct'),
  ('PUBLISHER', 'publication.retract'),
  ('DATA_OPERATOR', 'sources.read'),
  ('DATA_OPERATOR', 'sources.operate'),
  ('DATA_OPERATOR', 'jobs.operate'),
  ('DATA_OPERATOR', 'audit.read'),
  ('RULE_ANALYST', 'rules.read'),
  ('RULE_ANALYST', 'rules.propose'),
  ('RULE_ANALYST', 'sources.read'),
  ('RULE_ANALYST', 'cases.read'),
  ('OPERATIONS', 'sources.read'),
  ('OPERATIONS', 'jobs.operate'),
  ('OPERATIONS', 'budgets.manage'),
  ('OPERATIONS', 'kill_switch.execute'),
  ('OPERATIONS', 'audit.read'),
  ('SECURITY_ADMIN', 'kill_switch.execute'),
  ('SECURITY_ADMIN', 'audit.read'),
  ('SECURITY_ADMIN', 'users.manage'),
  ('SECURITY_ADMIN', 'roles.grant'),
  ('ACCESS_ADMIN', 'users.manage'),
  ('ACCESS_ADMIN', 'roles.grant'),
  ('ACCESS_ADMIN', 'audit.read'),
  ('AUDITOR', 'cases.read'),
  ('AUDITOR', 'sources.read'),
  ('AUDITOR', 'rules.read'),
  ('AUDITOR', 'audit.read'),
  ('EXECUTIVE_APPROVER', 'publication.publish'),
  ('EXECUTIVE_APPROVER', 'publication.retract'),
  ('EXECUTIVE_APPROVER', 'rules.activate'),
  ('EXECUTIVE_APPROVER', 'budgets.manage'),
  ('EXECUTIVE_APPROVER', 'kill_switch.execute'),
  ('EXECUTIVE_APPROVER', 'audit.read')
) AS mapping(role_code, capability_code)
JOIN ops.roles r ON r.code = mapping.role_code
ON CONFLICT DO NOTHING;

COMMIT;
