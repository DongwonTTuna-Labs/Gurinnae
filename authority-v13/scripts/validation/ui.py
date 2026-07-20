from __future__ import annotations
import collections
from pathlib import Path
from .loaders import load_yaml
from .models import Validation

INTERACTIONS={'NAVIGATION','DOWNLOAD','EXTERNAL_LINK','FORM_SUBMIT','COMMAND','DESTRUCTIVE_CONFIRMATION'}
ASSURANCE={'NONE','ANONYMOUS_PROOF','SCOPED_TOKEN','ACTIVE_SESSION','RECENT_SESSION','STEP_UP'}


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
    components=load_yaml(root/'specs/ui/component-catalog.yaml'); ops={o['operation_id']:o for o in load_yaml(root/'specs/api/operation-contracts.yaml')['operations']}
    commands={c['operation_id']:c for c in load_yaml(root/'specs/application/command-semantics.yaml')['commands']}
    capabilities={c['id'] for c in load_yaml(root/'specs/ui/roles-and-permissions.yaml')['capabilities']}
    screens=catalog['screens']; result.require(len(screens)==94,f'expected 94 screens, found {len(screens)}')
    counts=collections.Counter(s['surface'] for s in screens); result.require(counts=={'public':34,'response':8,'internal':52},f'wrong screen counts {dict(counts)}')
    component_ids={c['id'] for c in components['components']}; result.require(len(component_ids)==58,'expected 58 components')
    ids=set(); routes=set(); manifest_by={s['id']:s for s in manifest['screens']}
    for screen in screens:
        sid=screen['id']; result.require(sid not in ids,f'duplicate screen {sid}'); ids.add(sid)
        key=(screen['surface'],screen['route']); result.require(key not in routes,f'duplicate route {key}'); routes.add(key)
        sections=screen['sections']; result.require([s['order'] for s in sections]==list(range(1,len(sections)+1)),f'{sid}: section order invalid')
        for section in sections: result.require(section['component'] in component_ids,f"{sid}: unknown component {section['component']}")
        for req in screen.get('data_requirements',[]):
            oid=req['operation_id']; result.require(req['status']=='READY' and oid in ops,f'{sid}: invalid operation {oid}')
            if oid in ops:
                for field in ['api','method','path','request_schema','response_schema']: result.require(req.get(field)==ops[oid].get(field),f'{sid}:{oid}: {field} mismatch')
        for action in screen.get('actions',[]):
            interaction=action.get('interaction_kind'); level=action.get('assurance_level')
            result.require(interaction in INTERACTIONS,f"{sid}:{action['id']}: invalid interaction_kind")
            result.require(level in ASSURANCE,f"{sid}:{action['id']}: invalid assurance_level")
            result.require(action.get('confirmation_required')==(interaction=='DESTRUCTIVE_CONFIRMATION'),f"{sid}:{action['id']}: confirmation policy mismatch")
            oid=action.get('operation_id'); has=bool(oid) or bool(action.get('local_only')) or interaction in {'NAVIGATION','DOWNLOAD','EXTERNAL_LINK'}
            result.require(has,f"{sid}: action {action['id']} lacks contract")
            if oid:
                result.require(oid in ops,f'{sid}:{action["id"]}: unknown operation {oid}')
                if oid in ops:
                    op=ops[oid]; result.require(action.get('capability') in {'none',op.get('capability')},f'{sid}:{oid}: capability differs')
                    request={**action.get('fixed_request',{}),**action.get('request_discriminator',{})}
                    if op['operation_kind']=='QUERY':
                        if op['api']=='control-api': expected='ACTIVE_SESSION'
                        elif op['api']=='identity-provider' and op.get('auth')!='anonymous': expected='ACTIVE_SESSION'
                        elif op['api']=='submission-api' and any(token in op.get('auth','') for token in ['token','proof']): expected='SCOPED_TOKEN'
                        elif op['api'] in {'submission-api','identity-provider'}: expected='ANONYMOUS_PROOF'
                        else: expected='NONE'
                    else:
                        policy=commands[oid]['authorization']['assurance_policy']
                        if policy.get('mode')=='CONDITIONAL':
                            fields={c.get('when',{}).get('field') for c in policy.get('conditions',[])}
                            result.require(fields <= set(request),f'{sid}:{oid}: conditional assurance discriminator missing')
                        expected=_resolve(policy,request)
                    result.require(level==expected,f'{sid}:{oid}: action assurance {level} != {expected}')
                    result.require(action.get('step_up_required')==(expected=='STEP_UP'),f'{sid}:{oid}: step-up flag differs')
                    if expected=='STEP_UP': result.require('STEP_UP_REQUIRED' in op['authorization_errors'],f'{sid}:{oid}: STEP_UP_REQUIRED missing')
                    if expected=='RECENT_SESSION': result.require('RECENT_AUTH_REQUIRED' in op['authorization_errors'],f'{sid}:{oid}: RECENT_AUTH_REQUIRED missing')
        result.require((root/'specs/ui/screens'/f'{sid}.md').is_file(),f'{sid}: missing screen sheet')
        result.require(sid in manifest_by and [x['id'] for x in manifest_by[sid]['section_order']]==[x['id'] for x in sections],f'{sid}: build manifest mismatch')
        if sid in manifest_by: result.require(manifest_by[sid].get('actions')==screen.get('actions'),f'{sid}: build manifest actions differ')
    nested=[p for p in (root/'specs/ui/screens').rglob('*.md') if p.parent!=root/'specs/ui/screens']; result.require(not nested,'nested obsolete screen sheets exist')
    result.stats.update({'screens':94,'public_screens':34,'response_screens':8,'internal_screens':52,'components':58})
