from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

from pglast import parse_sql

from .loaders import load_json, load_yaml
from .models import Validation

TABLE_RE = re.compile(r'CREATE TABLE\s+([a-z_]+)\.([a-z_]+)\s*\(', re.I)
DROP_TABLE_RE = re.compile(r'DROP TABLE(?: IF EXISTS)?\s+([a-z_]+)\.([a-z_]+)', re.I)
DROP_FUNC_RE = re.compile(r'DROP FUNCTION(?: IF EXISTS)?\s+([a-z_]+)\.([a-z_]+)\s*\(', re.I)
FUNC_RE = re.compile(r'CREATE(?: OR REPLACE)? FUNCTION\s+([a-z_]+)\.([a-z_]+)\s*\(', re.I)
POLICY_RE = re.compile(r'CREATE POLICY\s+([a-zA-Z0-9_]+)\s+ON\s+([a-z_]+)\.([a-z_]+)', re.I)
TRIGGER_RE = re.compile(r'CREATE TRIGGER\s+([a-zA-Z0-9_]+).*?ON\s+([a-z_]+)\.([a-z_]+)', re.I | re.S)
FUNCTION_DEFINITION_RE = re.compile(
    r'CREATE(?: OR REPLACE)? FUNCTION\s+([a-z_]+\.[a-z_]+)\s*\(.*?\)\s*RETURNS\b.*?\$\$.*?\$\$;',
    re.I | re.S,
)
SEARCH_PATH_RE = re.compile(r'SET search_path\s*=\s*(.*?)\s+AS\s+\$\$', re.I | re.S)


def migration_digest(migrations: list[Path]) -> str:
    digest = hashlib.sha256()
    for migration in migrations:
        digest.update(migration.name.encode('utf-8'))
        digest.update(b'\0')
        digest.update(migration.read_bytes())
        digest.update(b'\0')
    return digest.hexdigest()


