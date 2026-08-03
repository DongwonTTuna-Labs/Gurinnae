from __future__ import annotations
from pathlib import Path
from .loaders import load_yaml
from .models import Validation

LEVELS={'ANONYMOUS_PROOF','SCOPED_TOKEN','ACTIVE_SESSION','RECENT_SESSION','STEP_UP'}
ACTION_LEVELS=LEVELS|{'NONE'}
INTERACTIONS={'NAVIGATION','DOWNLOAD','EXTERNAL_LINK','FORM_SUBMIT','COMMAND','DESTRUCTIVE_CONFIRMATION'}
PRIVATE_BILLING_AUTHORITY='TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY'

def resolve(policy:dict,fixed:dict)->str:
 level=policy['default']
 if policy['mode']=='STATIC': return level
 for condition in policy['conditions']:
  when=condition['when']; value=fixed.get(when['field'])
  if when['operator']=='EQUALS' and value==when['value']: level=condition['required_level']
  elif when['operator']=='IN' and value in when['values']: level=condition['required_level']
 return level

def _private_billing_catalog(root:Path,result:Validation)->dict[str,dict]:
 source_doc=load_yaml(root/'specs/product/addendum-operation-contracts.yaml'); owner_doc=load_yaml(root/'specs/product/owner-addendum-2026-07-14.yaml'); resources=load_yaml(root/'specs/product/addendum-resource-error-contracts.yaml')
 source=source_doc.get('private_billing_gateway_operations',{}); owner_rows=owner_doc.get('private_billing_gateway_operations',[]); bindings=resources.get('private_billing_gateway_operation_bindings',{}); requests=resources.get('private_billing_gateway_request_schemas',{}); errors=resources.get('private_billing_gateway_error_sets',{})
 rows_valid=isinstance(owner_rows,list) and all(isinstance(row,dict) and isinstance(row.get('operation_id'),str) and bool(row['operation_id']) for row in owner_rows)
 owner_ids=[row['operation_id'] for row in owner_rows] if rows_valid else []; owner_by={row['operation_id']:row for row in owner_rows} if rows_valid else {}
 declared_raw=resources.get('set_equality',{}).get('private_billing_gateway_operation_ids',[]); declared_valid=isinstance(declared_raw,list) and all(isinstance(oid,str) and bool(oid) for oid in declared_raw); declared=set(declared_raw) if declared_valid else set()
 mappings=(source,bindings,requests,errors); closure=rows_valid and declared_valid and len(owner_ids)==len(set(owner_ids)) and len(declared_raw)==len(declared) and all(isinstance(mapping,dict) and set(mapping)==declared for mapping in mappings) and set(owner_ids)==declared
 result.require(closure,'private billing operation registries differ')
 if not closure: return {}
 catalog={}
 for oid in sorted(declared):
  operation=source[oid]; owner=owner_by[oid]; binding=bindings[oid]; request=requests[oid]; entrypoint=operation.get('entrypoint',{})
  expected_pointer=f"specs/product/addendum-operation-contracts.yaml#private_billing_gateway_operations['{oid}']"
  checks=(
   (operation.get('operation_kind')==owner.get('kind')==binding.get('operation_kind'),f'{oid}: private billing operation kind differs'),
   (operation.get('transport')=='PRIVATE_BILLING_GATEWAY_HTTP',f'{oid}: private billing transport differs'),
   (entrypoint.get('method')==owner.get('method') and entrypoint.get('path')==owner.get('path'),f'{oid}: private billing entrypoint differs'),
   (owner.get('runtime_mode')=='TEST_MODE_ONLY',f'{oid}: private billing runtime mode differs'),
   (binding.get('scope')=='PRIVATE_BILLING_GATEWAY' and binding.get('source_pointer')==expected_pointer,f'{oid}: private billing binding scope differs'),
   (operation.get('request_schema')==binding.get('request_schema')==request.get('name'),f'{oid}: private billing request schema differs'),
   (operation.get('response_schema')==binding.get('success_schema'),f'{oid}: private billing response schema differs'),
   (isinstance(operation.get('errors'),list) and isinstance(errors[oid],list) and len(operation['errors'])==len(set(operation['errors'])) and len(errors[oid])==len(set(errors[oid])) and set(operation['errors'])==set(errors[oid]),f'{oid}: private billing error set differs'),
   (operation.get('effect_owner')==binding.get('effect_owner')=='billing-gateway',f'{oid}: private billing effect owner differs'),
   (binding.get('issuer')==binding.get('caller') and binding.get('audience')=='billing-gateway',f'{oid}: private billing service assertion binding differs'),
  )
  valid=all(condition for condition,_ in checks)
  for condition,message in checks: result.require(condition,message)
  if not valid: continue
  authority=operation.get('authority_boundary',{}).get('authority')
  if authority is None: authority=operation.get('availability',{}).get('TEST_ONLY',{}).get('authority') if isinstance(operation.get('availability',{}).get('TEST_ONLY'),dict) else None
  catalog[oid]={'operation_id':oid,'operation_kind':operation['operation_kind'],'transport':operation['transport'],'method':entrypoint['method'],'path':entrypoint['path'],'runtime_mode':owner['runtime_mode'],'caller':binding.get('caller'),'issuer':binding.get('issuer'),'audience':binding.get('audience'),'authority':authority}
 return catalog

