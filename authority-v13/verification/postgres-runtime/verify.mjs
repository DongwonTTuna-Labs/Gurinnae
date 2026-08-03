import EmbeddedPostgres from 'embedded-postgres';
import pg from 'pg';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const { Client } = pg;
const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');
const migrationDir = path.join(root, 'specs/database/migrations');
const concurrencyContractPath = path.join(root, 'specs/application/optimistic-concurrency.runtime.json');
const outputArg = process.argv.indexOf('--output');
const outputPath = outputArg >= 0 ? path.resolve(process.argv[outputArg + 1]) : null;

const results = [];
let server;
let tempDir;
let client;

function record(name, details = {}) {
  const item = { name, result: 'PASS', ...details };
  results.push(item);
  console.log(`PASS ${name}`);
  return item;
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

async function freePort() {
  const socket = net.createServer();
  await new Promise((resolve, reject) => socket.once('error', reject).listen(0, '127.0.0.1', resolve));
  const { port } = socket.address();
  await new Promise((resolve) => socket.close(resolve));
  return port;
}


async function ensureBundledLibraryLinks() {
  if (process.platform !== 'linux' || process.arch !== 'x64') return;
  const libDir = path.join(here, 'node_modules', '@embedded-postgres', 'linux-x64', 'native', 'lib');
  let files;
  try {
    files = await fs.readdir(libDir);
  } catch (error) {
    throw new Error(`embedded PostgreSQL library directory is unavailable: ${error.message}`);
  }
  for (const filename of files) {
    const match = filename.match(/^(lib.+\.so)\.(\d+)\.(\d+)$/);
    if (!match) continue;
    const [, base, major] = match;
    for (const linkName of [`${base}.${major}`, base]) {
      const linkPath = path.join(libDir, linkName);
      try {
        await fs.lstat(linkPath);
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
        await fs.symlink(filename, linkPath);
      }
    }
  }
}

async function migrationDigest(files) {
  const hash = crypto.createHash('sha256');
  for (const file of files) {
    const bytes = await fs.readFile(path.join(migrationDir, file));
    hash.update(Buffer.from(file));
    hash.update(Buffer.from([0]));
    hash.update(bytes);
    hash.update(Buffer.from([0]));
  }
  return hash.digest('hex');
}

async function expectSqlError(name, run, allowedCodes = []) {
  try {
    await run();
  } catch (error) {
    if (allowedCodes.length && !allowedCodes.includes(error.code)) {
      throw new Error(`${name}: expected SQLSTATE ${allowedCodes.join(', ')}, got ${error.code}: ${error.message}`);
    }
    return record(name, { sqlstate: error.code, message: error.message });
  }
  throw new Error(`${name}: operation unexpectedly succeeded`);
}

async function roleQuery(role, sql, params = []) {
  await client.query('BEGIN');
  try {
    await client.query(`SET LOCAL ROLE ${role}`);
    const response = await client.query(sql, params);
    await client.query('COMMIT');
    return response;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  }
}

async function main() {
  await ensureBundledLibraryLinks();
  const port = await freePort();
  tempDir = await fs.mkdtemp(path.join(os.tmpdir(), 'gurine-pg18-'));
  await fs.chmod(tempDir, 0o777);
  const dataDir = path.join(tempDir, 'data');
  const password = crypto.randomBytes(24).toString('base64url');
  server = new EmbeddedPostgres({
    databaseDir: dataDir,
    user: 'postgres',
    password,
    port,
    persistent: false,
    createPostgresUser: true,
    initdbFlags: ['--encoding=UTF8', '--locale=C'],
    postgresFlags: ['-F', '-c', 'listen_addresses=127.0.0.1', '-c', 'max_connections=50'],
    onLog: () => {},
    onError: (message) => console.error(`[postgres] ${message}`),
  });

  await server.initialise();
  await server.start();

  const admin = new Client({ host: '127.0.0.1', port, user: 'postgres', password, database: 'postgres' });
  await admin.connect();
  await admin.query('CREATE DATABASE gurine_authority_runtime');
  await admin.end();

  client = new Client({ host: '127.0.0.1', port, user: 'postgres', password, database: 'gurine_authority_runtime' });
  await client.connect();

  const migrationFiles = (await fs.readdir(migrationDir)).filter((name) => name.endsWith('.sql')).sort();
  for (const file of migrationFiles) {
    await client.query(await fs.readFile(path.join(migrationDir, file), 'utf8'));
  }
  const digest = await migrationDigest(migrationFiles);
  record('clean-migration-apply', { migrationCount: migrationFiles.length, migrationTreeSha256: digest });

  const version = (await client.query("SELECT current_setting('server_version') AS version")).rows[0].version;
  assert(version === '18.4', `expected PostgreSQL 18.4, got ${version}`);
  record('postgres-version', { version });

  const extensionRows = (await client.query(`
    SELECT e.extname, n.nspname
    FROM pg_extension e
    JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname IN ('pgcrypto','citext','pg_trgm')
    ORDER BY e.extname
  `)).rows;
  assert(extensionRows.length === 3 && extensionRows.every((row) => row.nspname === 'extensions'), `extension schema mismatch: ${JSON.stringify(extensionRows)}`);
  record('extension-schema-isolation', { extensions: extensionRows });

  const securityDefiners = (await client.query(`
    SELECT p.oid::regprocedure::text AS function_name, p.proconfig
    FROM pg_proc p
    WHERE p.prosecdef
    ORDER BY 1
  `)).rows;
  for (const row of securityDefiners) {
    const searchPath = (row.proconfig ?? []).find((value) => value.startsWith('search_path='));
    assert(searchPath, `${row.function_name}: missing fixed search_path`);
    assert(!searchPath.includes('public'), `${row.function_name}: public is present in search_path`);
    assert(searchPath.endsWith('pg_temp'), `${row.function_name}: pg_temp is not last in search_path`);
  }
  record('security-definer-search-path', { functionCount: securityDefiners.length });

  const catalogCounts = (await client.query(`
    SELECT
      (SELECT count(*)::integer FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
       WHERE n.nspname IN ('raw','core','editorial','intake','ops','public') AND c.relkind='r') AS tables,
      (SELECT count(*)::integer FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
       WHERE n.nspname IN ('raw','core','editorial','intake','ops','public')) AS functions,
      (SELECT count(*)::integer FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace
       WHERE n.nspname IN ('raw','core','editorial','intake','ops','public') AND NOT t.tgisinternal) AS triggers,
      (SELECT count(*)::integer FROM pg_policy p JOIN pg_class c ON c.oid=p.polrelid JOIN pg_namespace n ON n.oid=c.relnamespace
       WHERE n.nspname IN ('raw','core','editorial','intake','ops','public')) AS policies
  `)).rows[0];
  assert(catalogCounts.tables === 107, `expected 107 active tables, got ${catalogCounts.tables}`);
  assert(catalogCounts.functions === 72, `expected 72 active first-party functions, got ${catalogCounts.functions}`);
  assert(catalogCounts.triggers === 37, `expected 37 active first-party triggers, got ${catalogCounts.triggers}`);
  assert(catalogCounts.policies === 5, `expected 5 active RLS policies, got ${catalogCounts.policies}`);
  record('active-catalog-object-counts', catalogCounts);

  const legacyStepUpObjects = (await client.query(`
    SELECT to_regclass('ops.step_up_proofs')::text AS legacy_table,
           to_regprocedure('ops.consume_step_up_proof(character,uuid,character,text,uuid)')::text AS legacy_function
  `)).rows[0];
  assert(!legacyStepUpObjects.legacy_table && !legacyStepUpObjects.legacy_function, `legacy step-up proof objects remain: ${JSON.stringify(legacyStepUpObjects)}`);
  record('legacy-step-up-proof-objects-removed');

  const concurrencyBytes = await fs.readFile(concurrencyContractPath);
  const concurrencySpec = JSON.parse(concurrencyBytes.toString('utf8'));
  const concurrencyContractSha256 = crypto.createHash('sha256').update(concurrencyBytes).digest('hex');
  assert(concurrencySpec.contractCount === 64 && concurrencySpec.contracts.length === 64, 'expected 64 optimistic concurrency contracts');
  const catalogColumnRows = (await client.query(`
    SELECT table_schema, table_name, column_name
    FROM information_schema.columns
    WHERE table_schema IN ('raw','core','editorial','intake','ops','public')
  `)).rows;
  const catalogColumns = new Map();
  for (const row of catalogColumnRows) {
    const relation = `${row.table_schema}.${row.table_name}`;
    if (!catalogColumns.has(relation)) catalogColumns.set(relation, new Set());
    catalogColumns.get(relation).add(row.column_name);
  }
  for (const contract of concurrencySpec.contracts) {
    const guard = catalogColumns.get(contract.guardRelation);
    const mutation = catalogColumns.get(contract.mutationRelation);
    assert(guard, `${contract.operationId}: guard relation does not resolve: ${contract.guardRelation}`);
    assert(mutation, `${contract.operationId}: mutation relation does not resolve: ${contract.mutationRelation}`);
    for (const column of contract.guardColumns) assert(guard.has(column), `${contract.operationId}: guard column does not resolve: ${contract.guardRelation}.${column}`);
    for (const column of contract.mutationColumns) assert(mutation.has(column), `${contract.operationId}: mutation column does not resolve: ${contract.mutationRelation}.${column}`);
  }
  record('concurrency-contract-catalog-resolution', { contractCount: concurrencySpec.contractCount, concurrencyContractSha256 });

  const auditSignature = 'ops.append_audit_event(text,text,text,uuid,text,text,text,text,ops.audit_outcome,text,uuid,jsonb)';
  const auditGrant = (await client.query(`
    SELECT to_regprocedure($1)::text AS procedure,
           has_function_privilege('gurine_identity_api', $1, 'EXECUTE') AS identity_execute
  `, [auditSignature])).rows[0];
  assert(auditGrant.procedure && auditGrant.identity_execute, `audit signature/grant mismatch: ${JSON.stringify(auditGrant)}`);
  record('routine-signature-resolution', auditGrant);

  const firstRequestId = (await client.query('SELECT gen_random_uuid() AS id')).rows[0].id;
  const firstAudit = (await roleQuery('gurine_control_api', `
    SELECT ops.append_audit_event(
      'runtime:test','service','authority-verifier',NULL,
      'runtime.first','canary','1','audit.read','SUCCESS','first',
      $1,'{"sequence":1}'::jsonb
    ) AS id
  `, [firstRequestId])).rows[0].id;
  const secondRequestId = (await client.query('SELECT gen_random_uuid() AS id')).rows[0].id;
  const secondAudit = (await roleQuery('gurine_control_api', `
    SELECT ops.append_audit_event(
      'runtime:test','service','authority-verifier',NULL,
      'runtime.second','canary','2','audit.read','SUCCESS','second',
      $1,'{"sequence":2}'::jsonb
    ) AS id
  `, [secondRequestId])).rows[0].id;
  const chain = (await client.query(`
    SELECT first.event_hash AS first_hash,
           second.previous_event_hash AS second_previous_hash,
           second.event_hash AS second_hash,
           head.head_event_id,
           head.head_hash,
           head.version
    FROM ops.audit_events first
    JOIN ops.audit_events second ON second.id = $2
    JOIN ops.audit_chain_heads head ON head.stream_key = 'runtime:test'
    WHERE first.id = $1
  `, [firstAudit, secondAudit])).rows[0];
  assert(chain.first_hash === chain.second_previous_hash, 'audit previous hash does not link to first event');
  assert(chain.second_hash === chain.head_hash && chain.head_event_id === secondAudit && Number(chain.version) === 2, 'audit head mismatch');
  record('audit-runtime-chain', { firstAudit, secondAudit, headHash: chain.head_hash });

  await expectSqlError('audit-event-mutation-rejected', () => roleQuery(
    'gurine_control_api',
    'UPDATE ops.audit_events SET reason=\'tamper\' WHERE id=$1',
    [firstAudit],
  ), ['42501','55000']);

  const lifecycleSourceDocumentId = (await client.query(`
    INSERT INTO raw.source_documents(
      source_id,external_id,retrieved_at,content_type,content_sha256,content_size_bytes,object_key,status
    ) VALUES('runtime-source','runtime-document',clock_timestamp(),'application/json',$1,2,'runtime/document.json','FETCHED')
    RETURNING id
  `, ['5'.repeat(64)])).rows[0].id;
  await roleQuery('gurine_ingest_worker', `
    UPDATE raw.source_documents
    SET status='PARSED', parser_name='runtime-parser', parser_version='1.0.0'
    WHERE id=$1
  `, [lifecycleSourceDocumentId]);
  const parsedSource = (await client.query('SELECT status::text, parser_name, parser_version FROM raw.source_documents WHERE id=$1', [lifecycleSourceDocumentId])).rows[0];
  assert(parsedSource.status === 'PARSED' && parsedSource.parser_name === 'runtime-parser', 'valid source lifecycle transition failed');
  record('source-document-valid-lifecycle-transition');
  await expectSqlError('source-document-invalid-lifecycle-rejected', () => roleQuery(
    'gurine_ingest_worker',
    "UPDATE raw.source_documents SET status='FETCHED' WHERE id=$1",
    [lifecycleSourceDocumentId],
  ), ['23514']);

  const ruleVersionId = (await client.query(`
    INSERT INTO core.rule_versions(rule_id,version,name,description,configuration,code_digest,status)
    VALUES('RUNTIME_RULE','1.0.0','Runtime rule','Runtime lifecycle canary','{}',$1,'DRAFT')
    RETURNING id
  `, ['6'.repeat(64)])).rows[0].id;
  const ruleRunId = (await client.query(`
    INSERT INTO core.rule_runs(rule_version_id,run_key,input_snapshot_at,input_digest,started_at,status)
    VALUES($1,'runtime-rule-run',clock_timestamp(),$2,clock_timestamp(),'RUNNING')
    RETURNING id
  `, [ruleVersionId, '7'.repeat(64)])).rows[0].id;
  await roleQuery('gurine_analysis_worker', `
    UPDATE core.rule_runs
    SET status='SUCCEEDED', completed_at=clock_timestamp(), record_count=10, signal_count=1
    WHERE id=$1
  `, [ruleRunId]);
  const terminalRuleRun = (await client.query('SELECT status, record_count, signal_count FROM core.rule_runs WHERE id=$1', [ruleRunId])).rows[0];
  assert(terminalRuleRun.status === 'SUCCEEDED' && Number(terminalRuleRun.record_count) === 10, 'valid rule-run terminal transition failed');
  record('rule-run-valid-terminal-transition');
  await expectSqlError('rule-run-terminal-mutation-rejected', () => roleQuery(
    'gurine_analysis_worker',
    'UPDATE core.rule_runs SET signal_count=2 WHERE id=$1',
    [ruleRunId],
  ), ['55000']);

  const immutableCaseId = (await client.query("INSERT INTO editorial.cases(title) VALUES('Immutable review canary') RETURNING id")).rows[0].id;
  const reviewSnapshotId = (await client.query(`
    INSERT INTO editorial.review_snapshots(
      case_id,case_version,snapshot_sha256,snapshot_payload,automated_gate_results,created_by
    ) VALUES($1,1,$2,'{}','{}',$3)
    RETURNING id
  `, [immutableCaseId, '8'.repeat(64), '11111111-1111-4111-8111-111111111111'])).rows[0].id;
  await expectSqlError('review-snapshot-mutation-rejected', () => roleQuery(
    'gurine_control_api',
    "UPDATE editorial.review_snapshots SET snapshot_payload='{\"tampered\":true}' WHERE id=$1",
    [reviewSnapshotId],
  ), ['42501','55000']);

  await expectSqlError('public-role-private-schema-denied', () => roleQuery('gurine_public_api', 'SELECT 1 FROM editorial.cases LIMIT 1'), ['42501']);
  await expectSqlError('public-role-write-denied', () => roleQuery('gurine_public_api', "INSERT INTO public.cases(id,slug,title,public_state,latest_revision,summary,published_at,updated_at,source_freshness) VALUES(gen_random_uuid(),'forbidden','x','x',1,'x',now(),now(),'{}')"), ['42501']);
  await expectSqlError('identity-role-editorial-denied', () => roleQuery('gurine_identity_api', 'SELECT 1 FROM editorial.cases LIMIT 1'), ['42501']);
  await expectSqlError('submission-direct-write-denied', () => roleQuery('gurine_submission_api', "INSERT INTO intake.response_submissions(response_request_id,draft_version,submission_sha256,answers_encrypted,publication_consent,receipt_token_hash) VALUES(gen_random_uuid(),1,repeat('a',64),decode('00','hex'),'{}',repeat('b',64))"), ['42501']);

  await client.query('CREATE TABLE ops.ungranted_canary(id integer)');
  for (const role of ['gurine_public_api','gurine_submission_api','gurine_control_api','gurine_identity_api','gurine_ingest_worker','gurine_analysis_worker','gurine_public_projector','gurine_notification_worker','gurine_workflow_worker','gurine_document_extractor','gurine_scheduler','gurine_auditor']) {
    await expectSqlError(`default-privilege-denied:${role}`, () => roleQuery(role, 'SELECT * FROM ops.ungranted_canary'), ['42501']);
  }

  const actorId = '11111111-1111-4111-8111-111111111111';
  const caseId = (await client.query("INSERT INTO editorial.cases(title) VALUES('Runtime response canary') RETURNING id")).rows[0].id;
  const responseRequestId = (await client.query(`
    INSERT INTO editorial.response_requests(
      case_id,party_type,party_name,recipient_email_hash,recipient_email_encrypted,
      questions,requested_publication_scope,due_at,sent_at,status,created_by
    ) VALUES(
      $1,'AGENCY','Synthetic Agency',repeat('e',64),decode('00','hex'),
      '[]'::jsonb,'{}'::jsonb,clock_timestamp()+interval '1 day',clock_timestamp(),'SENT',$2
    ) RETURNING id
  `, [caseId, actorId])).rows[0].id;
  const tokenHash = 'a'.repeat(64);
  await client.query(`
    INSERT INTO intake.response_access_tokens(response_request_id,token_hash,expires_at,verified_at)
    VALUES($1,$2,clock_timestamp()+interval '1 day',clock_timestamp())
  `, [responseRequestId, tokenHash]);

  const draft = (await roleQuery('gurine_submission_api', `
    SELECT * FROM intake.save_response_draft(
      $1::char(64),0,decode('01','hex'),'{}'::jsonb,clock_timestamp()+interval '1 day'
    )
  `, [tokenHash])).rows[0];
  assert(Number(draft.version) === 1, `initial response draft version is ${draft.version}`);
  record('response-draft-create-from-zero', { draftId: draft.draft_id, version: Number(draft.version) });

  await expectSqlError('response-draft-nonzero-create-rejected', async () => {
    const otherCase = (await client.query("INSERT INTO editorial.cases(title) VALUES('Other response canary') RETURNING id")).rows[0].id;
    const otherRequest = (await client.query(`
      INSERT INTO editorial.response_requests(case_id,party_type,party_name,recipient_email_hash,recipient_email_encrypted,questions,requested_publication_scope,due_at,sent_at,status,created_by)
      VALUES($1,'AGENCY','Other',repeat('d',64),decode('00','hex'),'[]','{}',clock_timestamp()+interval '1 day',clock_timestamp(),'SENT',$2)
      RETURNING id
    `, [otherCase, actorId])).rows[0].id;
    const otherToken = '7'.repeat(64);
    await client.query("INSERT INTO intake.response_access_tokens(response_request_id,token_hash,expires_at,verified_at) VALUES($1,$2,clock_timestamp()+interval '1 day',clock_timestamp())", [otherRequest, otherToken]);
    await roleQuery('gurine_submission_api', "SELECT * FROM intake.save_response_draft($1::char(64),3,decode('01','hex'),'{}',clock_timestamp()+interval '1 day')", [otherToken]);
  }, ['40001']);

  const submissionId = (await roleQuery('gurine_submission_api', `
    SELECT intake.submit_response(
      $1::char(64),1,$2::char(64),decode('02','hex'),'{}'::jsonb,$3::char(64)
    ) AS id
  `, [tokenHash, 'b'.repeat(64), 'c'.repeat(64)])).rows[0].id;
  const responseState = (await client.query(`
    SELECT request.status, request.version,
           token.revoked_at IS NOT NULL AS token_revoked,
           (SELECT count(*)::integer FROM intake.response_submissions s WHERE s.response_request_id=request.id) AS submission_count
    FROM editorial.response_requests request
    JOIN intake.response_access_tokens token ON token.response_request_id=request.id
    WHERE request.id=$1
  `, [responseRequestId])).rows[0];
  assert(responseState.status === 'SUBMITTED' && Number(responseState.version) === 2 && responseState.token_revoked && responseState.submission_count === 1, `response terminal state mismatch: ${JSON.stringify(responseState)}`);
  record('single-response-submission', { submissionId, ...responseState });

  await expectSqlError('duplicate-response-submit-rejected', () => roleQuery('gurine_submission_api', `
    SELECT intake.submit_response($1::char(64),1,$2::char(64),decode('03','hex'),'{}'::jsonb,$3::char(64))
  `, [tokenHash, 'd'.repeat(64), 'e'.repeat(64)]), ['28000','55000','23505']);

  await expectSqlError('response-submission-unique-constraint', () => client.query(`
    INSERT INTO intake.response_submissions(response_request_id,draft_version,submission_sha256,answers_encrypted,publication_consent,receipt_token_hash)
    VALUES($1,1,$2,decode('04','hex'),'{}',$3)
  `, [responseRequestId, 'f'.repeat(64), '9'.repeat(64)]), ['23505']);

  const closedCase = (await client.query("INSERT INTO editorial.cases(title) VALUES('Closed response canary') RETURNING id")).rows[0].id;
  const closedRequest = (await client.query(`
    INSERT INTO editorial.response_requests(case_id,party_type,party_name,recipient_email_hash,recipient_email_encrypted,questions,requested_publication_scope,due_at,sent_at,status,created_by)
    VALUES($1,'AGENCY','Closed',repeat('c',64),decode('00','hex'),'[]','{}',clock_timestamp()+interval '1 day',clock_timestamp(),'CLOSED',$2)
    RETURNING id
  `, [closedCase, actorId])).rows[0].id;
  const closedToken = '8'.repeat(64);
  await client.query("INSERT INTO intake.response_access_tokens(response_request_id,token_hash,expires_at,verified_at) VALUES($1,$2,clock_timestamp()+interval '1 day',clock_timestamp())", [closedRequest, closedToken]);
  await expectSqlError('closed-response-request-rejected', () => roleQuery('gurine_submission_api', "SELECT * FROM intake.save_response_draft($1::char(64),0,decode('00','hex'),'{}',clock_timestamp()+interval '1 day')", [closedToken]), ['55000','28000']);

  const expiredCase = (await client.query("INSERT INTO editorial.cases(title) VALUES('Expired response canary') RETURNING id")).rows[0].id;
  const expiredRequest = (await client.query(`
    INSERT INTO editorial.response_requests(case_id,party_type,party_name,recipient_email_hash,recipient_email_encrypted,questions,requested_publication_scope,due_at,sent_at,status,created_by)
    VALUES($1,'AGENCY','Expired',repeat('b',64),decode('00','hex'),'[]','{}',clock_timestamp()-interval '1 minute',clock_timestamp()-interval '2 days','SENT',$2)
    RETURNING id
  `, [expiredCase, actorId])).rows[0].id;
  const expiredToken = '6'.repeat(64);
  await client.query("INSERT INTO intake.response_access_tokens(response_request_id,token_hash,expires_at,verified_at) VALUES($1,$2,clock_timestamp()+interval '1 day',clock_timestamp())", [expiredRequest, expiredToken]);
  await expectSqlError('expired-response-request-rejected', () => roleQuery('gurine_submission_api', "SELECT * FROM intake.save_response_draft($1::char(64),0,decode('00','hex'),'{}',clock_timestamp()+interval '1 day')", [expiredToken]), ['22023','28000']);

  await client.query('CREATE SCHEMA attacker');
  await client.query('GRANT USAGE ON SCHEMA attacker TO gurine_submission_api');
  await client.query('BEGIN');
  try {
    await client.query('SET LOCAL ROLE gurine_submission_api');
    await client.query('SET LOCAL search_path=attacker,public');
    await client.query('SELECT intake.get_response_access_status($1::char(64))', [tokenHash]);
    await client.query('COMMIT');
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  }
  record('security-definer-search-path-hijack-resistant');

  const userId = (await client.query(`
    INSERT INTO ops.users(oidc_subject,email,display_name,status)
    VALUES('authority-canary','authority-canary@example.invalid','Authority Canary','ACTIVE')
    RETURNING id
  `)).rows[0].id;


  const auditExport = (await roleQuery('gurine_control_api', `
    INSERT INTO ops.audit_exports(
      requested_by,from_at,to_at,format,scope,reason,watermark_policy,expires_at
    ) VALUES(
      $1,clock_timestamp()-interval '1 day',clock_timestamp(),'JSONL','GLOBAL',
      'Export the synthetic authority audit stream for the runtime canary.',
      'ACTOR_AND_TIME',clock_timestamp()+interval '1 hour'
    )
    RETURNING id,status,version
  `, [userId])).rows[0];
  assert(auditExport.status === 'QUEUED' && Number(auditExport.version) === 1,
    `audit export creation mismatch: ${JSON.stringify(auditExport)}`);
  const auditExportRunning = (await roleQuery('gurine_workflow_worker', `
    UPDATE ops.audit_exports
    SET status='RUNNING',started_at=clock_timestamp(),version=version+1
    WHERE id=$1 AND version=1
    RETURNING status,version
  `, [auditExport.id])).rows[0];
  assert(auditExportRunning.status === 'RUNNING' && Number(auditExportRunning.version) === 2,
    `audit export RUNNING transition mismatch: ${JSON.stringify(auditExportRunning)}`);
  const auditExportReady = (await roleQuery('gurine_workflow_worker', `
    UPDATE ops.audit_exports
    SET status='READY',object_key='runtime/audit-export.jsonl',content_sha256=$2,
        row_count=2,completed_at=clock_timestamp(),version=version+1
    WHERE id=$1 AND version=2
    RETURNING status,version,object_key,content_sha256
  `, [auditExport.id, 'f'.repeat(64)])).rows[0];
  assert(auditExportReady.status === 'READY' && Number(auditExportReady.version) === 3 &&
         auditExportReady.object_key === 'runtime/audit-export.jsonl' && auditExportReady.content_sha256.trim() === 'f'.repeat(64),
    `audit export READY transition mismatch: ${JSON.stringify(auditExportReady)}`);
  const auditExportPrivileges = (await client.query(`
    SELECT has_table_privilege('gurine_public_api','ops.audit_exports','INSERT') AS public_insert,
           has_table_privilege('gurine_submission_api','ops.audit_exports','INSERT') AS submission_insert,
           has_table_privilege('gurine_auditor','ops.audit_exports','UPDATE') AS auditor_update
  `)).rows[0];
  assert(!auditExportPrivileges.public_insert && !auditExportPrivileges.submission_insert && !auditExportPrivileges.auditor_update,
    `audit export privilege mismatch: ${JSON.stringify(auditExportPrivileges)}`);
  record('audit-export-role-lifecycle', { auditExportId: auditExport.id });

  const legalHoldCase = (await client.query(`
    INSERT INTO editorial.cases(title,legal_review_required)
    VALUES('Runtime legal hold canary',true)
    RETURNING id,version
  `)).rows[0];
  const legalHoldSnapshotId = (await client.query(`
    INSERT INTO editorial.review_snapshots(
      case_id,case_version,snapshot_sha256,snapshot_payload,automated_gate_results,unresolved_blockers,created_by
    ) VALUES($1,$2,$3,'{}'::jsonb,'{}'::jsonb,'[]'::jsonb,$4)
    RETURNING id
  `, [legalHoldCase.id, legalHoldCase.version, '9'.repeat(64), userId])).rows[0].id;
  const legalHoldResult = await roleQuery('gurine_control_api', `
    WITH guarded AS (
      UPDATE editorial.cases
      SET version=version+1
      WHERE id=$1 AND version=$2
      RETURNING id,version
    ), inserted AS (
      INSERT INTO editorial.legal_holds(
        case_id,review_snapshot_id,object_type,object_id,scope,affected_ids,
        reason,authority_reference,expires_at,placed_by
      )
      SELECT id,$3,'CASE',id,'ALL',jsonb_build_array(id),
             'Preserve the reviewed synthetic case while legal review is active.',
             'SYNTHETIC-AUTHORITY-2026-001',clock_timestamp()+interval '7 days',$4
      FROM guarded
      RETURNING id,version
    )
    SELECT inserted.id AS legal_hold_id, inserted.version AS legal_hold_version,
           guarded.version AS case_version
    FROM inserted CROSS JOIN guarded
  `, [legalHoldCase.id, Number(legalHoldCase.version), legalHoldSnapshotId, userId]);
  assert(legalHoldResult.rowCount === 1, 'legal hold placement did not insert exactly one row');
  assert(Number(legalHoldResult.rows[0].case_version) === 2 && Number(legalHoldResult.rows[0].legal_hold_version) === 1,
    `legal hold placement version mismatch: ${JSON.stringify(legalHoldResult.rows[0])}`);
  const legalHoldStale = await roleQuery('gurine_control_api', `
    UPDATE editorial.cases SET version=version+1
    WHERE id=$1 AND version=$2
    RETURNING version
  `, [legalHoldCase.id, Number(legalHoldCase.version)]);
  assert(legalHoldStale.rowCount === 0, 'stale legal hold case version unexpectedly mutated the case');
  record('legal-hold-place-concurrency', {
    caseId: legalHoldCase.id,
    reviewSnapshotId: legalHoldSnapshotId,
    legalHoldId: legalHoldResult.rows[0].legal_hold_id,
  });

  let legalHoldUpdateDenied = false;
  await client.query('BEGIN');
  try {
    await client.query('SET LOCAL ROLE gurine_control_api');
    await client.query(`UPDATE editorial.legal_holds SET reason='tampered' WHERE id=$1`, [legalHoldResult.rows[0].legal_hold_id]);
    await client.query('ROLLBACK');
  } catch (error) {
    await client.query('ROLLBACK');
    assert(error.code === '42501', `legal hold update expected 42501, got ${error.code}: ${error.message}`);
    legalHoldUpdateDenied = true;
  }
  const legalHoldPrivileges = (await client.query(`
    SELECT has_table_privilege('gurine_control_api','editorial.legal_holds','UPDATE') AS can_update,
           has_table_privilege('gurine_control_api','editorial.legal_holds','DELETE') AS can_delete
  `)).rows[0];
  assert(legalHoldUpdateDenied && !legalHoldPrivileges.can_update && !legalHoldPrivileges.can_delete,
    `legal hold immutability privilege mismatch: ${JSON.stringify(legalHoldPrivileges)}`);
  record('legal-hold-immutable-after-placement');

  const sessionTokenHash = '1'.repeat(64);
  const csrfHash1 = '2'.repeat(64);
  const csrfHash2 = '3'.repeat(64);
  const sessionId = (await client.query(`
    INSERT INTO ops.sessions(user_id,session_token_hash,auth_time,expires_at,csrf_token_hash)
    VALUES($1,$2,clock_timestamp(),clock_timestamp()+interval '1 hour',$3)
    RETURNING id
  `, [userId, sessionTokenHash, csrfHash1])).rows[0].id;
  const rotated = (await roleQuery('gurine_identity_api', `
    SELECT ops.rotate_session_csrf($1::char(64),$2::char(64),$3::char(64)) AS rotated
  `, [sessionTokenHash, csrfHash1, csrfHash2])).rows[0].rotated;
  assert(rotated, 'valid CSRF rotation returned false');
  const sessionRow = (await client.query('SELECT csrf_token_hash FROM ops.sessions WHERE id=$1', [sessionId])).rows[0];
  assert(sessionRow.csrf_token_hash.trim() === csrfHash2, 'CSRF hash was not rotated');
  record('csrf-hash-rotation');
  const staleRotation = (await roleQuery('gurine_identity_api', `
    SELECT ops.rotate_session_csrf($1::char(64),$2::char(64),$3::char(64)) AS rotated
  `, [sessionTokenHash, csrfHash1, '4'.repeat(64)])).rows[0].rotated;
  assert(!staleRotation, 'stale CSRF hash unexpectedly rotated the session');
  record('stale-csrf-rotation-rejected');


const authorizationTokenHash = 'a1'.repeat(32);
const actionDigest = 'b2'.repeat(32);
const idempotencyKeyHash = 'c3'.repeat(32);
const authorizationId = (await roleQuery('gurine_identity_api', `
  SELECT ops.create_step_up_authorization($1::uuid,$2::char(64),$3::char(64),$4::char(64),clock_timestamp()+interval '5 minutes') AS id
`, [sessionId, actionDigest, idempotencyKeyHash, authorizationTokenHash])).rows[0].id;
assert(authorizationId, 'step-up authorization was not created');
for (let issue = 1; issue <= 3; issue += 1) {
  const claimed = (await roleQuery('gurine_identity_api', `
    SELECT * FROM ops.claim_step_up_authorization($1::char(64),$2::uuid,$3::char(64),$4::char(64),clock_timestamp())
  `, [authorizationTokenHash, sessionId, actionDigest, idempotencyKeyHash])).rows[0];
  assert(claimed.authorization_id === authorizationId && Number(claimed.issue_number) === issue && Number(claimed.remaining_issues) === 3 - issue, `step-up authorization issue ${issue} mismatch`);
}
record('step-up-authorization-three-assertion-issues', { authorizationId });
await expectSqlError('step-up-authorization-fourth-issue-rejected', () => roleQuery('gurine_identity_api', `
  SELECT * FROM ops.claim_step_up_authorization($1::char(64),$2::uuid,$3::char(64),$4::char(64),clock_timestamp())
`, [authorizationTokenHash, sessionId, actionDigest, idempotencyKeyHash]), ['28000']);
const closed = (await roleQuery('gurine_identity_api', `
  SELECT ops.close_step_up_authorization($1::char(64),$2::uuid,$3::char(64),$4::char(64)) AS closed
`, [authorizationTokenHash, sessionId, actionDigest, idempotencyKeyHash])).rows[0].closed;
assert(closed, 'step-up authorization did not close');
record('step-up-authorization-closed');
await expectSqlError('control-api-step-up-authorization-claim-denied', () => roleQuery('gurine_control_api', `
  SELECT * FROM ops.claim_step_up_authorization($1::char(64),$2::uuid,$3::char(64),$4::char(64),clock_timestamp())
`, [authorizationTokenHash, sessionId, actionDigest, idempotencyKeyHash]), ['42501']);

  // Schema mapping optimistic concurrency uses the drift aggregate version and an exact mapping tuple.
  await client.query(`
    INSERT INTO ops.source_registry(source_id,display_name,connector_type,owner_team,enabled,schedule_cron,legal_status,configuration)
    VALUES('runtime-concurrency-source','Runtime source','SYNTHETIC','authority',true,'0 * * * *','APPROVED','{}')
  `);
  const approveDrift = (await client.query(`
    INSERT INTO ops.schema_drifts(source_id,detected_at,fingerprint_after,status,impact)
    VALUES('runtime-concurrency-source',clock_timestamp(),$1,'OPEN','runtime approve canary') RETURNING id,version
  `, ['a'.repeat(64)])).rows[0];
  await client.query(`
    INSERT INTO ops.schema_mappings(schema_drift_id,mapping_version,mapping_digest,field_mappings,status)
    VALUES($1,1,$2,'[]','DRAFT')
  `, [approveDrift.id, 'b'.repeat(64)]);
  const approveResult = await roleQuery('gurine_control_api', `
    WITH locked AS (
      SELECT id FROM ops.schema_drifts WHERE id=$1 AND version=$2 AND status='OPEN' FOR UPDATE
    ), mapped AS (
      UPDATE ops.schema_mappings SET status='APPROVED', decided_at=clock_timestamp()
      WHERE schema_drift_id=$1 AND mapping_version=1 AND mapping_digest=$3 AND EXISTS(SELECT 1 FROM locked)
      RETURNING id
    )
    UPDATE ops.schema_drifts SET status='RESOLVED', version=version+1
    WHERE id=$1 AND version=$2 AND EXISTS(SELECT 1 FROM mapped)
    RETURNING version
  `, [approveDrift.id, 1, 'b'.repeat(64)]);
  assert(approveResult.rowCount === 1 && Number(approveResult.rows[0].version) === 2, 'schema mapping approve concurrency failed');
  const approveStale = await roleQuery('gurine_control_api', `
    UPDATE ops.schema_drifts SET version=version+1 WHERE id=$1 AND version=1 RETURNING version
  `, [approveDrift.id]);
  assert(approveStale.rowCount === 0, 'stale schema mapping approve unexpectedly mutated the drift');
  record('schema-mapping-approve-concurrency');

  const rejectDrift = (await client.query(`
    INSERT INTO ops.schema_drifts(source_id,detected_at,fingerprint_after,status,impact)
    VALUES('runtime-concurrency-source',clock_timestamp(),$1,'OPEN','runtime reject canary') RETURNING id,version
  `, ['c'.repeat(64)])).rows[0];
  await client.query(`
    INSERT INTO ops.schema_mappings(schema_drift_id,mapping_version,mapping_digest,field_mappings,status)
    VALUES($1,3,$2,'[]','DRAFT')
  `, [rejectDrift.id, 'd'.repeat(64)]);
  const rejectResult = await roleQuery('gurine_control_api', `
    WITH locked AS (
      SELECT id FROM ops.schema_drifts WHERE id=$1 AND version=$2 AND status='OPEN' FOR UPDATE
    ), mapped AS (
      UPDATE ops.schema_mappings SET status='REJECTED', decided_at=clock_timestamp()
      WHERE schema_drift_id=$1 AND mapping_version=3 AND mapping_digest=$3 AND EXISTS(SELECT 1 FROM locked)
      RETURNING id
    )
    UPDATE ops.schema_drifts SET status='REJECTED', version=version+1
    WHERE id=$1 AND version=$2 AND EXISTS(SELECT 1 FROM mapped)
    RETURNING version
  `, [rejectDrift.id, 1, 'd'.repeat(64)]);
  assert(rejectResult.rowCount === 1 && Number(rejectResult.rows[0].version) === 2, 'schema mapping reject concurrency failed');
  const rejectedMapping = (await client.query(`SELECT status FROM ops.schema_mappings WHERE schema_drift_id=$1 AND mapping_version=3`, [rejectDrift.id])).rows[0];
  assert(rejectedMapping.status === 'REJECTED', 'selected schema mapping was not rejected');
  const rejectStale = await roleQuery('gurine_control_api', `UPDATE ops.schema_drifts SET version=version+1 WHERE id=$1 AND version=1 RETURNING version`, [rejectDrift.id]);
  assert(rejectStale.rowCount === 0, 'stale schema mapping reject unexpectedly mutated the drift');
  record('schema-mapping-reject-concurrency');

  await client.query(`INSERT INTO ops.queue_controls(queue_name,state,version) VALUES('runtime-queue','RUNNING',1)`);
  const queuePause = await roleQuery('gurine_control_api', `UPDATE ops.queue_controls SET state='PAUSED_NEW',version=version+1 WHERE queue_name=$1 AND version=$2 RETURNING version`, ['runtime-queue',1]);
  assert(queuePause.rowCount === 1 && Number(queuePause.rows[0].version) === 2, 'queue_name concurrency predicate failed');
  const queueStale = await roleQuery('gurine_control_api', `UPDATE ops.queue_controls SET version=version+1 WHERE queue_name=$1 AND version=1 RETURNING version`, ['runtime-queue']);
  assert(queueStale.rowCount === 0, 'stale queue update succeeded');
  const sourcePause = await roleQuery('gurine_control_api', `UPDATE ops.source_registry SET enabled=false,version=version+1 WHERE source_id=$1 AND version=1 RETURNING version`, ['runtime-concurrency-source']);
  assert(sourcePause.rowCount === 1 && Number(sourcePause.rows[0].version) === 2, 'source_id concurrency predicate failed');
  const sourceStale = await roleQuery('gurine_control_api', `UPDATE ops.source_registry SET version=version+1 WHERE source_id=$1 AND version=1 RETURNING version`, ['runtime-concurrency-source']);
  assert(sourceStale.rowCount === 0, 'stale source update succeeded');
  record('queue-and-source-primary-key-concurrency');

  const requestDigest = 'e'.repeat(64);
  const serviceJti = '55555555-5555-4555-8555-555555555555';
  const serviceFirst = (await roleQuery('gurine_identity_api', `SELECT ops.consume_assertion_jti('SERVICE',$1::uuid,'review-console','identity-api',clock_timestamp()+interval '30 seconds',$2::char(64)) AS consumed`, [serviceJti,requestDigest])).rows[0].consumed;
  const serviceReplay = (await roleQuery('gurine_identity_api', `SELECT ops.consume_assertion_jti('SERVICE',$1::uuid,'review-console','identity-api',clock_timestamp()+interval '30 seconds',$2::char(64)) AS consumed`, [serviceJti,requestDigest])).rows[0].consumed;
  assert(serviceFirst && !serviceReplay, 'service assertion replay guard failed');
  record('service-assertion-replay-rejected');
  const actorJti = '66666666-6666-4666-8666-666666666666';
  const actorFirst = (await roleQuery('gurine_control_api', `SELECT ops.consume_assertion_jti('ACTOR',$1::uuid,'identity-api','control-api',clock_timestamp()+interval '20 seconds',$2::char(64)) AS consumed`, [actorJti,requestDigest])).rows[0].consumed;
  const actorReplay = (await roleQuery('gurine_control_api', `SELECT ops.consume_assertion_jti('ACTOR',$1::uuid,'identity-api','control-api',clock_timestamp()+interval '20 seconds',$2::char(64)) AS consumed`, [actorJti,requestDigest])).rows[0].consumed;
  assert(actorFirst && !actorReplay, 'actor assertion replay guard failed');
  record('actor-assertion-replay-rejected');


  // v13 Submission boundary: BFF service assertion replay guard.
  const submissionServiceJti = '77777777-7777-4777-8777-777777777777';
  const submissionRequestDigest = '7'.repeat(64);
  const submissionAssertionFirst = (await roleQuery('gurine_submission_api', `
    SELECT ops.consume_assertion_jti('SERVICE',$1::uuid,'public-web','submission-api',clock_timestamp()+interval '30 seconds',$2::char(64)) AS consumed
  `, [submissionServiceJti, submissionRequestDigest])).rows[0].consumed;
  const submissionAssertionReplay = (await roleQuery('gurine_submission_api', `
    SELECT ops.consume_assertion_jti('SERVICE',$1::uuid,'public-web','submission-api',clock_timestamp()+interval '30 seconds',$2::char(64)) AS consumed
  `, [submissionServiceJti, submissionRequestDigest])).rows[0].consumed;
  assert(submissionAssertionFirst && !submissionAssertionReplay, 'submission BFF service assertion replay guard failed');
  record('submission-service-assertion-replay-rejected');

  const v13Case = (await client.query("INSERT INTO editorial.cases(title) VALUES('v13 scoped response boundary') RETURNING id")).rows[0].id;
  const v13Request = (await client.query(`
    INSERT INTO editorial.response_requests(
      case_id,party_type,party_name,recipient_email_hash,recipient_email_encrypted,
      questions,requested_publication_scope,due_at,sent_at,status,created_by
    ) VALUES(
      $1,'AGENCY','Scoped Response Agency',repeat('1',64),decode('01','hex'),
      '[]'::jsonb,'{}'::jsonb,clock_timestamp()+interval '1 day',clock_timestamp(),'SENT',$2
    ) RETURNING id
  `,[v13Case,actorId])).rows[0].id;
  const v13Magic = '1'.repeat(64);
  const v13Pending = '2'.repeat(64);
  const v13Active = '3'.repeat(64);
  const v13Receipt = '4'.repeat(64);
  const v13ReceiptSession = '5'.repeat(64);
  await client.query(`
    INSERT INTO intake.response_access_tokens(response_request_id,token_hash,expires_at)
    VALUES($1,$2,clock_timestamp()+interval '1 day')
  `,[v13Request,v13Magic]);
  const exchange = (await roleQuery('gurine_submission_api', `
    SELECT * FROM intake.exchange_response_magic_token($1::char(64),$2::char(64),'response-portal',clock_timestamp()+interval '15 minutes')
  `,[v13Magic,v13Pending])).rows[0];
  assert(exchange.request_id===v13Request && exchange.session_id, 'response magic token exchange failed');
  await expectSqlError('response-magic-token-replay-rejected',()=>roleQuery('gurine_submission_api',`
    SELECT * FROM intake.exchange_response_magic_token($1::char(64),$2::char(64),'response-portal',clock_timestamp()+interval '15 minutes')
  `,[v13Magic,'6'.repeat(64)]),['28000']);
  record('response-magic-token-exchange');

  const failedOtp=(await roleQuery('gurine_submission_api',`
    SELECT * FROM intake.verify_response_session($1::char(64),'response-portal',false,$2::char(64),clock_timestamp()+interval '12 hours')
  `,[v13Pending,'6'.repeat(64)])).rows[0];
  assert(Number(failedOtp.remaining_attempts)===4 && failedOtp.session_id===null,'response OTP failure accounting mismatch');
  const verified=(await roleQuery('gurine_submission_api',`
    SELECT * FROM intake.verify_response_session($1::char(64),'response-portal',true,$2::char(64),clock_timestamp()+interval '12 hours')
  `,[v13Pending,v13Active])).rows[0];
  assert(verified.request_id===v13Request && verified.session_id,'response OTP promotion failed');
  await expectSqlError('response-pending-session-reuse-rejected',()=>roleQuery('gurine_submission_api',`
    SELECT * FROM intake.verify_response_session($1::char(64),'response-portal',true,$2::char(64),clock_timestamp()+interval '12 hours')
  `,[v13Pending,'7'.repeat(64)]),['28000']);
  record('response-session-promotion');

  const scopedDraft=(await roleQuery('gurine_submission_api',`
    SELECT * FROM intake.save_response_draft_session($1::char(64),'response-portal',0,decode('01','hex'),'{}',clock_timestamp()+interval '1 day')
  `,[v13Active])).rows[0];
  assert(Number(scopedDraft.version)===1,'scoped response draft creation failed');
  const responseAttachment=(await roleQuery('gurine_submission_api',`
    SELECT intake.create_response_attachment_session($1::char(64),'response-portal',decode('02','hex'),'application/pdf',10,$2::char(64),'runtime/response.pdf') AS id
  `,[v13Active,'8'.repeat(64)])).rows[0].id;
  await roleQuery('gurine_submission_api',`
    SELECT intake.finalize_response_attachment_session($1::char(64),'response-portal',$2,10,$3::char(64))
  `,[v13Active,responseAttachment,'8'.repeat(64)]);
  await client.query(`UPDATE intake.response_attachments SET scan_status='CLEAN' WHERE id=$1`,[responseAttachment]);
  const scopedPreview=(await roleQuery('gurine_submission_api',`
    SELECT intake.get_response_preview_session($1::char(64),'response-portal') AS preview
  `,[v13Active])).rows[0].preview;
  assert(scopedPreview.attachments.length===1,'scoped response preview missing attachment');
  record('response-scoped-draft-and-attachment');

  const otherCaseV13=(await client.query("INSERT INTO editorial.cases(title) VALUES('v13 other scoped response') RETURNING id")).rows[0].id;
  const otherRequestV13=(await client.query(`
    INSERT INTO editorial.response_requests(case_id,party_type,party_name,recipient_email_hash,recipient_email_encrypted,questions,requested_publication_scope,due_at,sent_at,status,created_by)
    VALUES($1,'AGENCY','Other Scoped Agency',repeat('2',64),decode('02','hex'),'[]','{}',clock_timestamp()+interval '1 day',clock_timestamp(),'SENT',$2) RETURNING id
  `,[otherCaseV13,actorId])).rows[0].id;
  const otherActive='9'.repeat(64);
  await client.query(`INSERT INTO intake.submission_sessions(token_hash,session_kind,scope_type,scope_id,bff_issuer,expires_at) VALUES($1,'RESPONSE_ACTIVE','RESPONSE_REQUEST',$2,'response-portal',clock_timestamp()+interval '12 hours')`,[otherActive,otherRequestV13]);
  await expectSqlError('response-attachment-cross-session-idor-rejected',()=>roleQuery('gurine_submission_api',`
    SELECT intake.delete_response_attachment_session($1::char(64),'response-portal',$2)
  `,[otherActive,responseAttachment]),['P0002']);

  const scopedSubmission=(await roleQuery('gurine_submission_api',`
    SELECT * FROM intake.submit_response_session(
      $1::char(64),'response-portal',1,$2::char(64),decode('03','hex'),'{}',$3::char(64),$4::char(64),clock_timestamp()+interval '30 minutes'
    )
  `,[v13Active,'a'.repeat(64),v13Receipt,v13ReceiptSession])).rows[0];
  assert(scopedSubmission.submission_id && scopedSubmission.receipt_session_id,'scoped response submit failed');
  await expectSqlError('response-active-session-reuse-rejected',()=>roleQuery('gurine_submission_api',`
    SELECT * FROM intake.save_response_draft_session($1::char(64),'response-portal',1,decode('04','hex'),'{}',clock_timestamp()+interval '1 day')
  `,[v13Active]),['28000']);
  const responseReceipt=(await roleQuery('gurine_submission_api',`
    SELECT intake.get_response_receipt_session($1::char(64),'response-portal') AS receipt
  `,[v13ReceiptSession])).rows[0].receipt;
  assert(responseReceipt.id===scopedSubmission.submission_id,'response receipt session scope mismatch');
  record('response-session-submit-and-receipt');

  const correctionSessionHash='b'.repeat(64);
  const correctionReceiptHash='c'.repeat(64);
  const correctionReceiptSession='d'.repeat(64);
  const correctionStart=(await roleQuery('gurine_submission_api',`
    SELECT * FROM intake.create_correction_session($1::char(64),'public-web','ko-KR','synthetic-case',1,clock_timestamp()+interval '1 day')
  `,[correctionSessionHash])).rows[0];
  const correctionSaved=(await roleQuery('gurine_submission_api',`
    SELECT * FROM intake.save_correction_draft_session(
      $1::char(64),'public-web',1,'PUBLIC',repeat('3',64)::char(64),decode('03','hex'),
      'Correction summary','["replace unit"]'::jsonb,'Synthetic evidence'
    )
  `,[correctionSessionHash])).rows[0];
  assert(Number(correctionSaved.version)===2,'correction draft version did not advance');
  const correctionAttachment=(await roleQuery('gurine_submission_api',`
    SELECT intake.create_correction_draft_attachment($1::char(64),'public-web',decode('04','hex'),'application/pdf',12,$2::char(64),'runtime/correction.pdf') AS id
  `,[correctionSessionHash,'e'.repeat(64)])).rows[0].id;
  await roleQuery('gurine_submission_api',`
    SELECT intake.finalize_correction_draft_attachment($1::char(64),'public-web',$2,'etag-runtime',12,$3::char(64))
  `,[correctionSessionHash,correctionAttachment,'e'.repeat(64)]);
  await client.query(`UPDATE intake.correction_draft_attachments SET scan_status='CLEAN' WHERE id=$1`,[correctionAttachment]);
  const correctionPreview=(await roleQuery('gurine_submission_api',`
    SELECT intake.get_correction_draft_preview_session($1::char(64),'public-web') AS preview
  `,[correctionSessionHash])).rows[0].preview;
  assert(correctionPreview.attachments.length===1,'correction preview missing attachment');
  const correctionSubmit=(await roleQuery('gurine_submission_api',`
    SELECT * FROM intake.submit_correction_draft_session(
      $1::char(64),'public-web',2,true,true,$2::char(64),$3::char(64),clock_timestamp()+interval '30 minutes'
    )
  `,[correctionSessionHash,correctionReceiptHash,correctionReceiptSession])).rows[0];
  assert(correctionSubmit.request_id && correctionSubmit.receipt_session_id,'correction submit failed');
  const correctionState=(await client.query(`
    SELECT (SELECT count(*)::integer FROM intake.correction_request_drafts WHERE id=$1) AS draft_count,
           (SELECT status FROM intake.submission_sessions WHERE token_hash=$2) AS draft_session_status,
           (SELECT count(*)::integer FROM intake.correction_attachments WHERE correction_request_id=$3) AS attachment_count
  `,[correctionStart.draft_id,correctionSessionHash,correctionSubmit.request_id])).rows[0];
  assert(correctionState.draft_count===0 && correctionState.draft_session_status==='CONSUMED' && correctionState.attachment_count===1,`correction terminal state mismatch: ${JSON.stringify(correctionState)}`);
  await expectSqlError('correction-draft-session-reuse-rejected',()=>roleQuery('gurine_submission_api',`
    SELECT * FROM intake.save_correction_draft_session($1::char(64),'public-web',2,'PUBLIC',repeat('3',64)::char(64),decode('03','hex'),'x','[]','x')
  `,[correctionSessionHash]),['28000']);
  const correctionReceipt=(await roleQuery('gurine_submission_api',`
    SELECT intake.get_correction_receipt_session($1::char(64),'public-web') AS receipt
  `,[correctionReceiptSession])).rows[0].receipt;
  assert(correctionReceipt.id===correctionSubmit.request_id,'correction receipt scope mismatch');
  record('correction-session-atomic-submit-and-receipt');

  const otherCorrectionHash='f'.repeat(64);
  const otherCorrection=(await roleQuery('gurine_submission_api',`
    SELECT * FROM intake.create_correction_session($1::char(64),'public-web','ko-KR',NULL,NULL,clock_timestamp()+interval '1 day')
  `,[otherCorrectionHash])).rows[0];
  await expectSqlError('correction-attachment-cross-session-idor-rejected',()=>roleQuery('gurine_submission_api',`
    SELECT intake.delete_correction_draft_attachment($1::char(64),'public-web',$2)
  `,[otherCorrectionHash,correctionAttachment]),['P0002']);

  const subscriptionPending='0'.repeat(64);
  const subscriptionVerify='1'.repeat(63)+'2';
  const subscriptionManageToken='2'.repeat(63)+'3';
  const subscriptionActive='3'.repeat(63)+'4';
  const subscription=(await roleQuery('gurine_submission_api',`
    SELECT * FROM intake.create_subscription_session(
      repeat('4',64)::char(64),decode('05','hex'),'["CASE:synthetic"]'::jsonb,'DAILY','ko-KR',
      $1::char(64),$2::char(64),$3::char(64),'public-web',clock_timestamp()+interval '30 minutes'
    )
  `,[subscriptionVerify,subscriptionManageToken,subscriptionPending])).rows[0];
  const subscriptionVerified=(await roleQuery('gurine_submission_api',`
    SELECT * FROM intake.verify_subscription_session($1::char(64),$2::char(64),'public-web',clock_timestamp()+interval '30 minutes')
  `,[subscriptionVerify,subscriptionActive])).rows[0];
  assert(subscriptionVerified.subscription_id===subscription.subscription_id,'subscription verification scope mismatch');
  const pendingState=(await client.query(`SELECT status FROM intake.submission_sessions WHERE token_hash=$1`,[subscriptionPending])).rows[0].status;
  assert(pendingState==='CONSUMED','pending subscription session not consumed');
  const subscriptionProjection=(await roleQuery('gurine_submission_api',`
    SELECT intake.get_subscription_session($1::char(64),'public-web') AS subscription
  `,[subscriptionActive])).rows[0].subscription;
  assert(subscriptionProjection.id===subscription.subscription_id,'subscription session projection mismatch');
  const unsubscribed=(await roleQuery('gurine_submission_api',`
    SELECT intake.unsubscribe_session($1::char(64),'public-web') AS id
  `,[subscriptionActive])).rows[0].id;
  assert(unsubscribed===subscription.subscription_id,'subscription unsubscribe failed');
  await expectSqlError('subscription-session-reuse-rejected',()=>roleQuery('gurine_submission_api',`
    SELECT intake.get_subscription_session($1::char(64),'public-web')
  `,[subscriptionActive]),['28000']);
  record('subscription-session-lifecycle');

  const newTablePrivileges=(await client.query(`
    SELECT has_table_privilege('gurine_submission_api','intake.submission_sessions','SELECT') AS session_select,
           has_table_privilege('gurine_submission_api','intake.submission_sessions','INSERT') AS session_insert,
           has_table_privilege('gurine_submission_api','intake.correction_draft_attachments','UPDATE') AS correction_update,
           has_function_privilege('gurine_submission_api','ops.consume_assertion_jti(text,uuid,text,text,timestamptz,character)','EXECUTE') AS assertion_execute
  `)).rows[0];
  assert(!newTablePrivileges.session_select && !newTablePrivileges.session_insert && !newTablePrivileges.correction_update && newTablePrivileges.assertion_execute,
    `submission v13 least privilege mismatch: ${JSON.stringify(newTablePrivileges)}`);
  record('submission-session-least-privilege');

  const roles = (await client.query(`
    SELECT rolname, rolsuper, rolbypassrls
    FROM pg_roles
    WHERE rolname LIKE 'gurine_%'
  `)).rows;
  assert(roles.length >= 13 && roles.every((row) => !row.rolsuper && !row.rolbypassrls), `unsafe runtime role flags: ${JSON.stringify(roles)}`);
  record('runtime-roles-no-superuser-or-bypassrls', { roleCount: roles.length });

  const result = {
    specificationVersion: '13.0.0',
    result: 'PASS',
    postgresqlVersion: version,
    migrationCount: migrationFiles.length,
    migrationTreeSha256: digest,
    catalogCounts,
    concurrencyContractCount: concurrencySpec.contractCount,
    concurrencyCatalogResolved: concurrencySpec.contractCount,
    concurrencyContractSha256,
    expandedAssertionCount: results.length + concurrencySpec.contractCount,
    testCount: results.length,
    tests: results,
  };
  if (outputPath) await fs.writeFile(outputPath, `${JSON.stringify(result, null, 2)}\n`, 'utf8');
  console.log(JSON.stringify(result, null, 2));
}

try {
  await main();
} catch (error) {
  const failure = {
    specificationVersion: '13.0.0',
    result: 'FAIL',
    testCount: results.length,
    tests: results,
    error: error.message,
    stack: error.stack,
  };
  if (outputPath) await fs.writeFile(outputPath, `${JSON.stringify(failure, null, 2)}\n`, 'utf8');
  console.error(JSON.stringify(failure, null, 2));
  process.exitCode = 1;
} finally {
  if (client) await client.end().catch(() => {});
  if (server) await server.stop().catch(() => {});
  if (tempDir) await fs.rm(tempDir, { recursive: true, force: true }).catch(() => {});
}
