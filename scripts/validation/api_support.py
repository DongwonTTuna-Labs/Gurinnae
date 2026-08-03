from __future__ import annotations

import re


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
PROVIDER_CONTROL_SIDE_DOOR_OPERATION_IDS = frozenset({
    'disableProviderRouting',
    'setModelAutoUpgrade',
    'testProviderConnection',
    'upgradeProviderModel',
})
PROVIDER_CONTROL_DIRECT_HTTP_EFFECT = {
    'entrypoint': 'ACTION_PROPOSAL',
    'state_effect': 'UNCHANGED',
    'writes': [],
    'outbox_events': [],
    'external_effects': [],
    'authorized_effect_owner': 'private.ExecuteProviderControl',
}


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


def _error_catalog_for_operation(
    operation_id,
    base_error_by,
    additive_error_by,
    base_extension_operation_ids,
):
    if (
        operation_id in base_extension_operation_ids
        or operation_id in PROVIDER_CONTROL_SIDE_DOOR_OPERATION_IDS
    ):
        return base_error_by | additive_error_by
    return base_error_by