def _resolve_additive_action_assurance(additive:dict,interaction:str|None,result:Validation,key:str)->str|None:
 kind=additive.get('kind'); resolved=additive.get('assurance')
 if kind=='QUERY':
  result.require(interaction=='DOWNLOAD',f'{key}: additive query screen action is not a download')
  result.require(resolved=='NONE',f'{key}: additive query assurance must be NONE')
  return resolved if resolved=='NONE' else None
 result.require(kind=='COMMAND',f'{key}: additive screen action is neither a query nor a command')
 if kind!='COMMAND': return None
 if isinstance(resolved,str) and resolved.startswith('conditional-'):
  # Persisted/decision-dependent assurance cannot be selected from the
  # static screen catalog. The visible action advertises the conservative
  # upper bound while the command still reauthorizes its exact branch.
  resolved='STEP_UP'
 result.require(resolved in LEVELS,f'{key}: invalid additive command assurance')
 return resolved if resolved in LEVELS else None

def _validate_private_billing_action(operation:dict,action:dict,result:Validation,key:str)->None:
 availability=action.get('availability',{}); production=availability.get('production',{}); test_only=availability.get('test_only',{})
 checks=(
  (operation.get('operation_kind')=='COMMAND',f'{key}: private billing screen action is not a command'),
  (operation.get('transport')=='PRIVATE_BILLING_GATEWAY_HTTP',f'{key}: private billing transport differs'),
  (operation.get('runtime_mode')=='TEST_MODE_ONLY',f'{key}: private billing operation is not TEST_MODE_ONLY'),
  (operation.get('caller')==operation.get('issuer')=='public-web' and operation.get('audience')=='billing-gateway',f'{key}: private billing caller binding differs'),
  (operation.get('authority')==PRIVATE_BILLING_AUTHORITY,f'{key}: private billing authority differs'),
  (action.get('interaction_kind')=='COMMAND',f'{key}: private billing interaction is not COMMAND'),
  (action.get('server_only') is True and action.get('browser_direct') is False,f'{key}: private billing action is not server-only'),
  (action.get('assurance_level')=='NONE' and action.get('step_up_required') is False,f'{key}: private billing action has security assurance'),
  (availability.get('default')=='DISABLED' and production.get('state')=='UNAVAILABLE' and production.get('reason')==PRIVATE_BILLING_AUTHORITY and production.get('enabled') is False,f'{key}: private billing production availability differs'),
  (test_only.get('authority')==PRIVATE_BILLING_AUTHORITY and test_only.get('tier')=='TEST_FIXTURE' and test_only.get('lifecycle')=='EPHEMERAL' and test_only.get('enabled') is True,f'{key}: private billing test authority differs'),
 )
 for condition,message in checks: result.require(condition,message)

