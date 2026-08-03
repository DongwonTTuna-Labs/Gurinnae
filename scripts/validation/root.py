from __future__ import annotations

import collections
from pathlib import Path

from verify_migrations import EXPECTED_BASE_MIGRATIONS

from .http_operation_inventory import (
    BASE_EXTERNAL_APIS,
    derive_http_operation_inventory,
    non_get_count,
    operation_api_counts,
    operation_ids,
    operation_kind_counts,
)
from .loaders import load_yaml
from .models import Validation


REQUIRED = [
    'README.md', 'AGENTS.md', 'CODEX_START_HERE.md', 'FINAL_BUILD_CONTRACT.md',
    'SPECIFICATION_VERSION', 'requirements-spec.in', 'requirements-spec.txt',
    '.python-version', 'specs/verification/python-toolchain.yaml',
    'specs/product/final-product-contract.yaml',
    'specs/product/owner-addendum-2026-07-14.yaml',
    'specs/product/business-model-contract.yaml',
    'specs/product/addendum-operation-contracts.yaml',
    'specs/product/addendum-event-contracts.yaml',
    'specs/domain/state-machines.yaml', 'specs/domain/state-transition-tests.yaml',
    'specs/api/operation-contracts.yaml', 'specs/api/error-code-catalog.yaml',
    'specs/application/command-semantics.yaml',
    'specs/application/optimistic-concurrency.yaml',
    'specs/application/optimistic-concurrency.runtime.json',
    'specs/auth/assurance-policy.yaml', 'specs/auth/assertion-contract.yaml',
    'specs/auth/service-assertion.schema.json',
    'specs/auth/actor-assertion.schema.json',
    'specs/auth/test-vectors/service-assertion.json',
    'specs/auth/test-vectors/actor-assertion.json',
    'specs/auth/test-vectors/negative-cases.json',
    'specs/api/operation-persistence.yaml', 'specs/events/event-catalog.yaml',
    'specs/events/consumer-catalog.yaml', 'specs/database/schema-catalog.yaml',
    'specs/database/operation-table-matrix.yaml',
    'specs/database/privilege-matrix.yaml',
    'specs/database/runtime-security-tests.yaml',
    'specs/deployment/egress-allowlist.yaml',
    'specs/deployment/service-config-map.yaml',
    'specs/agents/agent-catalog.yaml', 'specs/agents/eval-manifest.yaml',
    'specs/connectors/connector-catalog.yaml',
    'specs/detection/rule-evaluation-catalog.yaml',
    'specs/ui/screen-catalog.yaml',
    'specs/traceability/final-traceability.yaml',
    'specs/traceability/internal-identity-traceability.yaml',
    'specs/engineering/code-quality-contract.yaml',
    'tests/acceptance/acceptance-catalog.yaml',
    'tests/acceptance/executable-mapping.yaml',
    'verification/python-clean-environments.yaml',
    'verification/postgres-runtime-baseline.json',
    'scripts/compare_postgres_runtime.py',
    'specs/cryptography/session-cookie-envelope.yaml',
    'specs/cryptography/field-encryption-envelope.yaml',
    'specs/cryptography/step-up-transaction-envelope.yaml',
    'specs/cryptography/step-up-authorization-envelope.yaml',
    'specs/cryptography/session-cookie-payload.schema.json',
    'specs/cryptography/step-up-transaction-payload.schema.json',
    'specs/cryptography/step-up-authorization-payload.schema.json',
    'specs/parsers/parser-catalog.yaml', 'specs/parsers/sandbox-contract.yaml',
    'specs/parsers/extraction-result.schema.json',
    'specs/parsers/fixture-manifest.yaml', 'specs/parsers/reference_harness.py',
    'verification/postgres-runtime/package.json',
    'verification/postgres-runtime/package-lock.json',
    'verification/postgres-runtime/verify.mjs',
    'verification/codegen-compatibility.json',
    'verification/sql-openapi-parser.json', 'verification/parser-reference.json',
    'verification/cryptography-reference.json',
    'docs/61-v12-assurance-legal-audit-parser-closure.md',
    'verification/final-reference/render-results.json',
    'tasks/FINAL-IMPLEMENTATION.md', 'tasks/FINAL-VERIFICATION.md',
]
IGNORED = {'.venv', 'venv', 'node_modules', 'target', '.git', '.pytest_cache'}


def ignored(path: Path, root: Path) -> bool:
    return any(part in IGNORED for part in path.relative_to(root).parts)


