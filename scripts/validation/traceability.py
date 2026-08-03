from __future__ import annotations
from pathlib import Path
from .loaders import load_yaml
from .models import Validation

def validate(root: Path, result: Validation) -> None:
    trace=load_yaml(root/'specs/traceability/final-traceability.yaml')
    operations={o['operation_id']:o for o in load_yaml(root/'specs/api/operation-contracts.yaml')['operations']}
    persistence={o['operation_id']:o for o in load_yaml(root/'specs/api/operation-persistence.yaml')['operations']}
    screens={s['id']:s for s in load_yaml(root/'specs/ui/screen-catalog.yaml')['screens']}
    expected={'screens':94,'operations':217,'query_operations':110,'command_operations':107,'http_write_operations':104,'database_tables':107,'database_migrations':24,'roles':15,'capabilities':31,'events':99,'acceptance_scenarios':271,'public_operations':43,'submission_operations':34,'control_operations':134,'identity_operations':6,'commands':107,'queries':110}
    result.require(trace['counts']==expected,f'traceability counts differ: {trace["counts"]}')
    result.require({s['screen_id'] for s in trace['screens']}==set(screens),'traceability screen set differs')
    traced={o['operation_id']:o for o in trace['operations']}; result.require(set(traced)==set(operations),'traceability operation set differs')
    for oid,op in operations.items():
        item=traced[oid]; p=persistence[oid]
        for key,trace_key in [('api','api'),('method','method'),('path','path'),('operation_kind','kind'),('request_schema','request_schema'),('response_schema','response_schema'),('success_status','success_status')]: result.require(item[trace_key]==op[key],f'{oid}: trace {trace_key} mismatch')
        for key in ['repository_methods','statements','domain_events','integration_events','audit_action']: result.require(item[key]==p[key],f'{oid}: trace {key} mismatch')
        for key in ['handler','application','integration_test','contract_test']: result.require(bool(item.get(key)),f'{oid}: trace missing {key}')
    internal=load_yaml(root/'specs/traceability/internal-identity-traceability.yaml'); internal_openapi=load_yaml(root/'specs/api/identity-service-internal.openapi.yaml'); expected_internal={node['operationId'] for item in internal_openapi['paths'].values() for node in item.values() if isinstance(node,dict) and node.get('operationId')}; internal_by={o['operation_id']:o for o in internal['operations']}; result.require(internal['status']=='FINAL' and internal['operation_count']==9,'internal identity traceability header mismatch'); result.require(set(internal_by)==expected_internal,'internal identity traceability operation set differs');
    for oid,item in internal_by.items():
        for key in ['handler','application','persistence','generated_client','integration_test','contract_test']: result.require(bool(item.get(key)),f'{oid}: internal identity trace missing {key}')
        result.require(item['auth']=='service-assertion',f'{oid}: internal identity auth mismatch')
    result.stats.update({'trace_screens':len(trace['screens']),'trace_operations':len(trace['operations']),'internal_identity_trace_operations':len(internal_by)})
