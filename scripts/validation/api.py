from __future__ import annotations

import collections
import re
from pathlib import Path

from openapi_spec_validator import validate_spec

from .loaders import load_json, load_yaml
from .models import Validation

APIS = ['public-api', 'submission-api', 'control-api', 'identity-provider']
LAYERS = {
    'TRANSPORT': 'transport_errors',
    'AUTHORIZATION': 'authorization_errors',
    'CONCURRENCY': 'concurrency_errors',
    'DOMAIN': 'domain_errors',
    'PROVIDER': 'provider_errors',
    'INTERNAL': 'internal_errors',
}
CAMEL = re.compile(r'^[a-z][A-Za-z0-9]*$')
HTTP_STATUS = re.compile(r'^[1-5][0-9]{2}$')


def _ops(doc):
    out = {}
    for path, item in doc.get('paths', {}).items():
        for method, op in item.items():
            if isinstance(op, dict) and op.get('operationId'):
                out[op['operationId']] = (method.upper(), path, op)
    return out


def _refs(node):
    if isinstance(node, dict):
        if isinstance(node.get('$ref'), str):
            yield node['$ref']
        for value in node.values():
            yield from _refs(value)
    elif isinstance(node, list):
        for value in node:
            yield from _refs(value)


def validate(root: Path, result: Validation) -> None:
    contract = load_yaml(root / 'specs/api/operation-contracts.yaml')
    operations = contract['operations']
    by_id = {op['operation_id']: op for op in operations}
    addendum = load_yaml(root / 'specs/product/addendum-operation-contracts.yaml')
    addendum_resources = load_yaml(root / 'specs/product/addendum-resource-error-contracts.yaml')
    addendum_by_id = {op['operation_id']: op for op in addendum['operations'] if op.get('api') in APIS}
    addendum_bindings = addendum_resources.get('operation_bindings', {})
    errors = load_yaml(root / 'specs/api/error-code-catalog.yaml')['errors']
    error_by = {error['code']: error for error in errors}

    result.require(contract['status'] == 'FINAL', 'operation contract must be FINAL')
    result.require(contract['specification_version'] == '13.0.0', 'operation contract version mismatch')
    result.require(len(operations) == 212, f'expected 212 operations, found {len(operations)}')
    result.require(len(by_id) == len(operations), 'operation IDs are not globally unique')
    counts = collections.Counter(op['api'] for op in operations)
    result.require(
        counts == {'public-api': 41, 'submission-api': 34, 'control-api': 131, 'identity-provider': 6},
        f'wrong API counts: {dict(counts)}',
    )
    kinds = collections.Counter(op['operation_kind'] for op in operations)
    result.require(kinds == {'QUERY': 107, 'COMMAND': 105}, f'wrong operation kinds: {dict(kinds)}')
    result.require(sum(op['method'] != 'GET' for op in operations) == 102, 'expected 102 non-GET HTTP commands')

    actor_codes = {
        'ACTOR_ASSERTION_REQUIRED',
        'ACTOR_ASSERTION_INVALID',
        'ACTOR_ASSERTION_EXPIRED',
        'ACTOR_ASSERTION_AUDIENCE_MISMATCH',
        'ACTOR_ASSERTION_REQUEST_MISMATCH',
        'ACTOR_ASSERTION_REPLAYED',
    }
    for op in operations:
        oid = op['operation_id']
        union = []
        result.require(op['status'] == 'READY', f'{oid}: not READY')
        result.require(op['mutates_state'] == (op['operation_kind'] == 'COMMAND'), f'{oid}: mutates_state mismatch')
        if op['api'] == 'public-api':
            result.require(op['operation_kind'] == 'QUERY' and op['method'] == 'GET', f'{oid}: Public API must be read-only')
        if op['method'] != 'GET':
            result.require(op['idempotency'] == 'required', f'{oid}: write missing idempotency')
        if op['api'] == 'control-api':
            result.require(op['auth'] == 'actor-assertion-and-capability', f'{oid}: Control API auth must be actor assertion')
            result.require(actor_codes <= set(op['authorization_errors']), f'{oid}: actor assertion errors incomplete')
            result.require('CSRF_FAILED' not in op['authorization_errors'], f'{oid}: browser CSRF must not be a Control API concern')
            result.require('SESSION_EXPIRED' not in op['authorization_errors'], f'{oid}: browser session errors must not be a Control API concern')
        for field in op.get('request_fields', []) + op.get('response_fields', []):
            result.require(CAMEL.fullmatch(field['name']) is not None, f'{oid}: external field is not lowerCamelCase: {field["name"]}')
            result.require(field['name'] not in {'payload', 'filter'}, f'{oid}: generic request/response field {field["name"]!r}')
            result.require(field['type'] != 'object', f'{oid}: untyped object field {field["name"]}')
        for layer, field in LAYERS.items():
            result.require(field in op, f'{oid}: missing {field}')
            union.extend(op.get(field, []))
            for code in op.get(field, []):
                result.require(code in error_by and error_by[code]['layer'] == layer, f'{oid}: {code} wrong/missing layer')
        result.require(union == op['error_codes'], f'{oid}: layered error order/set differs from error_codes')

        result.require(
            all(isinstance(status, str) and HTTP_STATUS.fullmatch(status) for status in op['errors']),
            f'{oid}: every errors entry must be a quoted three-digit string',
        )
        mapped = []
        for status, codes in op['http_error_mapping'].items():
            result.require(isinstance(status, str) and HTTP_STATUS.fullmatch(status), f'{oid}: HTTP mapping key must be a three-digit string')
            mapped.extend(codes)
            for code in codes:
                result.require(code in error_by and str(error_by[code]['http_status']) == status, f'{oid}: {code} HTTP mapping mismatch')
        result.require(len(mapped) == len(set(mapped)) and set(mapped) == set(op['error_codes']), f'{oid}: http_error_mapping differs from error_codes')
        result.require(sorted(op['errors']) == sorted(op['http_error_mapping']), f'{oid}: errors status list differs from mapping')
        result.require(bool(op.get('implementation_files')), f'{oid}: missing implementation file mapping')

    login = by_id['startOidcLogin']
    result.require(
        login['auth'] == 'anonymous'
        and login['path'] == '/auth/login'
        and any(field['name'] == 'returnTo' for field in login['request_fields']),
        'startOidcLogin contract is not anonymous/typed',
    )
    result.require('startStepUpAuthentication' in by_id and by_id['startStepUpAuthentication']['path'] == '/auth/step-up/start', 'step-up start operation missing')
    result.require(by_id['completeStepUpAuthentication']['path'] == '/auth/step-up/callback' and by_id['completeStepUpAuthentication']['method'] == 'GET', 'step-up callback contract mismatch')

    for operation in operations:
        if operation['operation_kind'] != 'COMMAND':
            continue
        names = {field['name'] for field in operation.get('request_fields', [])}
        result.require('reauthProof' not in names, f"{operation['operation_id']}: raw step-up proof must not cross the Control API boundary")
        policy = operation['assurance_policy']
        possible = policy.get('step_up_possible') is True or any(condition.get('required_level') == 'STEP_UP' for condition in policy.get('conditions', []))
        result.require(('STEP_UP_REQUIRED' in operation['authorization_errors']) == possible, f"{operation['operation_id']}: step-up error differs from assurance policy")
        if possible:
            result.require(operation.get('step_up_policy', {}).get('identity_api_authorization_required') is True, f"{operation['operation_id']}: step-up policy is not Identity-API-owned")

    internal = load_yaml(root / 'specs/api/identity-service-internal.openapi.yaml')
    internal_ops = _ops(internal)
    result.require(len(internal_ops) == 9, f'expected 9 private Identity operations, found {len(internal_ops)}')
    result.require({'issueActorAssertion','closeStepUpAuthorization'} <= set(internal_ops), 'actor assertion issue/close operations are missing')
    resolve_schema = internal['components']['schemas']['ResolveSessionResponse']
    result.require('actorAssertion' not in resolve_schema.get('properties', {}), 'resolveInternalSession must not issue an Actor Assertion')
    login_callback = internal['components']['schemas']['ConsumeLoginCallbackResponse']
    result.require('actorAssertion' not in login_callback.get('properties', {}), 'login callback must not issue a request-unbound Actor Assertion')
    issue_schema = internal['components']['schemas']['IssueActorAssertionRequest']
    required_issue = {'opaqueSessionToken','downstreamRequest','operationId','requiredCapability','requiredAssuranceLevel','actionContext','actionDigest','stepUpAuthorizationToken','context'}
    result.require(set(issue_schema.get('required', [])) == required_issue, 'IssueActorAssertionRequest binding fields differ')

    all_ids = set()
    schema_total = 0
    for api in APIS:
        yaml_doc = load_yaml(root / f'specs/api/{api}.openapi.yaml')
        json_doc = load_json(root / f'specs/api/{api}.openapi.json')
        result.require(yaml_doc == json_doc, f'{api}: YAML and JSON differ')
        result.require(yaml_doc.get('openapi') == '3.1.0', f'{api}: OpenAPI version mismatch')
        result.require(yaml_doc.get('info', {}).get('version') == '13.0.0', f'{api}: OpenAPI info.version mismatch')
        try:
            validate_spec(yaml_doc)
        except Exception as exc:
            result.error(f'{api}: official OpenAPI validation failed: {exc}')
        found = _ops(yaml_doc)
        expected = ({op['operation_id'] for op in operations if op['api'] == api}
                    | {op['operation_id'] for op in addendum_by_id.values() if op['api'] == api})
        result.require(set(found) == expected, f'{api}: operation set differs')
        schemas = yaml_doc.get('components', {}).get('schemas', {})
        schema_total += len(schemas)
        if api == 'submission-api':
            schemes = yaml_doc.get('components', {}).get('securitySchemes', {})
            result.require(set(schemes) == {'BffServiceAssertion','ScopedSubmissionSession'}, 'Submission API security schemes differ')
            result.require(schemes['BffServiceAssertion'].get('name') == 'X-Gurine-Service-Assertion', 'Submission BFF assertion header differs')
            result.require(schemes['ScopedSubmissionSession'].get('name') == 'X-Gurine-Submission-Session', 'Submission scoped session header differs')
        if api == 'control-api':
            schemes = yaml_doc.get('components', {}).get('securitySchemes', {})
            result.require(set(schemes) == {'ActorAssertion'}, 'Control API must expose only the ActorAssertion security scheme')
            result.require(schemes['ActorAssertion'] == {
                'type': 'apiKey',
                'in': 'header',
                'name': 'X-Gurine-Actor-Assertion',
                'description': schemes['ActorAssertion']['description'],
            }, 'Control API ActorAssertion security scheme is malformed')
        for oid, (method, path, node) in found.items():
            result.require(oid not in all_ids, f'duplicate OpenAPI operation ID {oid}')
            all_ids.add(oid)
            op = by_id.get(oid)
            additive = addendum_by_id.get(oid)
            if additive is not None:
                binding = addendum_bindings.get(oid, {})
                result.require((method, path) == (additive['method'], additive['path']), f'{api}:{oid}: additive method/path mismatch')
                result.require(node.get('x-operation-kind') == additive['kind'], f'{api}:{oid}: additive operation kind mismatch')
                result.require(node.get('x-error-codes') == additive.get('errors', []), f'{api}:{oid}: additive error code mismatch')
                result.require(str(binding.get('success_status')) in node.get('responses', {}), f'{api}:{oid}: additive success status missing')
                if api == 'submission-api':
                    expected_security = ([{'BffServiceAssertion': [], 'ScopedSubmissionSession': []}]
                                         if 'SCOPED' in binding.get('transport_profile', '')
                                         else [{'BffServiceAssertion': []}])
                    result.require(node.get('security') == expected_security, f'{oid}: additive Submission OpenAPI security differs')
                elif api == 'control-api':
                    result.require(node.get('security') == [{'ActorAssertion': []}], f'{oid}: additive Control OpenAPI security differs')
                continue
            result.require(op is not None, f'{api}:{oid}: operation missing from base/addendum contract')
            result.require((method, path) == (op['method'], op['path']), f'{api}:{oid}: method/path mismatch')
            result.require(node.get('x-operation-kind') == op['operation_kind'], f'{api}:{oid}: operation kind mismatch')
            result.require(node.get('x-error-codes') == op['error_codes'], f'{api}:{oid}: error code mismatch')
            if api == 'submission-api':
                expected_security = [{'BffServiceAssertion': []}] if op['auth'] != 'bff-service-assertion-and-scoped-submission-session' else [{'BffServiceAssertion': [], 'ScopedSubmissionSession': []}]
                result.require(node.get('security') == expected_security, f'{oid}: Submission OpenAPI security differs from auth contract')
                result.require(not any(token in path for token in ['{requestToken}','{draftToken}','{receiptToken}','{managementToken}','{verificationToken}']), f'{oid}: raw bearer-like token is forbidden in Submission API path')
            if api == 'control-api':
                result.require(node.get('security') == [{'ActorAssertion': []}], f'{oid}: Control OpenAPI must require ActorAssertion')
            success = str(op['success_status'])
            result.require(success in node['responses'], f'{api}:{oid}: missing success status {success}')
            for status, codes in op['http_error_mapping'].items():
                result.require(node['responses'].get(status, {}).get('x-error-codes') == codes, f'{api}:{oid}: OpenAPI error response mismatch {status}')
        for ref in _refs(yaml_doc):
            if ref.startswith('#/components/schemas/'):
                result.require(ref.rsplit('/', 1)[-1] in schemas, f'{api}: unresolved ref {ref}')
        for name, schema in schemas.items():
            if schema.get('type') == 'object':
                result.require(schema.get('additionalProperties') is False or name == 'ProblemDetails', f'{api}: open object schema {name}')
    result.require(all_ids == (set(by_id) | set(addendum_by_id)), 'OpenAPI global set differs')

    internal_y = load_yaml(root / 'specs/api/identity-service-internal.openapi.yaml')
    internal_j = load_json(root / 'specs/api/identity-service-internal.openapi.json')
    result.require(internal_y == internal_j, 'internal identity OpenAPI YAML and JSON differ')
    result.require(internal_y.get('info', {}).get('version') == '13.0.0', 'internal identity OpenAPI version mismatch')
    try:
        validate_spec(internal_y)
    except Exception as exc:
        result.error(f'internal identity API: official OpenAPI validation failed: {exc}')
    internal_ops = _ops(internal_y)
    expected_internal = {
        'createLoginTransaction', 'consumeLoginCallback', 'createStepUpTransaction',
        'consumeStepUpCallback', 'resolveInternalSession', 'revokeInternalSession',
        'getSecurityManagementRedirectInternal', 'issueActorAssertion', 'closeStepUpAuthorization',
    }
    result.require(set(internal_ops) == expected_internal, 'internal identity API operation set differs')
    result.require(all(path.startswith('/internal/') for _, path, _ in internal_ops.values()), 'internal identity API contains non-internal path')
    service_codes = {
        'SERVICE_ASSERTION_REQUIRED', 'SERVICE_ASSERTION_INVALID', 'SERVICE_ASSERTION_EXPIRED',
        'SERVICE_ASSERTION_AUDIENCE_MISMATCH', 'SERVICE_ASSERTION_REQUEST_MISMATCH', 'SERVICE_ASSERTION_REPLAYED',
    }
    for oid, (method, _path, node) in internal_ops.items():
        result.require(method == 'POST', f'{oid}: internal identity operation must be POST')
        result.require(node.get('security') == [{'ServiceAssertion': []}], f'{oid}: service assertion required')
        result.require(service_codes <= set(node.get('x-error-codes', [])), f'{oid}: service assertion errors incomplete')
    internal_schemas = internal_y.get('components', {}).get('schemas', {})
    result.require('ServiceAssertionToken' in internal_schemas and 'ActorAssertionToken' in internal_schemas, 'assertion token schemas missing from internal OpenAPI')
    issue_schema=internal_schemas.get('IssueActorAssertionRequest',{})
    result.require('requiredAssuranceLevel' in issue_schema.get('required',[]),'issueActorAssertion must require requiredAssuranceLevel')
    result.require(issue_schema.get('properties',{}).get('opaqueSessionToken') is not None,'issueActorAssertion must receive opaqueSessionToken')

    for api in APIS:
        doc = load_yaml(root / f'specs/api/{api}.openapi.yaml')
        schemas = doc.get('components', {}).get('schemas', {})
        for name, schema in schemas.items():
            applied = schema.get('properties', {}).get('appliedFilters')
            if applied is not None:
                result.require('$ref' in applied, f'{api}:{name}: appliedFilters must use typed schema')
            counts_schema = schema.get('properties', {}).get('caseCounts')
            if counts_schema is not None:
                result.require(counts_schema == {'$ref': '#/components/schemas/CaseStateCounts'}, f'{api}:{name}: caseCounts must use CaseStateCounts')

    result.stats.update({
        'operations': 212,
        'query_operations': 107,
        'command_operations': 105,
        'http_write_operations': 102,
        'public_operations': 41,
        'submission_operations': 34,
        'control_operations': 131,
        'identity_operations': 6,
        'openapi_schemas_total': schema_total,
        'error_codes': len(error_by),
        'internal_identity_operations': len(internal_ops),
    })