def validate(root: Path, result: Validation, version: str) -> None:
    for relative in REQUIRED:
        result.require((root / relative).is_file(), f'missing required authority file: {relative}')
    actual = (root / 'SPECIFICATION_VERSION').read_text(encoding='utf-8').strip()
    result.require(actual == version, f'SPECIFICATION_VERSION={actual!r}, expected {version!r}')
    caches = [
        path.relative_to(root).as_posix()
        for path in root.rglob('__pycache__')
        if not ignored(path, root)
    ]
    pyc = [
        path.relative_to(root).as_posix()
        for path in root.rglob('*.pyc')
        if not ignored(path, root)
    ]
    result.require(not caches, f'Python cache directories forbidden: {caches[:5]}')
    result.require(not pyc, f'Python bytecode forbidden: {pyc[:5]}')

    product = load_yaml(root / 'specs/product/final-product-contract.yaml')
    product_counts = product['counts']
    operation_inventory = derive_http_operation_inventory(root)
    base_operations = operation_inventory.base_external
    additive_operations = operation_inventory.additive_all
    additive_external = operation_inventory.additive_external
    private_identity_api = operation_inventory.private_identity_api
    final_external_operations = operation_inventory.final_external
    all_scope_http_operations = operation_inventory.all_scope_http
    base_ids = operation_ids(base_operations)
    additive_ids = operation_ids(additive_operations)
    additive_external_ids = operation_ids(additive_external)
    private_identity_api_ids = operation_ids(private_identity_api)
    base_id_set = set(base_ids)
    additive_id_set = set(additive_ids)
    additive_external_id_set = set(additive_external_ids)
    private_identity_api_id_set = set(private_identity_api_ids)
    business = load_yaml(root / 'specs/product/business-model-contract.yaml')
    funding_download_operation_id = business['donation_funding_boundary'][
        'funding_report_download'
    ]['operation_id']
    result.require(
        len(base_ids) == len(base_id_set)
        and len(additive_ids) == len(additive_id_set)
        and not (base_id_set & additive_id_set),
        'base and additive HTTP operation IDs must be unique and disjoint',
    )
    result.require(
        additive_external_id_set | private_identity_api_id_set == additive_id_set
        and not (additive_external_id_set & private_identity_api_id_set),
        'additive external and private Identity API partitions must be exact and disjoint',
    )
    result.require(
        additive_external_id_set
        == operation_inventory.declared_additive_external_ids
        == operation_inventory.binding_additive_external_ids
        and private_identity_api_id_set
        == operation_inventory.declared_private_identity_api_ids
        == operation_inventory.binding_private_identity_api_ids,
        'additive HTTP source partitions differ from resource binding scopes',
    )
    result.require(
        funding_download_operation_id in additive_external_id_set,
        'R6e funding download is absent from the additive external operation set',
    )
    final_by_api = operation_api_counts(final_external_operations)
    final_by_kind = operation_kind_counts(final_external_operations)
    derived_operation_counts = {
        'operations': len(final_external_operations),
        'public_operations': final_by_api['public-api'],
        'submission_operations': final_by_api['submission-api'],
        'control_operations': final_by_api['control-api'],
        'identity_flows': final_by_api['identity-provider'],
        'query_operations': final_by_kind['QUERY'],
        'command_operations': final_by_kind['COMMAND'],
        'http_write_operations': non_get_count(final_external_operations),
    }
    all_scope_by_kind = operation_kind_counts(all_scope_http_operations)
    derived_all_scope_counts = {
        'all_scope_http_operations': len(all_scope_http_operations),
        'all_scope_http_query_operations': all_scope_by_kind['QUERY'],
        'all_scope_http_command_operations': all_scope_by_kind['COMMAND'],
        'all_scope_http_write_operations': non_get_count(all_scope_http_operations),
    }
    for key, value in {**derived_operation_counts, **derived_all_scope_counts}.items():
        result.require(
            product_counts.get(key) == value,
            f'product contract {key}={product_counts.get(key)}, derived final={value}',
        )
    result.require(
        len(base_operations) == 217
        and set(operation_api_counts(base_operations)) == BASE_EXTERNAL_APIS
        and operation_api_counts(base_operations)
        == {'public-api': 43, 'submission-api': 34, 'control-api': 134, 'identity-provider': 6}
        and operation_kind_counts(base_operations) == {'QUERY': 110, 'COMMAND': 107}
        and non_get_count(base_operations) == 104,
        'immutable base operation layer differs',
    )
    result.require(
        len(additive_operations) == 54
        and len(additive_external) == 51
        and len(private_identity_api) == 3
        and operation_api_counts(additive_external)
        == {'public-api': 1, 'submission-api': 8, 'control-api': 42}
        and operation_kind_counts(additive_external)
        == {'QUERY': 13, 'COMMAND': 38}
        and non_get_count(additive_external) == 38
        and operation_api_counts(private_identity_api) == {'identity-api': 3}
        and operation_kind_counts(private_identity_api) == {'COMMAND': 3}
        and non_get_count(private_identity_api) == 3,
        'additive external/private Identity API operation layers differ',
    )
    result.require(
        len(final_external_operations) == 268
        and final_by_api
        == {'public-api': 44, 'submission-api': 42, 'control-api': 176, 'identity-provider': 6}
        and final_by_kind == {'QUERY': 123, 'COMMAND': 145}
        and non_get_count(final_external_operations) == 142,
        'final external HTTP operation layer differs',
    )
    result.require(
        len(all_scope_http_operations) == 271
        and all_scope_by_kind == {'QUERY': 123, 'COMMAND': 148}
        and non_get_count(all_scope_http_operations) == 145,
        'complete all-scope HTTP operation layer differs',
    )

    screens = load_yaml(root / 'specs/ui/screen-catalog.yaml')['screens']
    screen_by_surface = collections.Counter(row['surface'] for row in screens)
    result.require(
        product_counts.get('screens') == len(screens) == 95,
        f'final screen count differs: product={product_counts.get("screens")} source={len(screens)}',
    )
    result.require(
        screen_by_surface == {'public': 35, 'response': 8, 'internal': 52},
        f'final screen surface counts differ: {dict(screen_by_surface)}',
    )
    fundraising_screen_id = business['donation_funding_boundary']['donation_screen']['id']
    result.require(
        fundraising_screen_id == 'PUB-035'
        and fundraising_screen_id in {row['id'] for row in screens},
        'R6e fundraising screen is absent from the final screen catalog',
    )

    owner_addendum = load_yaml(root / 'specs/product/owner-addendum-2026-07-14.yaml')
    database_delta = owner_addendum['database_delta']
    base_catalog = load_yaml(root / 'specs/database/schema-catalog.yaml')
    runtime_migrations = sorted((root / 'db/migrations').glob('*.sql'))
    post_base_migrations = len(runtime_migrations) - EXPECTED_BASE_MIGRATIONS
    result.require(
        base_catalog['migration_count'] == database_delta['base_migrations'] == EXPECTED_BASE_MIGRATIONS,
        'immutable base migration layer differs',
    )
    result.require(
        base_catalog['table_count'] == database_delta['base_active_tables'] == 107,
        'immutable base table layer differs',
    )
    result.require(
        len(database_delta['migrations']) == database_delta['additive_migrations'] == 15,
        'owner-declared migration inventory differs',
    )
    result.require(
        product_counts.get('database_migrations') == len(runtime_migrations) == 41
        and product_counts.get('post_base_migrations') == post_base_migrations == 17
        and product_counts.get('owner_declared_migrations') == len(database_delta['migrations']),
        'final runtime migration layers differ',
    )
    derived_final_tables = (
        base_catalog['table_count'] + database_delta['additive_table_count']
    )
    result.require(
        product_counts.get('database_tables')
        == database_delta['final_active_tables']
        == derived_final_tables
        == 309,
        'final database table layers differ',
    )

    base_events = load_yaml(root / 'specs/events/event-catalog.yaml')['events']
    base_event_ids = {row['event_type'] for row in base_events}
    additive_events = load_yaml(root / 'specs/product/addendum-event-contracts.yaml')['events']
    owner_event_ids = set(owner_addendum['event_delta']['event_types'])
    result.require(
        len(base_events) == product_counts.get('domain_and_integration_events') == 99,
        'product domain_and_integration_events must preserve the immutable base catalog count',
    )
    result.require(
        set(additive_events) == owner_event_ids
        and len(additive_events) == 104
        and not (base_event_ids & set(additive_events)),
        'additive event layer differs or collides with the immutable base catalog',
    )
    result.require(
        len(base_event_ids | set(additive_events)) == 203,
        'effective base plus additive event count differs',
    )

    acceptance = load_yaml(root / 'tests/acceptance/acceptance-catalog.yaml')
    result.require(
        product_counts.get('acceptance_features') == len(acceptance['features']) == 35
        and product_counts.get('acceptance_scenarios') == acceptance['scenario_count'] == 271,
        'sealed base acceptance counts differ',
    )
    result.require(product_counts.get('agent_eval_cases') == 50, 'agent eval count differs')
    runtime_services = load_yaml(root / 'specs/deployment/service-config-map.yaml')['services']
    compose_services = load_yaml(root / 'compose.yaml')['services']
    result.require(
        product_counts.get('services') == len(runtime_services) == 18,
        'runtime service inventory differs',
    )
    result.require(
        product_counts.get('compose_services') == len(compose_services) == 22,
        'Compose service inventory differs',
    )

    toolchain = load_yaml(root / 'specs/verification/python-toolchain.yaml')
    result.require(
        toolchain['status'] == 'FINAL' and toolchain['installer']['hashes_required'] is True,
        'Python verifier lock contract incomplete',
    )
    result.require(
        (root / '.python-version').read_text(encoding='utf-8').strip()
        == str(toolchain['python']['verified_patch']),
        'Python patch pin differs from verifier contract',
    )
    result.stats.update({
        'required_authority_files': len(REQUIRED),
        'base_operations': len(base_operations),
        'additive_http_operations': len(additive_operations),
        'additive_external_operations': len(additive_external),
        'private_identity_api_operations': len(private_identity_api),
        'final_external_operations': len(final_external_operations),
        'all_scope_http_operations': len(all_scope_http_operations),
        'base_database_migrations': base_catalog['migration_count'],
        'post_base_database_migrations': post_base_migrations,
        'runtime_database_migrations': len(runtime_migrations),
        'base_database_tables': base_catalog['table_count'],
        'additive_database_tables': database_delta['additive_table_count'],
        'final_database_tables': derived_final_tables,
        'base_events': len(base_events),
        'additive_events': len(additive_events),
        'effective_events': len(base_event_ids | set(additive_events)),
    })
