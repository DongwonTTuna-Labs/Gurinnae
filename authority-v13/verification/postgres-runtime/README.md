# PostgreSQL 18.4 Authority Runtime Verification

Run only through `make verify-postgres-runtime`.

The verifier writes dynamic UUID/hash evidence to a temporary file outside the authority tree. `scripts/compare_postgres_runtime.py` compares stable semantic fields and mandatory canary names with `verification/postgres-runtime-baseline.json`. The Make target computes the Manifest-bound authority tree digest before and after execution and fails if any tracked byte changes.

A direct debug run may use:

```bash
cd verification/postgres-runtime
npm ci --ignore-scripts --no-audit --no-fund
npm run verify -- --output /tmp/gurine-postgres-runtime.json
cd ../..
python3 scripts/compare_postgres_runtime.py /tmp/gurine-postgres-runtime.json
rm -rf verification/postgres-runtime/node_modules
```
