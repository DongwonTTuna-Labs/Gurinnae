#!/usr/bin/env python3
from __future__ import annotations
import hashlib, json, os
from pathlib import Path

EXPECTED_RUNTIME_MIGRATIONS = 30
EXPECTED_ADDITIVE_MIGRATIONS = (
    "0025_evidence_snapshots_and_search.sql",
    "0026_agent_action_approval.sql",
    "0027_communication_consent_delivery.sql",
    "0028_governance_operations.sql",
    "0029_product_economics.sql",
    "0030_v13_submission_session_hardening.sql",
)

root=Path(__file__).resolve().parents[1]
excluded={'MANIFEST.md','MANIFEST.sha256'}
excluded_directories={
    '.git','.svelte-kit','artifacts','build','node_modules','playwright-report',
    'target','test-results','__pycache__','.authority-readonly-v13',
}
entries=[]
for path in sorted(p for p in root.rglob('*') if p.is_file()):
    rel=path.relative_to(root).as_posix()
    if (
        rel in excluded
        or any(part in excluded_directories for part in path.relative_to(root).parts)
        or path.suffix in {'.pyc','.pyo'}
    ):
        continue
    entries.append((hashlib.sha256(path.read_bytes()).hexdigest(),rel,path.stat().st_size))
runtime_migrations = sorted((root / 'db/migrations').glob('[0-9][0-9][0-9][0-9]_*.sql'))
runtime_names = tuple(path.name for path in runtime_migrations)
if len(runtime_names) != EXPECTED_RUNTIME_MIGRATIONS:
    raise SystemExit(
        f'final runtime migration count must be {EXPECTED_RUNTIME_MIGRATIONS}, '
        f'found {len(runtime_names)}'
    )
if runtime_names[:24] != tuple(
    path.name
    for path in sorted((root / 'specs/database/migrations').glob('[0-9][0-9][0-9][0-9]_*.sql'))
):
    raise SystemExit('runtime migration prefix differs from the hash-pinned authority base')
if runtime_names[24:] != EXPECTED_ADDITIVE_MIGRATIONS:
    raise SystemExit(
        'runtime additive migration set differs: '
        f'expected {EXPECTED_ADDITIVE_MIGRATIONS}, found {runtime_names[24:]}'
    )
(root/'MANIFEST.sha256').write_text(''.join(f'{digest}  {rel}\n' for digest,rel,_ in entries),encoding='utf-8')
stats=json.loads((root/'verification/static-validation.json').read_text())['stats']
size=sum(item[2] for item in entries)
archive_root=os.environ.get('GURINE_MANIFEST_ARCHIVE_ROOT','source')
md=f'''# Package Manifest — Gurine Source Tree v13.0.0

- Archive root: `{archive_root}/`
- Manifested files: **{len(entries)}**
- Manifested bytes: **{size}**
- Hash algorithm: **SHA-256**
- Manifest excludes its two circular digest files and generated build/cache output.

## Authority counts

- Screens: {stats['screens']}
- Operations: {stats['operations']} ({stats['query_operations']} queries / {stats['command_operations']} commands)
- Database migrations/tables: authority base {stats['database_migrations']} / runtime {len(runtime_names)} / {stats['database_tables']}
- Events: {stats['events']}
- Agent/detection evaluation cases: {stats['agent_eval_cases']} / {stats['rule_evaluation_cases']}
- Acceptance features/scenarios: {stats['acceptance_features']} / {stats['acceptance_scenarios']}

`MANIFEST.sha256` contains one digest and repository-relative path per line.
'''
(root/'MANIFEST.md').write_text(md,encoding='utf-8')
print(f'wrote {len(entries)} entries, {size} bytes')
