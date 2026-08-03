from __future__ import annotations
import base64,copy,hashlib,hmac,json,re
from pathlib import Path
from jsonschema import Draft202012Validator
from .loaders import load_json,load_yaml
from .models import Validation
TOKEN_RE=re.compile(r'^(gurine-(?:sa|aa)-v1)\.([a-f0-9]{16})\.([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]{43})$')
def b64d(v): return base64.urlsafe_b64decode(v+'='*((4-len(v)%4)%4))
def b64e(v): return base64.urlsafe_b64encode(v).rstrip(b'=').decode()
def canonical(v): return json.dumps(v,sort_keys=True,separators=(',',':'),ensure_ascii=True).encode('ascii')
def sign(prefix,payload,key):
 kid=hashlib.sha256(key).hexdigest()[:16]; pb=b64e(canonical(payload)); inp=f'{prefix}.{kid}.{pb}'.encode(); return f'{prefix}.{kid}.{pb}.{b64e(hmac.new(key,inp,hashlib.sha256).digest())}'
def parse_verify(token,prefix,keys,schema,now,expected_aud,binding=None,seen=None):
 m=TOKEN_RE.fullmatch(token)
 if not m or m.group(1)!=prefix: raise ValueError('ASSERTION_FORMAT_INVALID')
 kid=m.group(2)
 if kid not in keys: raise ValueError('ASSERTION_UNKNOWN_KEY')
 payload_bytes=b64d(m.group(3)); payload=json.loads(payload_bytes)
 if payload_bytes!=canonical(payload): raise ValueError('ASSERTION_NONCANONICAL_PAYLOAD')
 sig=b64d(m.group(4)); inp=f'{prefix}.{kid}.{m.group(3)}'.encode()
 if not hmac.compare_digest(sig,hmac.new(keys[kid],inp,hashlib.sha256).digest()): raise ValueError('ASSERTION_SIGNATURE_INVALID')
 errs=list(Draft202012Validator(schema).iter_errors(payload))
 if errs: raise ValueError('ASSERTION_SCHEMA_INVALID')
 if payload['exp']<now: raise ValueError('ASSERTION_EXPIRED')
 if payload['iat']>now+5: raise ValueError('ASSERTION_ISSUED_IN_FUTURE')
 if payload['aud']!=expected_aud: raise ValueError('ASSERTION_AUDIENCE_MISMATCH')
 if binding:
  for k,v in binding.items():
   if payload.get(k)!=v: raise ValueError('ASSERTION_REQUEST_MISMATCH')
 if seen is not None:
  if payload['jti'] in seen: raise ValueError('ASSERTION_REPLAYED')
  seen.add(payload['jti'])
 return payload


def public_error(prefix:str,internal:str)->str:
 namespace='SERVICE_ASSERTION' if prefix=='gurine-sa-v1' else 'ACTOR_ASSERTION'
 explicit={
  'ASSERTION_EXPIRED':namespace+'_EXPIRED',
  'ASSERTION_AUDIENCE_MISMATCH':namespace+'_AUDIENCE_MISMATCH',
  'ASSERTION_REQUEST_MISMATCH':namespace+'_REQUEST_MISMATCH',
  'ASSERTION_REPLAYED':namespace+'_REPLAYED',
 }
 return explicit.get(internal,namespace+'_INVALID')

