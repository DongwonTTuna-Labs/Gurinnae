from __future__ import annotations
from pathlib import Path
from .loaders import load_yaml
from .models import Validation

LEVELS={'ANONYMOUS_PROOF','SCOPED_TOKEN','ACTIVE_SESSION','RECENT_SESSION','STEP_UP'}
INTERACTIONS={'NAVIGATION','DOWNLOAD','EXTERNAL_LINK','FORM_SUBMIT','COMMAND','DESTRUCTIVE_CONFIRMATION'}

def resolve(policy:dict,fixed:dict)->str:
 level=policy['default']
 if policy['mode']=='STATIC': return level
 for condition in policy['conditions']:
  when=condition['when']; value=fixed.get(when['field'])
  if when['operator']=='EQUALS' and value==when['value']: level=condition['required_level']
  elif when['operator']=='IN' and value in when['values']: level=condition['required_level']
 return level

def validate(root:Path,result:Validation)->None:
 assurance=load_yaml(root/'specs/auth/assurance-policy.yaml'); operations=load_yaml(root/'specs/api/operation-contracts.yaml')['operations']; commands=load_yaml(root/'specs/application/command-semantics.yaml')['commands']; traces=load_yaml(root/'specs/traceability/final-traceability.yaml')['operations']; screens=load_yaml(root/'specs/ui/screen-catalog.yaml')['screens']
 op_by={o['operation_id']:o for o in operations}; cmd_by={c['operation_id']:c for c in commands}; trace_by={t['operation_id']:t for t in traces}; catalog={c['operation_id']:c for c in assurance['commands']}; command_ids={o['operation_id'] for o in operations if o['operation_kind']=='COMMAND'}
 result.require(assurance['status']=='FINAL' and assurance['specification_version']=='13.0.0','assurance catalog must be FINAL v13')
 result.require(set(assurance['levels'])==LEVELS,'assurance levels differ')
 result.require(set(catalog)==command_ids,'assurance command set differs')
 conditional=0; step_up_possible=0; action_count=0
 for oid in sorted(command_ids):
  op=op_by[oid]; cmd=cmd_by[oid]; record=catalog[oid]; policy=op['assurance_policy']
  result.require(policy==record['assurance_policy']==cmd['authorization']['assurance_policy']==trace_by[oid]['assurance_policy'],f'{oid}: assurance policy differs across layers')
  result.require(policy['mode'] in {'STATIC','CONDITIONAL'} and policy['default'] in LEVELS,f'{oid}: invalid assurance policy')
  possible=policy.get('step_up_possible') is True
  if policy['mode']=='CONDITIONAL':
   conditional+=1; result.require(bool(policy['conditions']),f'{oid}: conditional assurance has no conditions')
   for condition in policy['conditions']:
    result.require(condition['required_level'] in LEVELS and condition['when']['operator'] in {'EQUALS','IN'},f'{oid}: invalid assurance condition')
    if condition['required_level']=='STEP_UP': possible=True
  if possible: step_up_possible+=1
  result.require(('STEP_UP_REQUIRED' in op['authorization_errors'])==possible,f'{oid}: STEP_UP_REQUIRED differs from reachable policy branches')
  static_required=policy['mode']=='STATIC' and policy['default']=='STEP_UP'
  result.require(op['step_up_required']==cmd['authorization']['step_up_required']==record['step_up_required']==static_required,f'{oid}: static step-up flag differs')
  if possible:
   result.require(op['step_up_policy']['owner']=='PRIVATE_IDENTITY_API' and op['step_up_policy']['control_api_receives_proof'] is False,f'{oid}: step-up ownership differs')
  else: result.require('step_up_policy' not in op,f'{oid}: non-step-up command retains step_up_policy')
 for screen in screens:
  for action in screen.get('actions',[]):
   action_count+=1; kind=action.get('interaction_kind'); result.require(kind in INTERACTIONS,f"{screen['id']}:{action['id']}: unknown interaction kind {kind}")
   result.require(action.get('confirmation_required')==(kind=='DESTRUCTIVE_CONFIRMATION'),f"{screen['id']}:{action['id']}: confirmation flag differs from interaction kind")
   oid=action.get('operation_id')
   if not oid:
    result.require(action.get('local_only') is True,f"{screen['id']}:{action['id']}: local/navigation action lacks local_only")
    result.require(action.get('assurance_level')=='NONE' and action.get('step_up_required') is False,f"{screen['id']}:{action['id']}: local action has security assurance")
    continue
   result.require(oid in op_by,f"{screen['id']}:{action['id']}: unknown operation {oid}")
   if oid not in op_by: continue
   op=op_by[oid]
   if op['operation_kind']!='COMMAND':
    result.require(action.get('step_up_required') is False,f"{screen['id']}:{action['id']}: query/navigation cannot require step-up")
    continue
   resolved=resolve(op['assurance_policy'],action.get('fixed_request',{}))
   if op['assurance_policy']['mode']=='CONDITIONAL': result.require(bool(action.get('fixed_request')),f"{screen['id']}:{action['id']}: conditional operation lacks fixed_request")
   result.require(action.get('assurance_level')==resolved,f"{screen['id']}:{action['id']}: action assurance {action.get('assurance_level')} != {resolved}")
   result.require(action.get('step_up_required')==(resolved=='STEP_UP'),f"{screen['id']}:{action['id']}: step-up flag differs from resolved assurance")
   if screen['surface'] in {'public','response'}: result.require(resolved!='STEP_UP',f"{screen['id']}:{action['id']}: public/response surface cannot use internal OIDC step-up")
 result.stats.update({'assurance_commands':len(catalog),'conditional_assurance_commands':conditional,'step_up_capable_commands':step_up_possible,'assurance_screen_actions':action_count})
