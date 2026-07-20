from __future__ import annotations
import json, subprocess, sys
from pathlib import Path
from .loaders import load_json, load_yaml
from .models import Validation

def validate(root: Path, result: Validation) -> None:
    catalog=load_yaml(root/'specs/detection/rule-evaluation-catalog.yaml'); result.require(len(catalog['rules'])==10,'expected 10 detection rules')
    total=0
    for rule in catalog['rules']:
        contract=load_yaml(root/rule['contract']); result.require(contract['rule_id']==rule['id'],f"{rule['id']}: rule contract mismatch")
        path=root/rule['eval_file']; cases=[json.loads(line) for line in path.read_text(encoding='utf-8').splitlines() if line.strip()]
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
        evidence=load_json(output); result.require(evidence.get('result')=='PASS' and evidence.get('total')==300,'detection reference evidence is not PASS/300')
    result.require(total==300,f'expected 300 detection cases, found {total}')
    result.stats.update({'detection_rules':10,'rule_evaluation_cases':total,'detection_reference':'PASS' if proc.returncode==0 else 'FAIL'})