def validate(root:Path,result:Validation)->None:
 contract=load_yaml(root/'specs/auth/assertion-contract.yaml'); ss=load_json(root/'specs/auth/service-assertion.schema.json'); aa=load_json(root/'specs/auth/actor-assertion.schema.json'); sv=load_json(root/'specs/auth/test-vectors/service-assertion.json'); av=load_json(root/'specs/auth/test-vectors/actor-assertion.json'); neg=load_json(root/'specs/auth/test-vectors/negative-cases.json')
 result.require(contract['status']=='FINAL' and contract['specification_version']=='13.0.0','assertion contract must be FINAL v12')
 Draft202012Validator.check_schema(ss); Draft202012Validator.check_schema(aa)
 for vector,prefix_value,schema,aud in [(sv,'gurine-sa-v1',ss,'identity-api'),(av,'gurine-aa-v1',aa,'control-api')]:
  key=bytes.fromhex(vector['testOnlyKeyHex']); kid=hashlib.sha256(key).hexdigest()[:16]
  result.require(sign(prefix_value,vector['payload'],key)==vector['token'],f"{vector['name']}: token is not deterministic")
  parsed=parse_verify(vector['token'],prefix_value,{kid:key},schema,vector['payload']['iat'],aud)
  result.require(parsed==vector['payload'],f"{vector['name']}: verification payload differs")
 required_ids={'service-expired','service-wrong-audience','service-wrong-body','service-replay','service-unknown-key','service-wrong-signature','actor-expired','actor-wrong-audience','actor-wrong-path','actor-replay','actor-unknown-key','actor-noncanonical-payload'}
 cases={x['id']:x for x in neg['cases']}; result.require(required_ids==set(cases),'assertion negative vector set differs')
 def run_case(cid):
  is_actor=cid.startswith('actor-'); vector=av if is_actor else sv; schema=aa if is_actor else ss; prefix_value='gurine-aa-v1' if is_actor else 'gurine-sa-v1'; aud='control-api' if is_actor else 'identity-api'; key=bytes.fromhex(vector['testOnlyKeyHex']); kid=hashlib.sha256(key).hexdigest()[:16]; payload=copy.deepcopy(vector['payload']); token=vector['token']; keys={kid:key}; now=payload['iat']; binding=None; seen=set()
  if cid.endswith('expired'): now=payload['exp']+1
  elif cid.endswith('wrong-audience'): payload['aud']='wrong-audience'; token=sign(prefix_value,payload,key)
  elif cid.endswith('wrong-body'): payload['bodySha256']='0'*64; token=sign(prefix_value,payload,key); binding={'bodySha256':vector['payload']['bodySha256']}
  elif cid.endswith('wrong-path'): payload['path']='/v1/internal/wrong'; token=sign(prefix_value,payload,key); binding={'path':vector['payload']['path']}
  elif cid.endswith('unknown-key'): keys={}
  elif cid.endswith('wrong-signature'):
   parts=token.split('.'); sig=bytearray(b64d(parts[3])); sig[-1]^=1; token='.'.join(parts[:3]+[b64e(bytes(sig))])
  elif cid.endswith('noncanonical-payload'):
   noncanonical=json.dumps(payload,sort_keys=False,separators=(', ', ': '),ensure_ascii=True).encode('ascii'); pb=b64e(noncanonical); inp=f'{prefix_value}.{kid}.{pb}'.encode(); token=f'{prefix_value}.{kid}.{pb}.{b64e(hmac.new(key,inp,hashlib.sha256).digest())}'
  elif cid.endswith('replay'): parse_verify(token,prefix_value,keys,schema,now,aud,seen=seen)
  try: parse_verify(token,prefix_value,keys,schema,now,aud,binding=binding,seen=seen)
  except ValueError as error: return prefix_value,str(error)
  raise AssertionError(cid+' unexpectedly succeeded')
 executed=0
 for cid,case in cases.items():
  prefix_value,internal=run_case(cid); actual=public_error(prefix_value,internal)
  expected=case.get('expectedError') or case.get('expectedErrorOnAttempt',{}).get(str(case.get('attempts',2)))
  result.require(actual==expected,f'{cid}: public assertion error {actual} != fixture {expected} (internal {internal})'); executed+=1
 actor_required={'operationId','requiredCapability','idempotencyKeySha256','stepUpAuthorizationId','actionDigest'}; result.require(actor_required<=set(aa['required']),'Actor Assertion request/action binding claims incomplete')
 capability_resolution=contract.get('operation_capability_resolution',{}).get('submitReview',{})
 expected_resolution={
  'selector':'criteria.namedIndividualOverride',
  'absent_capability':'review.editorial',
  'present_capability':'review.legal',
  'mismatch_error':'CAPABILITY_DENIED',
 }
 result.require(
  all(capability_resolution.get(key)==value for key,value in expected_resolution.items()),
  'submitReview assertion capability selector must resolve exactly one body-bound editorial/legal branch',
 )
 operation_by={
  row['operation_id']:row
  for row in load_yaml(root/'specs/api/operation-contracts.yaml')['operations']
 }
 submit_policy=operation_by['submitReview'].get('capability_policy',{})
 result.require(
  submit_policy.get('default')=='review.editorial'
  and submit_policy.get('conditions')==[
   {'when':{'field':'criteria.namedIndividualOverride','operator':'ABSENT'},'required_capability':'review.editorial'},
   {'when':{'field':'criteria.namedIndividualOverride','operator':'PRESENT'},'required_capability':'review.legal'},
  ]
  and submit_policy.get('resolution')=='EXACTLY_ONE'
  and submit_policy.get('any_of_forbidden') is True
  and submit_policy.get('mismatch_error')=='CAPABILITY_DENIED',
  'submitReview operation capability policy differs from the body-bound assertion selector',
 )
 result.stats.update({'assertion_protocols':2,'assertion_positive_vectors':2,'assertion_negative_vectors_executed':executed})
