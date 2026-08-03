from __future__ import annotations
import hashlib
import json
import subprocess
import sys
from pathlib import Path
from .loaders import load_json, load_yaml
from .models import Validation

def validate(root: Path, result: Validation) -> None:
    catalog=load_yaml(root/'specs/detection/rule-evaluation-catalog.yaml'); result.require(len(catalog['rules'])==15,'expected 15 detection rules')
    manifest=load_yaml(root/catalog['evaluation']['manifest'])
    manifest_files={entry['rule_id']:entry for entry in manifest['files']}
    catalog_ids={rule['id'] for rule in catalog['rules']}
    result.require(len(catalog_ids)==15,'detection rule ids must be unique')
    result.require(len(manifest['files'])==len(manifest_files)==15,'detection eval manifest entries must be 15 unique rules')
    result.require(set(manifest_files)==catalog_ids,'detection eval manifest rule set differs from catalog')
    result.require(manifest.get('total_cases')==450,'detection eval manifest total must be 450')
    result.require(catalog['evaluation'].get('cases_per_rule')==30,'detection catalog cases per rule must be 30')
    result.require(catalog['evaluation'].get('total_cases')==450,'detection catalog total must be 450')
    total=0
    for rule in catalog['rules']:
        contract=load_yaml(root/rule['contract']); result.require(contract['rule_id']==rule['id'],f"{rule['id']}: rule contract mismatch")
        path=root/rule['eval_file']; cases=[json.loads(line) for line in path.read_text(encoding='utf-8').splitlines() if line.strip()]
        entry=manifest_files.get(rule['id'],{})
        result.require(entry.get('file')==rule['eval_file'],f"{rule['id']}: eval manifest path mismatch")
        result.require(entry.get('case_count')==len(cases),f"{rule['id']}: eval manifest case count mismatch")
        digest=hashlib.sha256(path.read_bytes()).hexdigest()
        result.require(entry.get('sha256')==digest,f"{rule['id']}: eval manifest sha256 mismatch")
        kinds={kind:sum(c['kind']==kind for c in cases) for kind in ['positive','false_positive','missing_data']}
        result.require(kinds=={'positive':10,'false_positive':15,'missing_data':5},f"{rule['id']}: eval distribution {kinds}")
        for case in cases:
            input_value=case.get('input'); concrete=isinstance(input_value,dict) and bool(input_value) and 'seed' not in input_value 
            result.require(concrete,f"{rule['id']}:{case.get('id')}: non-concrete input")
            result.require(isinstance(case.get('expected'),dict) and bool(case['expected']),f"{rule['id']}:{case.get('id')}: expected output missing")
        total+=len(cases)
    output=root/'verification/detection-reference.json'
    proc=subprocess.run([sys.executable,'-B',str(root/'specs/detection/reference_evaluator.py'),'--json-output',str(output)],cwd=root,text=True,capture_output=True)
    result.require(proc.returncode==0,f'detection reference evaluator failed: {proc.stdout}{proc.stderr}')
    if output.is_file():
        evidence=load_json(output); result.require(evidence.get('result')=='PASS' and evidence.get('total')==450,'detection reference evidence is not PASS/450')
    result.require(total==450,f'expected 450 detection cases, found {total}')
    result.stats.update({'detection_rules':15,'rule_evaluation_cases':total,'detection_reference':'PASS' if proc.returncode==0 else 'FAIL'})
