from __future__ import annotations
import collections
from pathlib import Path
from .loaders import load_yaml
from .models import Validation

INTERACTIONS={'NAVIGATION','DOWNLOAD','EXTERNAL_LINK','FORM_SUBMIT','COMMAND','DESTRUCTIVE_CONFIRMATION'}
ASSURANCE={'NONE','ANONYMOUS_PROOF','SCOPED_TOKEN','ACTIVE_SESSION','RECENT_SESSION','STEP_UP'}
PROPOSAL_ONLY_POLICY='PROPOSAL_ONLY_UNTIL_AUTHORIZED_EXECUTION'


def _external_operation_catalog(root: Path, result: Validation) -> dict[str, dict]:
    base_operations=load_yaml(root/'specs/api/operation-contracts.yaml')['operations']
    additive_contract=load_yaml(root/'specs/product/addendum-operation-contracts.yaml')
    additive_resources=load_yaml(root/'specs/product/addendum-resource-error-contracts.yaml')
    bindings=additive_resources.get('operation_bindings',{})
    additive_operations=[]
    for operation in additive_contract['operations']:
        binding=bindings.get(operation['operation_id'],{})
        additive_operations.append({
            **operation,
            'operation_kind':operation.get('kind'),
            'request_schema':binding.get('request_schema'),
            'response_schema':binding.get('success_schema',operation.get('response')),
            'success_status':binding.get('success_status'),
            'authorization_errors':operation.get('errors',[]),
            '_additive_external':True,
        })
    private_bindings=additive_resources.get('private_billing_gateway_operation_bindings',{})
    private_error_sets=additive_resources.get('private_billing_gateway_error_sets',{})
    private_operations=[]
    for operation_id,operation in additive_contract.get('private_billing_gateway_operations',{}).items():
        binding=private_bindings.get(operation_id,{})
        entrypoint=operation.get('entrypoint',{})
        result.require(binding.get('scope')=='PRIVATE_BILLING_GATEWAY',f'{operation_id}: private billing binding scope differs')
        result.require(binding.get('operation_kind')==operation.get('operation_kind'),f'{operation_id}: private billing operation kind differs')
        result.require(binding.get('request_schema')==operation.get('request_schema'),f'{operation_id}: private billing request schema differs')
        result.require(binding.get('success_schema')==operation.get('response_schema'),f'{operation_id}: private billing response schema differs')
        private_operations.append({
            'operation_id':operation_id,
            'operation_kind':operation.get('operation_kind'),
            'api':'billing-gateway-private',
            'method':entrypoint.get('method'),
            'path':entrypoint.get('path'),
            'request_schema':binding.get('request_schema'),
            'response_schema':binding.get('success_schema'),
            'success_status':binding.get('success_status'),
            'authorization_errors':private_error_sets.get(operation_id,[]),
            '_private_billing_gateway':True,
        })
    result.require(set(private_bindings)==set(additive_contract.get('private_billing_gateway_operations',{})),'private billing operation binding set mismatch')
    result.require(set(private_error_sets)==set(additive_contract.get('private_billing_gateway_operations',{})),'private billing error set mismatch')
    operations=[*base_operations,*additive_operations,*private_operations]
    counts=collections.Counter(operation['operation_id'] for operation in operations)
    duplicates=sorted(operation_id for operation_id,count in counts.items() if count != 1)
    result.require(not duplicates,f'duplicate external operation IDs across base/additive catalogs: {duplicates}')
    return {
        operation['operation_id']:operation
        for operation in operations
        if counts[operation['operation_id']]==1
    }


def _proposal_only_fences(root: Path, result: Validation, ops: dict[str, dict]) -> dict[tuple[str,str],dict]:
    contract=load_yaml(root/'specs/ui/screen-action-contracts.yaml')
    rows=[row for row in contract.get('legacy_side_door_fences',[]) if row.get('policy')==PROPOSAL_ONLY_POLICY]
    exact_counts=collections.Counter(
        (row.get('screen_id'),row.get('legacy_action_id'),row.get('legacy_operation_id'))
        for row in rows
    )
    duplicate_exact=sorted(key for key,count in exact_counts.items() if count != 1)
    result.require(not duplicate_exact,f'duplicate proposal-only fence triples: {duplicate_exact}')
    pair_counts=collections.Counter((row.get('screen_id'),row.get('legacy_action_id')) for row in rows)
    duplicate_pairs=sorted(key for key,count in pair_counts.items() if count != 1)
    result.require(not duplicate_pairs,f'ambiguous proposal-only fence action keys: {duplicate_pairs}')
    fences={}
    for row in rows:
        pair=(row.get('screen_id'),row.get('legacy_action_id'))
        triple=(*pair,row.get('legacy_operation_id'))
        entry=row.get('required_entry_operation')
        result.require(row.get('direct_effect_forbidden') is True,f'{triple}: proposal-only fence must forbid direct effects')
        result.require(entry in ops,f'{triple}: unknown required entry operation {entry}')
        if entry in ops:
            result.require(ops[entry].get('operation_kind')=='COMMAND',f'{triple}: required entry operation must be a command')
        if 'proposal_binding' in row:
            binding=row.get('proposal_binding')
            expected_fields={'actionKind','providerControl.operationId'}
            result.require(isinstance(binding,dict),f'{triple}: proposal_binding must be an object')
            if isinstance(binding,dict):
                result.require(set(binding)==expected_fields,f'{triple}: proposal_binding fields are not closed')
                result.require(binding.get('actionKind')=='PROVIDER_CONTROL',f'{triple}: proposal_binding actionKind differs')
                result.require(
                    binding.get('providerControl.operationId')==row.get('legacy_operation_id'),
                    f'{triple}: proposal_binding operation differs from legacy operation',
                )
        if exact_counts[triple]==1 and pair_counts[pair]==1 and entry in ops:
            fences[pair]=row
    return fences


