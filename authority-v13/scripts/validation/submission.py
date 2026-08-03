from __future__ import annotations
from pathlib import Path
from .loaders import load_json,load_yaml
from .models import Validation

def validate(root:Path,result:Validation)->None:
 contract=load_yaml(root/'specs/submission/session-boundary.yaml')
 result.require(contract['status']=='FINAL' and contract['specification_version']=='13.0.0','submission session contract mismatch')
 ops=load_yaml(root/'specs/api/operation-contracts.yaml')['operations']; sub=[o for o in ops if o['api']=='submission-api']
 result.require(len(sub)==34,f'expected 34 submission operations, found {len(sub)}')
 allowed_auth={'bff-service-assertion','bff-service-assertion-and-one-time-token','bff-service-assertion-and-scoped-submission-session'}
 result.require(all(o['auth'] in allowed_auth for o in sub),'submission operation has ambiguous auth')
 forbidden=['requestToken','draftToken','receiptToken','managementToken','verificationToken']
 result.require(all(not any('{'+x+'}' in o['path'] for x in forbidden) for o in sub),'raw token remains in Submission API path')
 anonymous={'createContactRequest','createCorrectionRequestDraft','createDatasetExport','createSubscription'}
 by={o['operation_id']:o for o in sub}
 for oid in anonymous:
  o=by[oid]; result.require(o['auth']=='bff-service-assertion' and any(f['name']=='abuseProof' for f in o['request_fields']),f'{oid}: anonymous BFF flow lacks abuse proof')
 scoped=set(contract['session_kinds'][k]['allowedOperations'][i] for k in contract['session_kinds'] for i in range(len(contract['session_kinds'][k]['allowedOperations'])))
 for oid in scoped:
  result.require(by[oid]['auth']=='bff-service-assertion-and-scoped-submission-session',f'{oid}: scoped operation auth differs')
 exchanges={'exchangeResponseAccessToken','exchangeResponseReceiptToken','exchangeCorrectionReceiptToken','exchangeSubscriptionManagementToken','verifySubscription'}
 for oid in exchanges:
  result.require(by[oid]['auth']=='bff-service-assertion-and-one-time-token',f'{oid}: exchange auth differs')
 flow_required={'createCorrectionRequestDraft','getCorrectionRequestDraft','saveCorrectionRequestDraft','createCorrectionAttachment','finalizeCorrectionAttachment','deleteCorrectionAttachment','getCorrectionRequestDraftPreview','createCorrectionRequest','exchangeResponseAccessToken','verifyResponseAccess','submitResponse','exchangeResponseReceiptToken','exchangeCorrectionReceiptToken','createSubscription','verifySubscription','exchangeSubscriptionManagementToken'}
 result.require(flow_required<=set(by),'submission workflow operation set incomplete')
 api=load_yaml(root/'specs/api/submission-api.openapi.yaml'); schemes=api['components']['securitySchemes']
 result.require(set(schemes)=={'BffServiceAssertion','ScopedSubmissionSession'},'submission security scheme resolution differs')
 for path,item in api['paths'].items():
  for node in item.values():
   if isinstance(node,dict) and node.get('operationId'):
    for requirement in node.get('security',[]):
     result.require(set(requirement)<=set(schemes),f"{node['operationId']}: undefined security scheme")
 cookie_schema=load_json(root/'specs/cryptography/submission-session-cookie-payload.schema.json')
 result.require(set(cookie_schema['required'])=={'v','typ','sessionKind','opaqueSessionToken','csrfToken','issuedAt','absoluteExpiresAt','csrfRotatedAt'},'submission cookie canonical payload differs')
 screens=load_yaml(root/'specs/ui/screen-catalog.yaml')['screens']; sb={s['id']:s for s in screens}
 result.require(all('{token}' not in sb[s]['route'] for s in ['RSP-001','RSP-002','RSP-003','RSP-004','RSP-005','RSP-006','RSP-007']),'response portal canonical routes contain raw token')
 result.require('{token}' not in sb['PUB-030']['route'] and '{receiptId}' not in sb['PUB-028']['route'],'public management/receipt routes contain token')
 result.stats.update({'submission_operations':len(sub),'submission_session_kinds':len(contract['session_kinds']),'submission_bff_callers':len(contract['boundary']['bff_callers'])})