def validate(root: Path, result: Validation) -> None:
    catalog = load_yaml(root / 'specs/database/schema-catalog.yaml')
    privilege = load_yaml(root / 'specs/database/privilege-matrix.yaml')
    matrix = load_yaml(root / 'specs/database/operation-table-matrix.yaml')
    persistence = {
        item['operation_id']: item
        for item in load_yaml(root / 'specs/api/operation-persistence.yaml')['operations']
    }
    runtime_catalog = load_yaml(root / 'specs/database/runtime-security-tests.yaml')
    runtime_evidence = load_json(root / 'verification/postgres-runtime-baseline.json')

    migrations = sorted((root / 'specs/database/migrations').glob('*.sql'))
    for migration in migrations:
        try:
            parse_sql(migration.read_text(encoding='utf-8'))
        except Exception as exc:
            result.error(f'{migration.name}: PostgreSQL parser failed: {exc}')

    combined = '\n'.join(path.read_text(encoding='utf-8') for path in migrations)
    table_definitions = [f'{schema}.{table}' for schema, table in TABLE_RE.findall(combined)]
    dropped_tables = {f'{schema}.{table}' for schema, table in DROP_TABLE_RE.findall(combined)}
    tables = [name for name in table_definitions if name not in dropped_tables]
    function_definitions = [f'{schema}.{function}' for schema, function in FUNC_RE.findall(combined)]
    dropped_functions = {f'{schema}.{function}' for schema, function in DROP_FUNC_RE.findall(combined)}
    functions = [name for name in function_definitions if name not in dropped_functions]
    policies = [f'{schema}.{table}:{name}' for name, schema, table in POLICY_RE.findall(combined)]
    triggers = [f'{schema}.{table}:{name}' for name, schema, table in TRIGGER_RE.findall(combined)]
    schemas = sorted(set(re.findall(r'CREATE SCHEMA IF NOT EXISTS\s+([a-z_]+)', combined, re.I)))

    result.require(len(migrations) == catalog['migration_count'], f'migration count mismatch {len(migrations)} vs {catalog["migration_count"]}')
    result.require(schemas == catalog['schemas'] == ['core', 'editorial', 'extensions', 'intake', 'ops', 'public', 'raw'], f'database schema set mismatch: {schemas}')
    result.require(len(tables) == catalog['table_count'], f'table count mismatch {len(tables)} vs {catalog["table_count"]}')
    result.require(set(tables) == {f"{item['schema']}.{item['table']}" for item in catalog['tables']}, 'schema catalog table set differs from SQL')
    result.require(len(set(functions)) > 0, 'first-party database functions are missing')
    result.require(len(policies) == catalog['policy_count'] == 5, f'RLS policy definition count mismatch {len(policies)}')
    result.require(len(triggers) >= catalog['trigger_count'], f'trigger definition count {len(triggers)} is lower than active catalog count {catalog["trigger_count"]}')

    result.require('CREATE SCHEMA IF NOT EXISTS extensions' in combined, 'trusted extensions schema is missing')
    result.require('REVOKE ALL ON SCHEMA extensions FROM PUBLIC' in combined, 'extensions schema is not revoked from PUBLIC')
    for extension in ['pgcrypto', 'citext', 'pg_trgm']:
        result.require(
            re.search(rf'CREATE EXTENSION IF NOT EXISTS {extension} WITH SCHEMA extensions', combined, re.I) is not None,
            f'{extension} is not installed in the trusted extensions schema',
        )
    result.require('extensions.digest(' in combined, 'audit hashing does not schema-qualify extensions.digest')
    result.require('extensions.gin_trgm_ops' in combined, 'trigram operator class is not schema-qualified')
    result.require('extensions.citext' in combined, 'citext type is not schema-qualified')

    security_definers: list[tuple[str, str]] = []
    for match in FUNCTION_DEFINITION_RE.finditer(combined):
        definition = match.group(0)
        if re.search(r'\bSECURITY DEFINER\b', definition, re.I) is None:
            continue
        search_path_match = SEARCH_PATH_RE.search(definition)
        result.require(search_path_match is not None, f'{match.group(1)}: SECURITY DEFINER function lacks fixed search_path')
        if search_path_match is not None:
            security_definers.append((match.group(1), search_path_match.group(1)))
    result.require(bool(security_definers), 'SECURITY DEFINER functions are missing')
    for function_name, search_path in security_definers:
        normalized = ' '.join(search_path.strip().split())
        result.require('public' not in normalized, f'{function_name}: untrusted public schema in SECURITY DEFINER search_path')
        result.require(normalized.endswith('pg_temp'), f'{function_name}: pg_temp must be last in SECURITY DEFINER search_path')
        result.require('pg_catalog' in normalized, f'{function_name}: pg_catalog missing from SECURITY DEFINER search_path')

    exact_audit_signature = 'ops.append_audit_event(text,text,text,uuid,text,text,text,text,ops.audit_outcome,text,uuid,jsonb)'
    result.require(
        re.search(
            r'GRANT EXECUTE ON FUNCTION ops\.append_audit_event\(text,text,text,uuid,text,text,text,text,ops\.audit_outcome,text,uuid,jsonb\) TO gurine_identity_api',
            combined,
            re.I,
        ) is not None,
        'identity API grant does not use the exact 12-argument append_audit_event signature',
    )

    result.require('CREATE TABLE ops.assertion_replay_guard' in combined, 'assertion replay table is missing')
    result.require('CREATE OR REPLACE FUNCTION ops.consume_assertion_jti' in combined, 'assertion replay consume function is missing')
    result.require(
        re.search(
            r'GRANT EXECUTE ON FUNCTION ops\.consume_assertion_jti\(text,uuid,text,text,timestamptz,char\(64\)\) TO gurine_identity_api, gurine_control_api',
            combined,
            re.I,
        ) is not None,
        'assertion replay function grant differs',
    )
    result.require('schema_mappings_one_approved_per_drift_idx' in combined, 'one-approved-mapping-per-drift invariant is missing')
    result.require('ops.step_up_proofs' not in set(tables), 'legacy step-up proof table remains active')
    result.require('ops.consume_step_up_proof' not in set(functions), 'legacy step-up proof function remains active')

    result.require('CONSTRAINT response_submissions_one_per_request UNIQUE (response_request_id)' in combined, 'single-submission database constraint is missing')
    submit_section = combined[combined.rfind('CREATE OR REPLACE FUNCTION intake.submit_response('):]
    result.require("status IN ('SENT', 'VIEWED')" in submit_section and 'due_at > clock_timestamp()' in submit_section, 'submit_response does not enforce open and unexpired request state')
    result.require('response_request_already_submitted' in submit_section, 'submit_response does not reject a prior submission')
    result.require('revoked_at = clock_timestamp()' in submit_section and 'response_token_consumption_failed' in submit_section, 'submit_response does not atomically consume the response token')
    save_draft_section = combined[combined.rfind('CREATE OR REPLACE FUNCTION intake.save_response_draft('):combined.rfind('CREATE OR REPLACE FUNCTION intake.create_response_attachment(')]
    result.require('IF p_expected_version <> 0' in save_draft_section, 'initial response draft creation is not bound to expectedVersion=0')
    result.require('FOR UPDATE' in save_draft_section and 'version = p_expected_version' in save_draft_section, 'response draft update is not locked and version guarded')

    result.require('ALTER TABLE ops.sessions' in combined and 'csrf_token_hash char(64)' in combined, 'session CSRF hash persistence is missing')
    result.require('CREATE OR REPLACE FUNCTION ops.rotate_session_csrf' in combined, 'current-hash-bound CSRF rotation function is missing')

    for role in catalog['required_roles']:
        result.require(role in combined, f'missing database role {role}')
    for relation in privilege['rls_relations']:
        result.require(f'ALTER TABLE {relation} ENABLE ROW LEVEL SECURITY' in combined, f'RLS not enabled for {relation}')
        result.require(any(policy.startswith(relation + ':') for policy in policies), f'RLS policy missing for {relation}')
    for relation in privilege['immutable_relations']:
        result.require(any(trigger.startswith(relation + ':') for trigger in triggers), f'immutable trigger missing for {relation}')
    for relation in privilege['lifecycle_guarded_relations']:
        result.require(any(trigger.startswith(relation + ':') for trigger in triggers), f'lifecycle guard missing for {relation}')

    audit_definitions = list(re.finditer(r'CREATE OR REPLACE FUNCTION ops\.append_audit_event\s*\(', combined, re.I))
    result.require(bool(audit_definitions), 'DB-owned audit append function missing')
    audit_section = combined[audit_definitions[-1].start():] if audit_definitions else ''
    signature = audit_section.split('RETURNS', 1)[0]
    body = audit_section.split('$$;', 1)[0]
    result.require('p_previous_event_hash' not in signature and 'p_event_hash' not in signature, 'audit append accepts caller-supplied hash')
    result.require('FOR UPDATE' in body and 'extensions.digest(' in body, 'audit append must lock the chain head and calculate the digest in the database')
    result.require(re.search(r'(?<!NO)\bBYPASSRLS\b', combined, re.I) is None, 'runtime role must not receive BYPASSRLS')

    result.require(privilege['status'] == 'FINAL', 'privilege matrix must be FINAL')
    result.require(matrix['operation_count'] == 212 and len(matrix['operations']) == 212, 'operation-table matrix must cover 205 operations')
    valid_relations = set(tables) | set(functions) | {'content_repository', 'generated_openapi', 'oidc_provider_configuration', 'object_store'}
    for operation in matrix['operations']:
        source = persistence[operation['operation_id']]
        result.require(operation.get('mode', operation.get('operation_kind')) == source['operation_kind'], f"{operation['operation_id']}: matrix mode mismatch")
        for key in ['statements', 'repository_methods', 'domain_events', 'integration_events', 'audit_action']:
            result.require(operation[key] == source[key], f"{operation['operation_id']}: matrix {key} mismatch")
        for statement in operation.get('statements', []):
            result.require(statement['relation'] in valid_relations, f"{operation['operation_id']}: unknown relation {statement['relation']}")


    result.require(runtime_catalog['status'] == 'FINAL' and runtime_catalog['test_count'] >= 35, 'runtime security test catalog incomplete')
    result.require(runtime_evidence.get('result') == 'PASS', 'PostgreSQL runtime baseline is not PASS')
    result.require(runtime_evidence.get('postgresqlVersion') == '18.4', 'runtime baseline is not PostgreSQL 18.4')
    result.require(runtime_evidence.get('migrationCount') == catalog['migration_count'], 'runtime baseline migration count differs from catalog')
    active_counts = runtime_evidence.get('catalogCounts', {})
    result.require(active_counts == {'tables':catalog['table_count'],'functions':catalog['function_count'],'triggers':catalog['trigger_count'],'policies':catalog['policy_count']}, 'runtime baseline catalog counts differ')
    result.require(runtime_evidence.get('concurrencyContractCount') == 64 and runtime_evidence.get('concurrencyCatalogResolved') == 64, 'runtime concurrency baseline differs')
    required_runtime_names = {'active-catalog-object-counts','actor-assertion-replay-rejected','audit-event-mutation-rejected','audit-export-role-lifecycle','audit-runtime-chain','clean-migration-apply','closed-response-request-rejected','concurrency-contract-catalog-resolution','control-api-step-up-authorization-claim-denied','correction-attachment-cross-session-idor-rejected','correction-draft-session-reuse-rejected','correction-session-atomic-submit-and-receipt','csrf-hash-rotation','default-privilege-denied:gurine_analysis_worker','default-privilege-denied:gurine_auditor','default-privilege-denied:gurine_control_api','default-privilege-denied:gurine_document_extractor','default-privilege-denied:gurine_identity_api','default-privilege-denied:gurine_ingest_worker','default-privilege-denied:gurine_notification_worker','default-privilege-denied:gurine_public_api','default-privilege-denied:gurine_public_projector','default-privilege-denied:gurine_scheduler','default-privilege-denied:gurine_submission_api','default-privilege-denied:gurine_workflow_worker','duplicate-response-submit-rejected','expired-response-request-rejected','extension-schema-isolation','identity-role-editorial-denied','legacy-step-up-proof-objects-removed','legal-hold-immutable-after-placement','legal-hold-place-concurrency','postgres-version','public-role-private-schema-denied','public-role-write-denied','queue-and-source-primary-key-concurrency','response-active-session-reuse-rejected','response-attachment-cross-session-idor-rejected','response-draft-create-from-zero','response-draft-nonzero-create-rejected','response-magic-token-exchange','response-magic-token-replay-rejected','response-pending-session-reuse-rejected','response-scoped-draft-and-attachment','response-session-promotion','response-session-submit-and-receipt','response-submission-unique-constraint','review-snapshot-mutation-rejected','routine-signature-resolution','rule-run-terminal-mutation-rejected','rule-run-valid-terminal-transition','runtime-roles-no-superuser-or-bypassrls','schema-mapping-approve-concurrency','schema-mapping-reject-concurrency','security-definer-search-path','security-definer-search-path-hijack-resistant','service-assertion-replay-rejected','single-response-submission','source-document-invalid-lifecycle-rejected','source-document-valid-lifecycle-transition','stale-csrf-rotation-rejected','step-up-authorization-closed','step-up-authorization-fourth-issue-rejected','step-up-authorization-three-assertion-issues','submission-direct-write-denied','submission-service-assertion-replay-rejected','submission-session-least-privilege','subscription-session-lifecycle','subscription-session-reuse-rejected'}
    result.require(required_runtime_names <= set(runtime_evidence.get('requiredTests', [])), 'runtime baseline mandatory canary set differs')
    result.require(
        (root / 'scripts/compare_postgres_runtime.py').is_file()
        and (root / 'scripts/git_authority.py').is_file(),
        'reproducible runtime comparison and Git authority tooling missing',
    )
    result.stats.update({
        'database_schemas': len(schemas),
        'database_migrations': len(migrations),
        'database_tables': len(tables),
        'database_table_definitions': len(table_definitions),
        'database_functions': catalog['function_count'],
        'database_function_definitions': len(function_definitions),
        'database_policies': len(policies),
        'database_triggers': catalog['trigger_count'],
        'database_trigger_definitions': len(triggers),
        'database_roles': len(catalog['required_roles']),
        'runtime_security_tests': runtime_catalog['test_count'],
        'runtime_security_assertions': len(runtime_evidence.get('requiredTests', [])),
        'postgresql_runtime_version': runtime_evidence.get('postgresqlVersion'),
    })
