from __future__ import annotations
import base64,hashlib,json
from pathlib import Path
from jsonschema import Draft202012Validator
from .loaders import load_json,load_yaml
from .models import Validation

def b64d(v): return base64.urlsafe_b64decode(v+'='*((4-len(v)%4)%4))

def validate(root:Path,result:Validation)->None:
 files=['session-cookie-envelope.yaml','field-encryption-envelope.yaml','step-up-transaction-envelope.yaml','step-up-authorization-envelope.yaml','submission-session-cookie-envelope.yaml']
 for name in files:
  c=load_yaml(root/'specs/cryptography'/name)
  result.require(c['status']=='FINAL' and c['specification_version']=='13.0.0',f'{name}: contract mismatch')
  result.require(c['algorithm']=='ChaCha20-Poly1305 IETF (RFC 8439)' and c['key_bytes']==32 and c['nonce_bytes']==12 and c['tag_bytes']==16,f'{name}: algorithm dimensions differ')
 schema_names=['session-cookie-payload.schema.json','step-up-transaction-payload.schema.json','step-up-authorization-payload.schema.json','submission-session-cookie-payload.schema.json']
 schemas={name:load_json(root/'specs/cryptography'/name) for name in schema_names}
 for schema in schemas.values(): Draft202012Validator.check_schema(schema)
 # The internal-session cookie has one canonical payload across OIDC, schema and vector.
 session_schema=schemas['session-cookie-payload.schema.json']
 canonical_required={'v','typ','opaqueIdentitySessionToken','csrfToken','issuedAt','absoluteExpiresAt','csrfRotatedAt'}
 result.require(set(session_schema['required'])==canonical_required,'internal-session cookie required fields differ from the canonical contract')
 oidc=load_yaml(root/'specs/config/oidc-contract.yaml')
 sealed=set(oidc['cookies']['internal_session']['sealed_payload'])
 result.require(sealed==canonical_required,'OIDC internal-session sealed payload differs from the cryptography schema')
 result.require(oidc['cookies']['internal_session']['canonical_payload_schema']=='specs/cryptography/session-cookie-payload.schema.json','OIDC session schema reference differs')
 try:
  from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
 except Exception as exc:
  result.error(f'cryptography runtime unavailable for envelope vector verification: {exc}'); return
 vectors=['session-cookie.json','field-encryption.json','step-up-transaction-cookie.json','step-up-authorization-cookie.json','submission-session-cookie.json']; verified=0
 for name in vectors:
  v=load_json(root/'specs/cryptography/test-vectors'/name); key=bytes.fromhex(v['testOnlyKeyHex']); nonce=bytes.fromhex(v['nonceHex']); aad=bytes.fromhex(v['aadHex']); token=v['token'].split('.')
  result.require(token[1]==hashlib.sha256(key).hexdigest()[:16],f'{name}: kid mismatch'); result.require(b64d(token[2])==nonce,f'{name}: nonce mismatch')
  ct=b64d(token[3]); result.require(ct.hex()==v['ciphertextAndTagHex'],f'{name}: ciphertext differs')
  plain=ChaCha20Poly1305(key).decrypt(nonce,ct,aad); result.require(plain.decode()==v['plaintextUtf8'],f'{name}: decrypt differs')
  if name=='session-cookie.json':
   payload=json.loads(plain); errors=list(Draft202012Validator(session_schema).iter_errors(payload)); result.require(not errors,f'session-cookie vector violates canonical schema: {errors[0].message if errors else ""}')
   result.require(payload==v['payload'],'session-cookie plaintext and payload object differ')
   result.require('opaqueIdentitySessionToken' in payload and 'sessionId' not in payload and 'userId' not in payload,'session cookie does not carry the canonical opaque session token')
  tampered=bytearray(ct); tampered[-1]^=1
  try: ChaCha20Poly1305(key).decrypt(nonce,bytes(tampered),aad); result.error(f'{name}: tampered tag decrypted')
  except Exception: pass
  try: ChaCha20Poly1305(key).decrypt(nonce,ct,aad+b'x'); result.error(f'{name}: wrong AAD decrypted')
  except Exception: pass
  verified+=1
 negative=load_json(root/'specs/cryptography/test-vectors/negative-cases.json'); result.require(len(negative['cases'])==8,'cryptography negative vector count differs')
 result.stats.update({'cryptographic_envelope_vectors':verified,'cryptographic_negative_cases':len(negative['cases'])})
