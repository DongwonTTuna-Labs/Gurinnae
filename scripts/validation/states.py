from __future__ import annotations
import json, re
from collections import deque
from pathlib import Path
from .loaders import load_json, load_yaml
from .models import Validation

SCHEMA_ENUMS={
 'investigation_state':('investigation-case.schema.json',['properties','investigation_state','enum']),
 'publication_state':('investigation-case.schema.json',['properties','publication_state','enum']),
 'resolution_code':('investigation-case.schema.json',['properties','resolution_code','enum']),
 'signal_status':('anomaly-signal.schema.json',['properties','status','enum']),
 'evidence_verification_status':('evidence.schema.json',['properties','verification_status','enum']),
 'claim_validation_status':('investigation-case.schema.json',['properties','claims','items','properties','status','enum']),
 'review_decision':('review-decision.schema.json',['properties','decision','enum']),
 'hypothesis_status':('investigation-case.schema.json',['properties','hypotheses','items','properties','status','enum']),
 'claim_type':('investigation-case.schema.json',['properties','claims','items','properties','claim_type','enum']),
 'response_summary_status':('investigation-case.schema.json',['properties','response_summary','properties','status','enum']),
 'contract_status':('contract.schema.json',['properties','status','enum']),
 'source_document_processing_status':('source-document.schema.json',['properties','processing_status','enum']),
 'source_record_status':('source-document.schema.json',['properties','record_status','enum']),
}

def _at(doc,path):
    for key in path: doc=doc[key]
    return doc

def validate(root: Path, result: Validation) -> None:
    model=load_yaml(root/'specs/domain/state-machines.yaml'); enums=model['enums']
    result.require(model['status']=='FINAL','state model must be FINAL')
    for name,(file,path) in SCHEMA_ENUMS.items(): result.require(_at(load_json(root/'specs/schemas'/file),path)==enums[name],f'{name}: JSON Schema differs from canonical state model')
    transitions=model['case_transitions']; events={e['event_type'] for e in load_yaml(root/'specs/events/event-catalog.yaml')['events']}
    capabilities={c['id'] for c in load_yaml(root/'specs/ui/roles-and-permissions.yaml')['capabilities']}
    graph={s:set() for s in enums['investigation_state']}
    for t in transitions:
        result.require(t['to'] in graph,f"{t['id']}: invalid target state")
        result.require(t['capability'] in capabilities,f"{t['id']}: unknown capability")
        result.require(bool(t.get('guards')) and bool(t.get('audit_action')),f"{t['id']}: guards/audit missing")
        for source in t['from']:
            result.require(source in graph,f"{t['id']}: invalid source state"); graph.setdefault(source,set()).add(t['to'])
        for event in t.get('domain_events',[]): result.require(event in events,f"{t['id']}: unknown event {event}")
    reachable={'SIGNAL_DETECTED'}; queue=deque(reachable)
    while queue:
        for nxt in graph.get(queue.popleft(),()):
            if nxt not in reachable: reachable.add(nxt); queue.append(nxt)
    result.require(reachable==set(graph),f'unreachable investigation states: {sorted(set(graph)-reachable)}')
    tests=load_yaml(root/'specs/domain/state-transition-tests.yaml')
    positives=tests['positive_transition_cases']; negatives=tests['negative_transition_cases']; cross=tests['cross_axis_cases']
    declared={(s,t['to'],t['capability']) for t in transitions for s in t['from']}
    result.require({(c['from'],c['to'],c['capability']) for c in positives}==declared,'positive transition tests do not cover declared transitions')
    result.require(all(c['expected']=='DENY' for c in negatives),'negative transition cases must deny')
    result.require(any(c['expected']=='ALLOW' for c in cross) and any(c['expected']=='DENY' for c in cross),'cross-axis tests need allow and deny cases')
    sql='\n'.join(p.read_text(encoding='utf-8') for p in sorted((root/'specs/database/migrations').glob('*.sql')))
    for enum_name in ['investigation_state','publication_state','resolution_code','signal_status','review_decision','job_status','source_run_status']:
        for value in enums[enum_name]: result.require(f"'{value}'" in sql,f'{enum_name}: SQL does not contain {value}')
    result.stats.update({'canonical_state_enums':len(enums),'case_transitions':len(transitions),'state_positive_cases':len(positives),'state_negative_cases':len(negatives),'state_cross_axis_cases':len(cross)})
