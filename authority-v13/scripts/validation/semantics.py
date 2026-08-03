from __future__ import annotations
import re
from pathlib import Path
from jsonschema import Draft202012Validator
from referencing import Registry, Resource
from .loaders import load_json, load_yaml
from .models import Validation

EVENT_RE=re.compile(r'^[a-z][a-z0-9_]*(?:\.[a-z0-9_]+)*\.v[1-9][0-9]*$')
MUTATING={'INSERT','UPDATE','DELETE','UPSERT','REPLACE_RELATIONS','CALL'}

def validate(root: Path, result: Validation) -> None:
    operations=load_yaml(root/'specs/api/operation-contracts.yaml')['operations']; op_by={o['operation_id']:o for o in operations}
    concurrency_doc=load_yaml(root/'specs/application/optimistic-concurrency.yaml'); concurrency_by={c['operation_id']:c for c in concurrency_doc['contracts']}
    matrix_by={x['operation_id']:x for x in load_yaml(root/'specs/database/operation-table-matrix.yaml')['operations']}
    trace_by={x['operation_id']:x for x in load_yaml(root/'specs/traceability/final-traceability.yaml')['operations']}
    commands=load_yaml(root/'specs/application/command-semantics.yaml')['commands']; cmd_by={c['operation_id']:c for c in commands}
    persistence=load_yaml(root/'specs/api/operation-persistence.yaml')['operations']; per_by={p['operation_id']:p for p in persistence}
    events=load_yaml(root/'specs/events/event-catalog.yaml')['events']; event_by={e['event_type']:e for e in events}
    consumer_doc=load_yaml(root/'specs/events/consumer-catalog.yaml'); terminal=set(consumer_doc.get('terminal_observability_events',[]))
    command_ids={o['operation_id'] for o in operations if o['operation_kind']=='COMMAND'}
    assurance_doc=load_yaml(root/'specs/auth/assurance-policy.yaml')
    assurance_by={item['operation_id']:item for item in assurance_doc['commands']}
    result.require(set(assurance_by)==command_ids,'assurance command set differs from command operations')
    result.require(set(cmd_by)==command_ids,f'command semantics mismatch: missing={sorted(command_ids-set(cmd_by))[:5]} extra={sorted(set(cmd_by)-command_ids)[:5]}')
    result.require(set(per_by)==set(op_by),'persistence mapping is incomplete')
    result.require(len(event_by)==99,'expected 99 events')
    accepted={e for c in consumer_doc['consumers'] for e in c['accepted_event_types']}
    produced={}
    for command in commands:
        for event in command['domain_events']+command['integration_events']: produced.setdefault(event,set()).add(command['operation_id'])
    for event_type,event in event_by.items():
        result.require(set(event.get('producer_operations',[]))==produced.get(event_type,set()),f'{event_type}: producer operation mapping differs')
        result.require(bool(EVENT_RE.fullmatch(event_type)),f'invalid event type {event_type}')
        payload=root/'specs/events'/event['payload_schema']; result.require(payload.is_file(),f'{event_type}: payload schema missing')
        if payload.is_file(): Draft202012Validator.check_schema(load_json(payload))
        if event['category']=='INTEGRATION': result.require(bool(event['consumers']) or event_type in terminal,f'{event_type}: integration event has no consumer or terminal declaration')
    integration={e['event_type'] for e in events if e['category']=='INTEGRATION'}
    result.require(integration-terminal <= accepted,f'integration events missing consumer declarations: {sorted(integration-terminal-accepted)}')
    for oid,op in op_by.items():
        p=per_by[oid]; result.require(p['operation_kind']==op['operation_kind'],f'{oid}: persistence kind mismatch')
        mutating=[s for s in p.get('statements',[]) if s['verb'] in MUTATING]
        if op['operation_kind']=='QUERY':
            result.require(not mutating,f'{oid}: query has mutating statement')
            result.require(not p.get('domain_events') and not p.get('integration_events'),f'{oid}: query emits events')
        else:
            c=cmd_by[oid]
            policy_record=assurance_by[oid]; auth=c['authorization']; policy=op['assurance_policy']; level=policy['default']
            result.require(policy_record['assurance_policy']==policy==auth['assurance_policy']==trace_by[oid]['assurance_policy'],f'{oid}: assurance policy differs')
            result.require(level==policy_record['assurance_level']==auth['assurance_level']==op.get('assurance_level'),f'{oid}: assurance default level differs')
            static_step_up=policy['mode']=='STATIC' and level=='STEP_UP'
            result.require(auth['step_up_required']==policy_record['step_up_required']==op.get('step_up_required')==static_step_up,f'{oid}: static step-up flag differs')
            step_up_possible=policy.get('step_up_possible') is True or any(condition.get('required_level')=='STEP_UP' for condition in policy.get('conditions',[]))
            recent_possible=level=='RECENT_SESSION' or any(condition.get('required_level')=='RECENT_SESSION' for condition in policy.get('conditions',[]))
            auth_errors=set(op['authorization_errors'])
            result.require(('STEP_UP_REQUIRED' in auth_errors)==step_up_possible,f'{oid}: STEP_UP_REQUIRED differs from policy branches')
            result.require(('RECENT_AUTH_REQUIRED' in auth_errors)==recent_possible,f'{oid}: RECENT_AUTH_REQUIRED differs from policy branches')
            if recent_possible:
                result.require(auth.get('recent_session_max_age_seconds',assurance_doc['recent_session_max_age_seconds'])==assurance_doc['recent_session_max_age_seconds'],f'{oid}: recent-session age differs')
            result.require(c['method']==op['method'] and c['api']==op['api'],f'{oid}: command transport mismatch')
            result.require(c['receipt']==op['response_schema'],f'{oid}: receipt mismatch')
            result.require(c['repository_methods']==p['repository_methods'],f'{oid}: repository methods mismatch')
            result.require(c['transaction']['statements']==p['statements'],f'{oid}: statement mapping mismatch')
            result.require(c['domain_events']==p['domain_events'] and c['integration_events']==p['integration_events'],f'{oid}: event mapping mismatch')
            result.require(c['transaction']['audit_action']==p['audit_action'],f'{oid}: audit action mismatch')
            layer_map={'transport':'transport_errors','authorization':'authorization_errors','concurrency':'concurrency_errors','domain':'domain_errors','provider':'provider_errors','internal':'internal_errors'}
            for key,field in layer_map.items(): result.require(c['errors'][key]==op[field],f'{oid}: {key} errors mismatch')
            for event in c['domain_events']+c['integration_events']: result.require(event in event_by,f'{oid}: unknown event {event}')

    import re as _re
    versioned={}
    for operation in operations:
        fields=[f for f in operation.get('request_fields',[]) if _re.sub(r'[_-]','',f['name']).lower() in {'expectedversion','expectedcaseversion'}]
        if fields: versioned[operation['operation_id']]=fields[0]['name']
    result.require(set(concurrency_by)==set(versioned),f'optimistic-concurrency catalog differs from versioned operations: missing={sorted(set(versioned)-set(concurrency_by))[:5]} extra={sorted(set(concurrency_by)-set(versioned))[:5]}')
    for oid,field in versioned.items():
        operation=op_by[oid]; command=cmd_by[oid]; persistence_item=per_by[oid]; catalog_record=concurrency_by[oid]; contract={k:v for k,v in catalog_record.items() if k!='operation_id'}
        result.require(operation.get('optimistic_concurrency')=='required',f'{oid}: operation does not require optimistic concurrency')
        result.require(operation.get('concurrency_contract')==contract,f'{oid}: operation concurrency contract differs')
        result.require(command.get('concurrency')==contract,f'{oid}: command concurrency contract differs')
        result.require(persistence_item.get('concurrency')==contract,f'{oid}: persistence concurrency contract differs')
        result.require(matrix_by[oid].get('concurrency')==contract,f'{oid}: table matrix concurrency contract differs')
        result.require(trace_by[oid].get('concurrency')==contract,f'{oid}: traceability concurrency contract differs')
        result.require(contract['version_field']==field and f':{field}' in contract['guard_version_predicate'],f'{oid}: declared version field is not used in guard predicate')
        statements=command['transaction']['statements']
        guards=[s for s in statements if s.get('relation')==contract['guard_relation'] and s.get('version_predicate')==contract['guard_version_predicate']]
        result.require(bool(guards),f'{oid}: exact version guard statement missing')
        execution=contract.get('execution',{})
        if execution.get('kind')=='SECURITY_DEFINER_FUNCTION':
            calls=[s for s in statements if s.get('verb')=='CALL' and s.get('relation')==execution.get('function') and s.get('function_signature')==execution.get('signature')]
            result.require(len(calls)==1,f'{oid}: exact SECURITY DEFINER function call contract missing or duplicated')
            effect=contract.get('version_effect')
            mutations=[s for s in statements if s.get('relation')==contract['mutation_relation'] and s.get('verb') in {'UPDATE','DELETE','UPSERT','INSERT'}]
            result.require(bool(mutations),f'{oid}: procedure-owned mutation contract missing')
            if effect=='INCREMENT_ONE':
                result.require(any(s.get('verb')=='UPDATE' and s.get('version_predicate')==contract['guard_version_predicate'] and s.get('version_mutation')==contract['version_mutation'] for s in mutations),f'{oid}: procedure does not increment the exact guarded version')
            elif effect=='CREATE_AT_ONE_OR_INCREMENT_ONE':
                result.require(any(s.get('verb')=='UPSERT' and ':expectedVersion = 0' in s.get('version_predicate','') and s.get('version_mutation')==contract['version_mutation'] for s in mutations),f'{oid}: create-or-increment procedure semantics missing')
            elif effect=='GUARD_ONLY_TERMINALIZE':
                requirements=contract.get('terminal_requirements',[])
                result.require(bool(requirements),f'{oid}: terminal requirements missing')
                for requirement in requirements:
                    matches=[statement for statement in statements if statement.get('verb')==requirement.get('verb') and statement.get('relation')==requirement.get('relation')]
                    result.require(bool(matches),f"{oid}: terminal statement missing {requirement.get('verb')} {requirement.get('relation')}")
                    if matches and requirement.get('version_mutation') is not None:
                        result.require(any(statement.get('version_mutation')==requirement['version_mutation'] for statement in matches),f"{oid}: terminal version mutation differs for {requirement.get('relation')}")
                    if matches and requirement.get('state_contains') is not None:
                        result.require(any(requirement['state_contains'] in statement.get('state_mutation','') for statement in matches),f"{oid}: terminal state mutation differs for {requirement.get('relation')}")
            else:
                result.error(f'{oid}: unsupported procedure-backed version_effect {effect!r}')
        else:
            mutations=[s for s in statements if s.get('relation')==contract['mutation_relation'] and s.get('verb') in {'UPDATE','DELETE'} and s.get('version_predicate')==contract['guard_version_predicate']]
            result.require(bool(mutations),f'{oid}: exact versioned mutation missing')
            if all(s.get('verb')!='DELETE' for s in mutations): result.require(any(s.get('version_mutation')==contract['version_mutation'] for s in mutations),f'{oid}: version is not incremented exactly once')

        declared_placeholders=set(contract.get('request_placeholders',[]))|set(contract.get('context_placeholders',[]))
        actual_placeholders=set()
        for key in ['guard_identity_predicate','guard_version_predicate','mutation_identity_predicate','version_mutation']:
            actual_placeholders.update(_re.findall(r':([A-Za-z][A-Za-z0-9]*)',str(contract.get(key,''))))
        request_fields={field['name'] for field in operation.get('request_fields',[])}
        result.require(set(contract.get('request_placeholders',[]))<=request_fields,f'{oid}: concurrency request placeholder is not a request field')
        result.require(set(contract.get('context_placeholders',[]))<={'actorUserId','sessionScopeId'},f'{oid}: unregistered concurrency context placeholder')
        result.require(declared_placeholders==actual_placeholders,f'{oid}: declared concurrency placeholders differ from predicates')
        result.require(bool(contract.get('guard_columns')),f'{oid}: guard_columns missing')
        result.require(bool(contract.get('mutation_columns')),f'{oid}: mutation_columns missing')
        result.require(contract.get('zero_rows_resolution',{}).get('existing_error') in operation['error_codes'],f'{oid}: concurrency existing-error is not exposed by the operation')

    runtime_projection=load_json(root/'specs/application/optimistic-concurrency.runtime.json')
    result.require(runtime_projection['specificationVersion']=='13.0.0','runtime concurrency projection version mismatch')
    result.require(runtime_projection['contractCount']==len(concurrency_by),'runtime concurrency projection count mismatch')
    runtime_by={item['operationId']:item for item in runtime_projection['contracts']}
    result.require(set(runtime_by)==set(concurrency_by),'runtime concurrency projection operation set differs')
    for oid,item in runtime_by.items():
        contract=concurrency_by[oid]
        result.require(item['versionField']==contract['version_field'],f'{oid}: runtime version field mismatch')
        result.require(item['guardRelation']==contract['guard_relation'] and item['guardColumns']==contract['guard_columns'],f'{oid}: runtime guard catalog differs')
        result.require(item['mutationRelation']==contract['mutation_relation'] and item['mutationColumns']==contract['mutation_columns'],f'{oid}: runtime mutation catalog differs')
        result.require(item['requestPlaceholders']==contract['request_placeholders'] and item['contextPlaceholders']==contract['context_placeholders'],f'{oid}: runtime placeholder catalog differs')

    # Validate one concrete event envelope and payload per catalog entry.
    registry=Registry()
    for schema_path in sorted((root/'specs/schemas').glob('*.json')):
        schema_value=load_json(schema_path)
        if schema_value.get('$id'): registry=registry.with_resource(schema_value['$id'],Resource.from_contents(schema_value))
    envelope=load_json(root/'specs/schemas/event-envelope.schema.json'); ev_validator=Draft202012Validator(envelope,registry=registry)
    samples=sorted((root/'fixtures/events/catalog').glob('*.json')); result.require(len(samples)==99,f'expected 99 event samples, found {len(samples)}')
    for sample_path in samples:
        sample=load_json(sample_path); errs=list(ev_validator.iter_errors(sample)); result.require(not errs,f'{sample_path.name}: envelope invalid: {errs[0].message if errs else ""}')
        event=event_by.get(sample.get('event_type')); result.require(event is not None,f'{sample_path.name}: unknown event type')
        if event:
            pv=Draft202012Validator(load_json(root/'specs/events'/event['payload_schema'])); pe=list(pv.iter_errors(sample['payload']))
            result.require(not pe,f'{sample_path.name}: payload invalid: {pe[0].message if pe else ""}')
    result.stats.update({'optimistic_concurrency_contracts':len(concurrency_by),'command_semantics':len(commands),'persistence_mappings':len(persistence),'events':len(events),'integration_events':len(integration),'event_consumers':len(consumer_doc['consumers']),'event_fixture_samples':len(samples)})
