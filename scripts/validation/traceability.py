from __future__ import annotations
from pathlib import Path
from verify_migrations import EXPECTED_BASE_MIGRATIONS
from .api_support import _ops
from .http_operation_inventory import (
    derive_http_operation_inventory,
    non_get_count,
    operation_api_counts,
    operation_ids,
    operation_kind_counts,
)
from .loaders import load_yaml
from .models import Validation

def validate(root: Path, result: Validation) -> None:
    trace = load_yaml(root / 'specs/traceability/final-traceability.yaml')
    product_counts = load_yaml(root / 'specs/product/final-product-contract.yaml')['counts']
    operation_inventory = derive_http_operation_inventory(root)
    base_operations = {
        row['operation_id']: row for row in operation_inventory.base_external
    }
    additive_external = {
        row['operation_id']: row for row in operation_inventory.additive_external
    }
    private_identity_api_ids = set(operation_ids(operation_inventory.private_identity_api))
    final_external_rows = operation_inventory.final_external
    all_scope_http_rows = operation_inventory.all_scope_http
    persistence = {
        row['operation_id']: row
        for row in load_yaml(root / 'specs/api/operation-persistence.yaml')['operations']
    }
    screens = {
        row['id']: row for row in load_yaml(root / 'specs/ui/screen-catalog.yaml')['screens']
    }
    additive_bindings = load_yaml(
        root / 'specs/product/addendum-resource-error-contracts.yaml'
    )['operation_bindings']
    additive_contract = load_yaml(
        root / 'specs/product/addendum-operation-contracts.yaml'
    )
    additive_persistence = load_yaml(
        root / 'specs/product/addendum-persistence-contracts.yaml'
    )['exact_persistence_registry']
    additive_query_persistence = additive_persistence['query_persistence']
    additive_command_persistence = additive_persistence['external_command_persistence']
    additive_command_semantics = load_yaml(
        root / 'specs/product/addendum-command-semantics.yaml'
    )['external_commands']
    additive_screen_bindings = additive_contract['operation_screen_bindings']
    base_id_set = set(base_operations)
    additive_external_id_set = set(additive_external)
    result.require(
        not (base_id_set & additive_external_id_set)
        and not (base_id_set & private_identity_api_ids)
        and not (additive_external_id_set & private_identity_api_ids),
        'trace base, additive external and private Identity API sets must be disjoint',
    )
    additive_query_ids = {
        row['operation_id']
        for row in operation_inventory.additive_all
        if row['kind'] == 'QUERY'
    }
    additive_command_ids = {
        row['operation_id']
        for row in operation_inventory.additive_all
        if row['kind'] == 'COMMAND'
    }
    result.require(
        set(additive_query_persistence) == additive_query_ids
        and set(additive_command_persistence)
        == set(additive_command_semantics)
        == additive_command_ids,
        'additive query/command persistence partitions differ from HTTP sources',
    )

    final_operation_ids = base_id_set | additive_external_id_set
    by_api = operation_api_counts(final_external_rows)
    by_kind = operation_kind_counts(final_external_rows)
    all_scope_by_kind = operation_kind_counts(all_scope_http_rows)
    base_catalog = load_yaml(root / 'specs/database/schema-catalog.yaml')
    base_events = load_yaml(root / 'specs/events/event-catalog.yaml')['events']
    acceptance = load_yaml(root / 'tests/acceptance/acceptance-catalog.yaml')
    expected = {
        'screens': len(screens),
        'operations': len(final_external_rows),
        'query_operations': by_kind['QUERY'],
        'command_operations': by_kind['COMMAND'],
        'http_write_operations': non_get_count(final_external_rows),
        'all_scope_http_operations': len(all_scope_http_rows),
        'all_scope_http_query_operations': all_scope_by_kind['QUERY'],
        'all_scope_http_command_operations': all_scope_by_kind['COMMAND'],
        'all_scope_http_write_operations': non_get_count(all_scope_http_rows),
        # These three fields intentionally preserve frozen base provenance. The
        # additive/runtime layers are checked separately below.
        'database_tables': base_catalog['table_count'],
        'database_migrations': base_catalog['migration_count'],
        'roles': 15,
        'capabilities': 31,
        'events': len(base_events),
        'acceptance_scenarios': acceptance['scenario_count'],
        'public_operations': by_api['public-api'],
        'submission_operations': by_api['submission-api'],
        'control_operations': by_api['control-api'],
        'identity_operations': by_api['identity-provider'],
        'commands': by_kind['COMMAND'],
        'queries': by_kind['QUERY'],
    }
    result.require(
        trace['counts'] == expected,
        f'traceability counts differ: expected={expected} actual={trace["counts"]}',
    )
    result.require(
        expected['screens'] == product_counts['screens'] == 95
        and expected['operations'] == product_counts['operations'] == 268
        and expected['public_operations'] == product_counts['public_operations'] == 44
        and expected['submission_operations']
        == product_counts['submission_operations'] == 42
        and expected['control_operations'] == product_counts['control_operations'] == 176
        and expected['query_operations'] == product_counts['query_operations'] == 123
        and expected['command_operations'] == product_counts['command_operations'] == 145
        and expected['http_write_operations'] == product_counts['http_write_operations'] == 142,
        'final trace screen/operation layer differs from the final product contract',
    )
    for key in [
        'all_scope_http_operations',
        'all_scope_http_query_operations',
        'all_scope_http_command_operations',
        'all_scope_http_write_operations',
    ]:
        result.require(
            expected[key] == product_counts[key],
            f'trace/product all-scope HTTP count differs: {key}',
        )
    result.require(
        expected['database_migrations'] == EXPECTED_BASE_MIGRATIONS == 24
        and expected['database_tables'] == 107
        and expected['events'] == product_counts['domain_and_integration_events'] == 99,
        'trace frozen base database/event layer differs',
    )
    result.require(
        {row['screen_id'] for row in trace['screens']} == set(screens),
        'traceability screen set differs',
    )
    traced = {row['operation_id']: row for row in trace['operations']}
    result.require(
        len(traced) == len(trace['operations'])
        and set(traced) == final_operation_ids,
        'traceability final operation set differs or contains duplicates',
    )
    additive_trace_ids = {
        row['operation_id']
        for row in trace['operations']
        if row.get('trace_scope') == 'ADDITIVE_EXTERNAL'
    }
    result.require(
        additive_trace_ids == additive_external_id_set
        and len(additive_trace_ids) == 51,
        'traceability additive external scope must be the exact 51-operation set',
    )
    private_identity_registry = trace.get('private_identity_api_registry', {})
    private_identity_registry_ids = private_identity_registry.get(
        'private_identity_api_operation_ids', []
    ) if isinstance(private_identity_registry, dict) else []
    result.require(
        isinstance(private_identity_registry, dict)
        and private_identity_registry.get('scope') == 'PRIVATE_IDENTITY_API'
        and isinstance(private_identity_registry_ids, list)
        and len(private_identity_registry_ids)
        == len(set(private_identity_registry_ids))
        and set(private_identity_registry_ids) == private_identity_api_ids,
        'traceability private Identity API registry differs',
    )

    for operation_id, operation in base_operations.items():
        item = traced[operation_id]
        persistence_item = persistence[operation_id]
        for key, trace_key in [
            ('api', 'api'), ('method', 'method'), ('path', 'path'),
            ('operation_kind', 'kind'), ('request_schema', 'request_schema'),
            ('response_schema', 'response_schema'), ('success_status', 'success_status'),
        ]:
            result.require(
                item[trace_key] == operation[key],
                f'{operation_id}: trace {trace_key} mismatch',
            )
        for key in [
            'repository_methods', 'statements', 'domain_events',
            'integration_events', 'audit_action',
        ]:
            result.require(
                item[key] == persistence_item[key],
                f'{operation_id}: trace {key} mismatch',
            )
        for key in ['handler', 'application', 'integration_test', 'contract_test']:
            result.require(bool(item.get(key)), f'{operation_id}: trace missing {key}')

    for operation_id, additive_operation in additive_external.items():
        additive_trace = traced.get(operation_id, {})
        additive_binding = additive_bindings.get(operation_id, {})
        expected_consuming_screens = sorted({
            binding.split('.', maxsplit=1)[0]
            for binding in additive_screen_bindings.get(operation_id, [])
        })
        expected_additive_transport = {
            'api': additive_operation['api'],
            'method': additive_operation['method'],
            'path': additive_operation['path'],
            'kind': additive_operation['kind'],
            'request_schema': additive_binding.get('request_schema'),
            'response_schema': additive_binding.get('success_schema'),
            'success_status': additive_binding.get('success_status'),
        }
        result.require(
            additive_binding.get('scope') == 'ADDITIVE_EXTERNAL',
            f'{operation_id}: additive trace binding scope mismatch',
        )
        result.require(
            additive_binding.get('source_pointer')
            == (
                'specs/product/addendum-operation-contracts.yaml'
                f'#operations[operation_id={operation_id}]'
            ),
            f'{operation_id}: additive binding source pointer mismatch',
        )
        result.require(
            additive_trace.get('trace_scope') == 'ADDITIVE_EXTERNAL',
            f'{operation_id}: additive trace scope mismatch',
        )
        for key, value in expected_additive_transport.items():
            result.require(
                additive_trace.get(key) == value,
                f'{operation_id}: additive trace {key} mismatch',
            )
        for key in [
            'handler', 'application', 'integration_test', 'generated_client',
            'contract_test',
        ]:
            source_path = additive_trace.get(key)
            result.require(
                isinstance(source_path, str)
                and bool(source_path)
                and (root / source_path).exists(),
                f'{operation_id}: additive trace source path missing: {key}',
            )
        result.require(
            additive_trace.get('consuming_screens') == expected_consuming_screens,
            f'{operation_id}: additive trace consuming screens mismatch',
        )
        assurance = additive_operation.get('assurance')
        assurance_policy = additive_trace.get('assurance_policy', {})
        result.require(
            additive_trace.get('assurance_level') == assurance
            and isinstance(assurance_policy, dict)
            and assurance_policy.get('default') == assurance
            and additive_trace.get('step_up_required', False)
            == (assurance == 'STEP_UP'),
            f'{operation_id}: additive trace assurance differs',
        )

        if additive_operation['kind'] == 'QUERY':
            persistence_item = additive_query_persistence.get(operation_id, {})
            expected_pointer = (
                'specs/product/addendum-persistence-contracts.yaml'
                '#exact_persistence_registry.query_persistence.'
                f'{operation_id}'
            )
            result.require(
                additive_trace.get('persistence_contract') == expected_pointer,
                f'{operation_id}: additive query persistence pointer mismatch',
            )
            for key in [
                'repository_methods', 'statements', 'domain_events',
                'integration_events', 'audit_action', 'concurrency',
            ]:
                result.require(
                    key in additive_trace
                    and key in persistence_item
                    and additive_trace[key] == persistence_item[key],
                    f'{operation_id}: additive query trace {key} mismatch',
                )
            continue

        persistence_item = additive_command_persistence.get(operation_id, {})
        semantics_item = additive_command_semantics.get(operation_id, {})
        expected_pointer = (
            'specs/product/addendum-persistence-contracts.yaml'
            '#exact_persistence_registry.external_command_persistence.'
            f'{operation_id}'
        )
        expected_events = semantics_item.get('outbox', {}).get('events')
        expected_isolation = semantics_item.get('transaction', {}).get('isolation')
        result.require(
            bool(persistence_item)
            and additive_trace.get('persistence_contract') == expected_pointer,
            f'{operation_id}: additive command persistence pointer mismatch',
        )
        result.require(
            expected_events is not None
            and additive_trace.get('domain_events') == expected_events,
            f'{operation_id}: additive command domain events mismatch',
        )
        result.require(
            additive_trace.get('integration_events') == [],
            f'{operation_id}: additive command integration events must be empty',
        )
        result.require(
            additive_trace.get('audit_action') == f'command.{operation_id}',
            f'{operation_id}: additive command audit action mismatch',
        )
        result.require(
            expected_isolation is not None
            and additive_trace.get('concurrency') == {
                'mode': 'ADDITIVE_PERSISTENCE_CONTRACT',
                'isolation': expected_isolation,
            },
            f'{operation_id}: additive command concurrency mismatch',
        )

    owner_addendum = load_yaml(root / 'specs/product/owner-addendum-2026-07-14.yaml')
    database_delta = owner_addendum['database_delta']
    additive_events = load_yaml(root / 'specs/product/addendum-event-contracts.yaml')['events']
    runtime_migration_count = len(list((root / 'db/migrations').glob('*.sql')))
    result.require(
        database_delta['base_active_tables'] == expected['database_tables']
        and database_delta['additive_table_count'] == 202
        and database_delta['final_active_tables'] == 309,
        'trace database base/additive/final layer derivation differs',
    )
    result.require(
        runtime_migration_count - expected['database_migrations'] == 17
        and runtime_migration_count == 41,
        'trace base/runtime migration layer derivation differs',
    )
    result.require(
        len(additive_events) == 104
        and not ({row['event_type'] for row in base_events} & set(additive_events))
        and len(base_events) + len(additive_events) == 203,
        'trace base/additive/effective event layer derivation differs',
    )

    internal = load_yaml(root / 'specs/traceability/internal-identity-traceability.yaml')
    internal_openapi = load_yaml(root / 'specs/api/identity-service-internal.openapi.yaml')
    expected_internal = {
        node['operationId']
        for item in internal_openapi['paths'].values()
        for node in item.values()
        if isinstance(node, dict) and node.get('operationId')
    }
    internal_by = {row['operation_id']: row for row in internal['operations']}
    private_identity_openapi_ids = set(_ops(
        load_yaml(root / 'specs/api/identity-api.openapi.yaml')
    ))
    result.require(
        internal['status'] == 'FINAL' and internal['operation_count'] == 9,
        'internal identity traceability header mismatch',
    )
    result.require(
        set(internal_by) == expected_internal,
        'internal identity traceability operation set differs',
    )
    result.require(
        private_identity_openapi_ids
        == private_identity_api_ids
        == operation_inventory.declared_private_identity_api_ids
        == operation_inventory.binding_private_identity_api_ids
        and not (set(internal_by) & private_identity_api_ids),
        'three-operation private Identity API must be exact and disjoint from the nine-operation Identity service',
    )
    for operation_id, item in internal_by.items():
        for key in [
            'handler', 'application', 'persistence', 'generated_client',
            'integration_test', 'contract_test',
        ]:
            result.require(
                bool(item.get(key)), f'{operation_id}: internal identity trace missing {key}'
            )
        result.require(
            item['auth'] == 'service-assertion',
            f'{operation_id}: internal identity auth mismatch',
        )
    result.stats.update({
        'trace_screens': len(trace['screens']),
        'trace_operations': len(trace['operations']),
        'trace_private_identity_api_operations': len(private_identity_api_ids),
        'trace_all_scope_http_operations': len(all_scope_http_rows),
        'trace_base_database_migrations': expected['database_migrations'],
        'trace_runtime_database_migrations': runtime_migration_count,
        'trace_base_database_tables': expected['database_tables'],
        'trace_additive_database_tables': database_delta['additive_table_count'],
        'trace_final_database_tables': database_delta['final_active_tables'],
        'trace_base_events': len(base_events),
        'trace_additive_events': len(additive_events),
        'trace_effective_events': len(base_events) + len(additive_events),
        'internal_identity_trace_operations': len(internal_by),
    })
