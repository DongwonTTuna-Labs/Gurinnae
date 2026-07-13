from __future__ import annotations
import re
from pathlib import Path
from .loaders import load_yaml
from .models import Validation

ID_RE=re.compile(r'^# scenario-id: ([A-Z0-9_-]+)$')
SC_RE=re.compile(r'^\s*Scenario(?: Outline)?:\s*(.+)$')

def validate(root: Path, result: Validation) -> None:
    directory=root/'tests/acceptance'; paths=sorted(directory.glob('*.feature'))
    catalog=load_yaml(directory/'acceptance-catalog.yaml'); mapping=load_yaml(directory/'executable-mapping.yaml')
    result.require(len(paths)==35,'expected 35 acceptance features')
    result.require({x['file'] for x in catalog['features']}=={p.name for p in paths},'acceptance catalog differs from feature files')
    scenarios=[]
    for path in paths:
        lines=path.read_text(encoding='utf-8').splitlines(); first=next((x for x in lines if x.strip()),'')
        result.require('@final' in first,f'{path.name}: missing @final')
        pending=None
        for line in lines:
            match=ID_RE.match(line.strip())
            if match: pending=match.group(1); continue
            sm=SC_RE.match(line)
            if sm:
                result.require(pending is not None,f'{path.name}:{sm.group(1)} missing stable scenario ID')
                if pending: scenarios.append((pending,path.name,sm.group(1).strip()))
                pending=None
    ids=[x[0] for x in scenarios]; result.require(len(ids)==len(set(ids)),'duplicate acceptance scenario IDs')
    result.require(len(scenarios)==catalog['scenario_count']==mapping['scenario_count']==271,f'acceptance scenario count mismatch {len(scenarios)}')
    mapped={x['scenario_id']:x for x in mapping['scenarios']}; result.require(set(mapped)==set(ids),'executable mapping does not match scenarios')
    for sid,file,title in scenarios:
        item=mapped[sid]; result.require(item['feature_file']==f'tests/acceptance/{file}' and item['scenario_title']==title,f'{sid}: mapping identity mismatch')
        result.require(item['skip_policy']=='FORBIDDEN',f'{sid}: skip must be forbidden')
        for key in ['implementation_test_path','command','environment','required_evidence']: result.require(bool(item.get(key)),f'{sid}: missing {key}')
    result.stats.update({'acceptance_features':len(paths),'acceptance_scenarios':len(scenarios),'acceptance_executable_mappings':len(mapped)})