def _action_operation(
    screen_id: str,
    action: dict,
    ops: dict[str, dict],
    fences: dict[tuple[str,str],dict],
    matched_fences: set[tuple[str,str]],
    result: Validation,
) -> tuple[str,dict] | None:
    operation_id=action.get('operation_id')
    result.require(operation_id in ops,f'{screen_id}:{action["id"]}: unknown operation {operation_id}')
    fence_key=(screen_id,action['id'])
    fence=fences.get(fence_key)
    if fence is None:
        return (operation_id,ops[operation_id]) if operation_id in ops else None
    matched_fences.add(fence_key)
    legacy_operation_id=fence['legacy_operation_id']
    result.require(
        operation_id==legacy_operation_id,
        f'{screen_id}:{action["id"]}: proposal-only fence operation {legacy_operation_id} != {operation_id}',
    )
    if operation_id!=legacy_operation_id:
        return None
    if 'proposal_binding' not in fence:
        return (operation_id,ops[operation_id]) if operation_id in ops else None
    entry=fence['required_entry_operation']
    return (entry,ops[entry]) if entry in ops else None


def _matches(condition: dict, request: dict) -> bool:
    rule=condition.get('when',{})
    field=rule.get('field')
    if field not in request:
        return False
    value=request[field]
    operator=rule.get('operator')
    if operator=='EQUALS':
        return value==rule.get('value')
    if operator=='IN':
        return value in rule.get('values',[])
    return False


def _resolve(policy: dict, request: dict) -> str:
    for condition in policy.get('conditions',[]):
        if _matches(condition,request):
            return condition['required_level']
    return policy['default']


