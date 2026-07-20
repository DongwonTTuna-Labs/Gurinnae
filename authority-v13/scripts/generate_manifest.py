#!/usr/bin/env python3
from __future__ import annotations
import hashlib, json
from pathlib import Path
root=Path(__file__).resolve().parents[1]
excluded={'MANIFEST.md','MANIFEST.sha256'}
entries=[]
for path in sorted(p for p in root.rglob('*') if p.is_file()):
    rel=path.relative_to(root).as_posix()
    if rel in excluded or rel.startswith('.git/'): continue
    entries.append((hashlib.sha256(path.read_bytes()).hexdigest(),rel,path.stat().st_size))
(root/'MANIFEST.sha256').write_text(''.join(f'{digest}  {rel}\n' for digest,rel,_ in entries),encoding='utf-8')
stats=json.loads((root/'verification/static-validation.json').read_text())['stats']
size=sum(item[2] for item in entries)
md=f'''# Package Manifest — Gurine Codex Final Authority Pack v13.0.0

- Archive root: `gurine/`
- Manifested files: **{len(entries)}**
- Manifested bytes: **{size}**
- Hash algorithm: **SHA-256**
- Manifest excludes only `MANIFEST.md` and `MANIFEST.sha256` to avoid a circular digest.

## Authority counts

- Screens: {stats['screens']}
- Operations: {stats['operations']} ({stats['query_operations']} queries / {stats['command_operations']} commands)
- Database migrations/tables: {stats['database_migrations']} / {stats['database_tables']}
- Events: {stats['events']}
- Agent/detection evaluation cases: {stats['agent_eval_cases']} / {stats['rule_evaluation_cases']}
- Acceptance features/scenarios: {stats['acceptance_features']} / {stats['acceptance_scenarios']}

`MANIFEST.sha256` contains one digest and repository-relative path per line.
'''
(root/'MANIFEST.md').write_text(md,encoding='utf-8')
print(f'wrote {len(entries)} entries, {size} bytes')
