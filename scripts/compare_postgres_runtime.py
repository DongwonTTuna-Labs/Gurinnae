#!/usr/bin/env python3
from pathlib import Path
import argparse,json,sys
p=argparse.ArgumentParser(); p.add_argument('actual'); p.add_argument('--baseline',default='verification/postgres-runtime-baseline.json'); a=p.parse_args()
root=Path(__file__).resolve().parents[1]; actual=json.loads(Path(a.actual).read_text()); baseline=json.loads((root/a.baseline).read_text())
errors=[]
for key in ['specificationVersion','result','postgresqlVersion','migrationCount','catalogCounts','concurrencyContractCount','concurrencyCatalogResolved']:
 if actual.get(key)!=baseline.get(key): errors.append(f'{key}: {actual.get(key)!r} != {baseline.get(key)!r}')
names={x['name'] for x in actual.get('tests',[]) if x.get('result')=='PASS'}
for name in baseline['requiredTests']:
 if name not in names: errors.append(f'missing required PASS test: {name}')
if actual.get('testCount')!=len(actual.get('tests',[])): errors.append('testCount differs from tests length')
if errors:
 print('\n'.join('ERROR: '+x for x in errors)); sys.exit(1)
print(json.dumps({'result':'PASS','requiredTests':len(baseline['requiredTests']),'actualTests':actual['testCount'],'catalogCounts':actual['catalogCounts']},indent=2))