def validate(root: Path, result: Validation) -> None:
    catalog=load_yaml(root/'specs/ui/screen-catalog.yaml'); manifest=load_yaml(root/'specs/ui/screen-build-manifest.yaml')
    components=load_yaml(root/'specs/ui/component-catalog.yaml'); ops=_external_operation_catalog(root,result)
    commands={c['operation_id']:c for c in load_yaml(root/'specs/application/command-semantics.yaml')['commands']}
    capabilities={c['id'] for c in load_yaml(root/'specs/ui/roles-and-permissions.yaml')['capabilities']}
    screens=catalog['screens']; result.require(len(screens)==95,f'expected 95 screens, found {len(screens)}')
    counts=collections.Counter(s['surface'] for s in screens); result.require(counts=={'public':35,'response':8,'internal':52},f'wrong screen counts {dict(counts)}')
    component_ids={c['id'] for c in components['components']}; result.require(len(component_ids)==58,'expected 58 components')
    proposal_fences=_proposal_only_fences(root,result,ops); matched_fences=set()
    ids=set(); routes=set(); manifest_by={s['id']:s for s in manifest['screens']}
    for screen in screens:
        sid=screen['id']; result.require(sid not in ids,f'duplicate screen {sid}'); ids.add(sid)
        key=(screen['surface'],screen['route']); result.require(key not in routes,f'duplicate route {key}'); routes.add(key)
        sections=screen['sections']; result.require([s['order'] for s in sections]==list(range(1,len(sections)+1)),f'{sid}: section order invalid')
        for section in sections: result.require(section['component'] in component_ids,f"{sid}: unknown component {section['component']}")
        for req in screen.get('data_requirements',[]):
            oid=req['operation_id']; result.require(req['status']=='READY' and oid in ops,f'{sid}: invalid operation {oid}')
            if oid in ops:
                fields=['api','method','path','request_schema','response_schema']
                if 'success_status' in req or ops[oid].get('_private_billing_gateway'):
                    fields.append('success_status')
                for field in fields: result.require(req.get(field)==ops[oid].get(field),f'{sid}:{oid}: {field} mismatch')
                if ops[oid].get('_private_billing_gateway'):
                    result.require(req.get('server_only') is True,f'{sid}:{oid}: private billing query must be server-only')
        for action in screen.get('actions',[]):
            interaction=action.get('interaction_kind'); level=action.get('assurance_level')
            result.require(interaction in INTERACTIONS,f"{sid}:{action['id']}: invalid interaction_kind")
            result.require(level in ASSURANCE,f"{sid}:{action['id']}: invalid assurance_level")
            result.require(action.get('confirmation_required')==(interaction=='DESTRUCTIVE_CONFIRMATION'),f"{sid}:{action['id']}: confirmation policy mismatch")
            oid=action.get('operation_id'); has=bool(oid) or bool(action.get('local_only')) or interaction in {'NAVIGATION','DOWNLOAD','EXTERNAL_LINK'}
            result.require(has,f"{sid}: action {action['id']} lacks contract")
            if oid:
                resolved=_action_operation(sid,action,ops,proposal_fences,matched_fences,result)
                if resolved:
                    contract_oid,op=resolved; result.require(action.get('capability') in {'none',op.get('capability')},f'{sid}:{contract_oid}: capability differs')
                    request={**action.get('fixed_request',{}),**action.get('request_discriminator',{})}
                    if op.get('_private_billing_gateway'):
                        result.require(action.get('server_only') is True and action.get('browser_direct') is False,f'{sid}:{contract_oid}: private billing action must be BFF-only')
                        expected='NONE'
                    elif op['operation_kind']=='QUERY':
                        if op['api']=='control-api': expected='ACTIVE_SESSION'
                        elif op['api']=='identity-provider' and op.get('auth')!='anonymous': expected='ACTIVE_SESSION'
                        elif op['api']=='submission-api' and any(token in op.get('auth','') for token in ['token','proof']): expected='SCOPED_TOKEN'
                        elif op['api'] in {'submission-api','identity-provider'}: expected='ANONYMOUS_PROOF'
                        else: expected='NONE'
                    elif op.get('_additive_external'):
                        additive_assurance=op.get('assurance')
                        if additive_assurance in ASSURANCE:
                            expected=additive_assurance
                        elif isinstance(additive_assurance,str) and additive_assurance.startswith('conditional-'):
                            # A screen-level action cannot resolve a persisted or
                            # decision-dependent branch before submission. Require
                            # the conservative upper bound instead of flattening
                            # the operation contract to a static assurance claim.
                            expected='STEP_UP'
                        else:
                            result.require(False,f'{sid}:{contract_oid}: invalid additive assurance {additive_assurance}')
                            expected=None
                    else:
                        policy=commands[contract_oid]['authorization']['assurance_policy']
                        if policy.get('mode')=='CONDITIONAL':
                            fields={c.get('when',{}).get('field') for c in policy.get('conditions',[])}
                            result.require(fields <= set(request),f'{sid}:{contract_oid}: conditional assurance discriminator missing')
                        expected=_resolve(policy,request)
                    if expected is not None:
                        result.require(level==expected,f'{sid}:{contract_oid}: action assurance {level} != {expected}')
                        result.require(action.get('step_up_required')==(expected=='STEP_UP'),f'{sid}:{contract_oid}: step-up flag differs')
                        if expected=='STEP_UP' and not op.get('_additive_external'):
                            result.require('STEP_UP_REQUIRED' in op['authorization_errors'],f'{sid}:{contract_oid}: STEP_UP_REQUIRED missing')
                        if expected=='RECENT_SESSION': result.require('RECENT_AUTH_REQUIRED' in op['authorization_errors'],f'{sid}:{contract_oid}: RECENT_AUTH_REQUIRED missing')
        result.require((root/'specs/ui/screens'/f'{sid}.md').is_file(),f'{sid}: missing screen sheet')
        result.require(sid in manifest_by and [x['id'] for x in manifest_by[sid]['section_order']]==[x['id'] for x in sections],f'{sid}: build manifest mismatch')
        if sid in manifest_by: result.require(manifest_by[sid].get('actions')==screen.get('actions'),f'{sid}: build manifest actions differ')
    pub_035_manifest=manifest_by.get('PUB-035',{})
    result.require(
        {'method-unavailable','receipt'} <= set(pub_035_manifest.get('states',[])),
        'PUB-035: build manifest must include method-unavailable and receipt states',
    )
    stale_fences=sorted(set(proposal_fences)-matched_fences)
    result.require(not stale_fences,f'proposal-only fences do not match screen actions: {stale_fences}')
    nested=[p for p in (root/'specs/ui/screens').rglob('*.md') if p.parent!=root/'specs/ui/screens']; result.require(not nested,'nested obsolete screen sheets exist')
    result.stats.update({'screens':95,'public_screens':35,'response_screens':8,'internal_screens':52,'components':58})