def validate(root:Path,result:Validation)->None:
 assurance=load_yaml(root/'specs/auth/assurance-policy.yaml'); operations=load_yaml(root/'specs/api/operation-contracts.yaml')['operations']; commands=load_yaml(root/'specs/application/command-semantics.yaml')['commands']; traces=load_yaml(root/'specs/traceability/final-traceability.yaml')['operations']; screens=load_yaml(root/'specs/ui/screen-catalog.yaml')['screens']
 additive_operations=load_yaml(root/'specs/product/addendum-operation-contracts.yaml'); additive_by={o['operation_id']:o for o in additive_operations['operations']}
 private_billing=_private_billing_catalog(root,result)
 side_door_ids=set(additive_operations.get('provider_control_http_side_door',{}).get('operation_ids',[]))
 action_contracts=load_yaml(root/'specs/ui/screen-action-contracts.yaml')
 proposal_entries={(row['screen_id'],row['legacy_action_id']):row for row in action_contracts.get('legacy_side_door_fences',[]) if 'proposal_binding' in row}
 op_by={o['operation_id']:o for o in operations}; cmd_by={c['operation_id']:c for c in commands}; trace_by={t['operation_id']:t for t in traces}; catalog={c['operation_id']:c for c in assurance['commands']}; command_ids={o['operation_id'] for o in operations if o['operation_kind']=='COMMAND'}
 overlap=(set(op_by)&set(additive_by))|(set(op_by)&set(private_billing))|(set(additive_by)&set(private_billing)); result.require(not overlap,f'operation catalogs overlap: {sorted(overlap)}')
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
  if oid in side_door_ids: result.require(not op['authorization_errors'],f'{oid}: provider-control side-door authorization errors must be empty')
  else: result.require(('STEP_UP_REQUIRED' in op['authorization_errors'])==possible,f'{oid}: STEP_UP_REQUIRED differs from reachable policy branches')
  static_required=policy['mode']=='STATIC' and policy['default']=='STEP_UP'
  result.require(op['step_up_required']==cmd['authorization']['step_up_required']==record['step_up_required']==static_required,f'{oid}: static step-up flag differs')
  if possible:
   result.require(op['step_up_policy']['owner']=='PRIVATE_IDENTITY_API' and op['step_up_policy']['control_api_receives_proof'] is False,f'{oid}: step-up ownership differs')
  else: result.require('step_up_policy' not in op,f'{oid}: non-step-up command retains step_up_policy')
 submit_review_policy={
  'mode':'CONDITIONAL',
  'default':'ACTIVE_SESSION',
  'conditions':[
   {'when':{'field':'decision','operator':'EQUALS','value':'approve'},'required_level':'STEP_UP'},
   {'when':{'field':'decision','operator':'IN','values':['reject','changes_required']},'required_level':'ACTIVE_SESSION'},
  ],
  'step_up_possible':True,
 }
 result.require(
  op_by['submitReview']['assurance_policy']==submit_review_policy,
  'submitReview assurance must remain decision-owned: APPROVE is STEP_UP and REJECT/CHANGES_REQUIRED are ACTIVE_SESSION independently of namedIndividualOverride',
 )
 for screen in screens:
  for action in screen.get('actions',[]):
   action_count+=1; kind=action.get('interaction_kind'); result.require(kind in INTERACTIONS,f"{screen['id']}:{action['id']}: unknown interaction kind {kind}")
   result.require(action.get('confirmation_required')==(kind=='DESTRUCTIVE_CONFIRMATION'),f"{screen['id']}:{action['id']}: confirmation flag differs from interaction kind")
   oid=action.get('operation_id')
   if not oid:
    result.require(action.get('local_only') is True,f"{screen['id']}:{action['id']}: local/navigation action lacks local_only")
    result.require(action.get('assurance_level')=='NONE' and action.get('step_up_required') is False,f"{screen['id']}:{action['id']}: local action has security assurance")
    continue
   key=f"{screen['id']}:{action['id']}"
   result.require(oid in op_by or oid in additive_by or oid in private_billing,f'{key}: unknown operation {oid}')
   if oid not in op_by and oid not in additive_by and oid not in private_billing: continue
   if oid in private_billing:
    _validate_private_billing_action(private_billing[oid],action,result,key)
    continue
   if oid not in op_by:
    additive=additive_by.get(oid)
    result.require(additive is not None,f'{key}: unknown additive operation {oid}')
    if additive is None: continue
    resolved=_resolve_additive_action_assurance(additive,kind,result,key)
    if resolved not in ACTION_LEVELS: continue
    result.require(action.get('assurance_level')==resolved,f"{screen['id']}:{action['id']}: action assurance {action.get('assurance_level')} != {resolved}")
    result.require(action.get('step_up_required')==(resolved=='STEP_UP'),f"{screen['id']}:{action['id']}: step-up flag differs from resolved assurance")
    if screen['surface'] in {'public','response'}: result.require(resolved!='STEP_UP',f"{screen['id']}:{action['id']}: public/response surface cannot use internal OIDC step-up")
    continue
   op=op_by[oid]
   if op['operation_kind']!='COMMAND':
    result.require(action.get('step_up_required') is False,f"{screen['id']}:{action['id']}: query/navigation cannot require step-up")
    continue
   proposal_entry=proposal_entries.get((screen['id'],action['id']))
   if proposal_entry:
    entry_id=proposal_entry.get('required_entry_operation'); entry=additive_by.get(entry_id)
    result.require(proposal_entry.get('legacy_operation_id')==oid,f"{screen['id']}:{action['id']}: proposal operation binding differs")
    result.require(entry is not None and entry.get('kind')=='COMMAND',f"{screen['id']}:{action['id']}: proposal entry operation is missing or not a command")
    resolved=entry.get('assurance') if entry else None
   else:
    resolved=resolve(op['assurance_policy'],action.get('fixed_request',{}))
    if op['assurance_policy']['mode']=='CONDITIONAL': result.require(bool(action.get('fixed_request')),f"{screen['id']}:{action['id']}: conditional operation lacks fixed_request")
   result.require(action.get('assurance_level')==resolved,f"{screen['id']}:{action['id']}: action assurance {action.get('assurance_level')} != {resolved}")
   result.require(action.get('step_up_required')==(resolved=='STEP_UP'),f"{screen['id']}:{action['id']}: step-up flag differs from resolved assurance")
   if screen['surface'] in {'public','response'}: result.require(resolved!='STEP_UP',f"{screen['id']}:{action['id']}: public/response surface cannot use internal OIDC step-up")
 result.stats.update({'assurance_commands':len(catalog),'conditional_assurance_commands':conditional,'step_up_capable_commands':step_up_possible,'assurance_screen_actions':action_count})
