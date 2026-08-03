from __future__ import annotations
import json
import tomllib
from pathlib import Path
from .loaders import load_yaml
from .models import Validation


PAYMENT_FIXTURE_KEYRING_ENV = {
    'PAYMENT_FIXTURE_BILLING_KEY_VAULT_HMAC_KEY_CURRENT',
    'PAYMENT_FIXTURE_BILLING_KEY_VAULT_HMAC_KEY_CURRENT_VERSION',
    'PAYMENT_FIXTURE_BILLING_KEY_VAULT_HMAC_KEY_PREVIOUS',
    'PAYMENT_FIXTURE_BILLING_KEY_VAULT_HMAC_KEY_PREVIOUS_VERSION',
    'PAYMENT_FIXTURE_IDENTITY_HMAC_KEY_CURRENT',
    'PAYMENT_FIXTURE_IDENTITY_HMAC_KEY_CURRENT_VERSION',
    'PAYMENT_FIXTURE_IDENTITY_HMAC_KEY_PREVIOUS',
    'PAYMENT_FIXTURE_IDENTITY_HMAC_KEY_PREVIOUS_VERSION',
}


def _cargo_workspace_members(root: Path) -> list[str]:
    document = tomllib.loads((root / 'Cargo.toml').read_text(encoding='utf-8'))
    members = document.get('workspace', {}).get('members')
    if not isinstance(members, list) or not all(isinstance(member, str) for member in members):
        raise ValueError('Cargo.toml workspace.members must be a string array')
    return members


def _bun_workspace_members(root: Path) -> list[str]:
    document = json.loads((root / 'package.json').read_text(encoding='utf-8'))
    patterns = document.get('workspaces')
    if not isinstance(patterns, list) or not all(isinstance(pattern, str) for pattern in patterns):
        raise ValueError('package.json workspaces must be a string array')
    members: set[str] = set()
    for pattern in patterns:
        if not pattern or pattern.startswith('/') or '..' in Path(pattern).parts:
            raise ValueError(f'unsafe Bun workspace pattern: {pattern!r}')
        for candidate in root.glob(pattern):
            if candidate.is_dir() and (candidate / 'package.json').is_file():
                members.add(candidate.relative_to(root).as_posix())
    return sorted(members)


def _require_exact_members(
    result: Validation,
    *,
    label: str,
    expected: list[str],
    actual: list[str],
) -> None:
    result.require(
        len(actual) == len(set(actual)),
        f'{label} contains duplicate members',
    )
    expected_set = set(expected)
    actual_set = set(actual)
    result.require(
        actual_set == expected_set,
        f'{label} differs from final-tree: missing={sorted(expected_set - actual_set)}, '
        f'unexpected={sorted(actual_set - expected_set)}',
    )


def validate(root: Path, result: Validation) -> None:
    tree=load_yaml(root/'specs/repository/final-tree.yaml'); services=load_yaml(root/'specs/architecture/service-boundaries.yaml')
    compose=load_yaml(root/'specs/deployment/compose-reference.yaml'); config=load_yaml(root/'specs/config/secret-and-key-catalog.yaml'); egress=load_yaml(root/'specs/deployment/egress-allowlist.yaml')
    layout=load_yaml(root/'specs/architecture/monorepo-layout.yaml'); images=load_yaml(root/'specs/deployment/docker-image-contracts.yaml')
    containers=load_yaml(root/'specs/architecture/container-matrix.yaml'); topology=load_yaml(root/'specs/deployment/production-topology.yaml')
    cargo=tree['cargo_workspace']['members']; bun=tree['bun_workspace']['workspaces']; service_ids={s['id'] for s in services['services']}
    result.require(len(cargo)==34,f'expected 34 Cargo members, found {len(cargo)}'); result.require(len(bun)==9,f'expected 9 Bun workspaces, found {len(bun)}')
    result.require(len(compose['services'])==22,f'expected 22 Compose services, found {len(compose["services"])}')
    result.require(len(service_ids)==18,f'expected 18 runnable service boundaries, found {len(service_ids)}')
    _require_exact_members(result, label='monorepo layout Cargo members', expected=list(cargo), actual=layout['cargo_members'])
    _require_exact_members(result, label='monorepo layout Bun workspaces', expected=list(bun), actual=layout['bun_workspaces'])
    try:
        actual_cargo = _cargo_workspace_members(root)
    except (OSError, ValueError, tomllib.TOMLDecodeError) as error:
        result.error(f'cannot read actual Cargo workspace: {error}')
        actual_cargo = []
    try:
        actual_bun = _bun_workspace_members(root)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        result.error(f'cannot read actual Bun workspace: {error}')
        actual_bun = []
    actual_compose = load_yaml(root/'compose.yaml').get('services', {})
    _require_exact_members(result, label='Cargo.toml workspace.members', expected=cargo, actual=actual_cargo)
    _require_exact_members(result, label='expanded package.json workspaces', expected=bun, actual=actual_bun)
    _require_exact_members(
        result,
        label='compose.yaml services',
        expected=list(compose['services']),
        actual=list(actual_compose),
    )
    _require_exact_members(result, label='production topology services', expected=list(actual_compose), actual=topology['services'])
    split={'ingest-worker','analysis-worker','projection-worker','notification-worker','workflow-worker'}
    result.require(split<=set(compose['services']) and split<=service_ids,'split worker services incomplete')
    result.require('worker' not in compose['services'] and 'WORKER_DATABASE_URL' not in {e['name'] for e in config['entries']},'monolithic worker is forbidden')
    result.require('egress-gateway' in compose['services'] and 'egress-gateway' in service_ids,'egress gateway missing')
    result.require(compose['networks']['internal'].get('internal') is True,'internal network must deny direct external routing')
    billing_container=containers['compose_services'].get('billing-gateway',{})
    result.require(billing_container.get('public_port_default') is False and billing_container.get('depends_on',{}).get('migrator')=='service_completed_successfully','billing-gateway container dependency/port boundary differs')
    finance_integrations=topology.get('external_finance_integrations',{})
    result.require(str(finance_integrations.get('payment_gateway','')).startswith('DISABLED') and str(finance_integrations.get('tax_invoice_asp','')).startswith('DISABLED'),'live payment gateway and tax-invoice ASP must remain disabled')
    hardening = {
        'init': True,
        'security_opt': ['no-new-privileges:true'],
        'cap_drop': ['ALL'],
        'pids_limit': 256,
    }
    hardened_services = set(actual_compose) - {'postgres', 'clamav', 'otel-collector'}
    for service in sorted(hardened_services):
        service_config = actual_compose[service]
        for key, expected in hardening.items():
            result.require(service_config.get(key) == expected, f'{service}: runtime isolation {key} differs')
    role_actual=actual_compose.get('role-provisioner',{})
    role_reference=compose['services'].get('role-provisioner',{})
    role_environment={'ROLE_PROVISIONER_DATABASE_URL','ROLE_PROVISIONER_EXPECTED_ACTOR'}
    role_entrypoint=['/bin/bash','/opt/gurine/infra/scripts/provision-r6e-roles.sh']
    role_volumes={
        './db/control-plane:/opt/gurine/db/control-plane:ro',
        './db/migrations/0041_r6e_monetization_runtime.sql:/opt/gurine/db/migrations/0041_r6e_monetization_runtime.sql:ro',
        './infra/scripts/provision-r6e-roles.sh:/opt/gurine/infra/scripts/provision-r6e-roles.sh:ro',
    }
    for label, role_config in (('actual',role_actual),('reference',role_reference)):
        result.require(set(role_config.get('environment',{}))==role_environment,f'role-provisioner {label} environment differs')
        result.require(role_config.get('user')=='postgres' and role_config.get('entrypoint')==role_entrypoint and role_config.get('command')==[],f'role-provisioner {label} executable identity differs')
        result.require(role_config.get('depends_on',{}).get('postgres',{}).get('condition')=='service_healthy',f'role-provisioner {label} PostgreSQL readiness dependency differs')
        result.require(role_config.get('networks')==['data'] and not role_config.get('ports'),f'role-provisioner {label} network boundary differs')
        result.require(set(role_config.get('volumes',[]))==role_volumes,f'role-provisioner {label} checksummed input mounts differ')
    result.require('@sha256:' in str(role_actual.get('image','')) and role_reference.get('image')=='postgres:18.4-bookworm','role-provisioner PostgreSQL image pin/reference differs')
    for label, migrator_config in (('actual',actual_compose['migrator']),('reference',compose['services']['migrator'])):
        result.require(migrator_config.get('depends_on',{}).get('role-provisioner',{}).get('condition')=='service_completed_successfully',f'migrator {label} role-provisioner ordering differs')
    result.require(len(egress['channels'])==5,'expected five active egress channels')
    payment_future=egress.get('future_live_payment_provider',{})
    result.require(payment_future.get('status')=='UNCONFIGURED' and payment_future.get('runtime_channel_present') is False,'live payment-provider egress must remain unconfigured in R6e')
    names=[e['name'] for e in config['entries']]; result.require(len(names)==len(set(names)),'duplicate runtime variables')
    result.require(len(names)==config.get('entry_count'),'runtime variable entry_count differs from catalog entries')
    config_by_name={entry['name']:entry for entry in config['entries']}
    role_url=config_by_name.get('ROLE_PROVISIONER_DATABASE_URL',{})
    role_actor=config_by_name.get('ROLE_PROVISIONER_EXPECTED_ACTOR',{})
    result.require(role_url.get('kind')=='secret' and set(role_url.get('services',[]))=={'role-provisioner'},'role-provisioner URL catalog boundary differs')
    result.require(role_actor.get('kind')=='config' and set(role_actor.get('services',[]))=={'role-provisioner'} and 'superuser' in role_actor.get('rule',''),'role-provisioner actor catalog boundary differs')
    required=['INGEST_DATABASE_URL','ANALYSIS_DATABASE_URL','PROJECTOR_DATABASE_URL','NOTIFICATION_DATABASE_URL','WORKFLOW_DATABASE_URL','ECONOMICS_DATABASE_URL','DOCUMENT_EXTRACTOR_DATABASE_URL','BILLING_DATABASE_URL']
    for name in required: result.require(name in names,f'missing split database config {name}')

    service_map=load_yaml(root/'specs/deployment/service-config-map.yaml'); mapped={x['service']:x for x in service_map['services']}; internal_derived={x['name'] for x in service_map.get('internal_derived_variables',[])}
    first_party={'migrator','public-api','control-api','identity-api','submission-api','billing-gateway','ingest-worker','analysis-worker','projection-worker','notification-worker','workflow-worker','document-extractor','scheduler','egress-gateway','oidc-test-provider','public-web','review-console','response-portal'}
    result.require(set(mapped)==first_party,'service config map does not cover every first-party service')
    image_targets=[target for image in images['images'] for target in image.get('targets',[])]
    result.require(len(image_targets)==18 and len(image_targets)==len(set(image_targets)),'expected 18 unique first-party production image targets')
    result.require(set(image_targets)==first_party,'first-party production image targets differ from runnable service set')
    for service in first_party:
        actual=set(compose['services'][service].get('environment',{})); declared=set(mapped[service]['compose_environment']); result.require(actual==declared,f'{service}: Compose environment differs from service config map'); result.require(set(mapped[service]['required_variables'])|set(mapped[service]['conditional_variables'])<=actual,f'{service}: scoped runtime variable not forwarded')
    expected_volumes={'submission-api':'gurine-objects:/var/lib/gurine-objects','ingest-worker':'gurine-objects:/var/lib/gurine-objects','workflow-worker':'gurine-objects:/var/lib/gurine-objects','document-extractor':'gurine-objects:/var/lib/gurine-objects','egress-gateway':'gurine-objects:/var/lib/gurine-objects','notification-worker':'gurine-mail:/var/lib/gurine-mail'}
    for service,volume in expected_volumes.items(): result.require(volume in compose['services'][service].get('volumes',[]),f'{service}: development adapter volume missing')
    env_values=dict(line.split('=',1) for line in (root/'.env.example').read_text(encoding='utf-8').splitlines() if line and not line.startswith('#') and '=' in line); prod_env_values=dict(line.split('=',1) for line in (root/'.env.production.example').read_text(encoding='utf-8').splitlines() if line and not line.startswith('#') and '=' in line); result.require(set(names)==set(env_values),'.env.example must define exactly every external cataloged runtime variable'); result.require(set(names)==set(prod_env_values),'.env.production.example must define exactly every external cataloged runtime variable'); all_compose_env={key for cfg in compose['services'].values() for key in (cfg.get('environment') or {})}; result.require(all_compose_env <= set(names)|internal_derived,f'Compose uses uncataloged/non-derived variables: {sorted(all_compose_env-set(names)-internal_derived)}'); result.require(internal_derived=={'DATABASE_URL','EGRESS_ALLOWLIST_PATH'},'internal derived variable catalog differs')

    result.require('identity-api' in compose['services'] and 'identity-api' in service_ids,'private identity service missing')
    result.require('services/identity-api' in tree['cargo_workspace']['members'],'identity-api Cargo member missing')
    result.require('packages/api-client-identity-internal' in tree['bun_workspace']['workspaces'],'internal identity generated client workspace missing')
    review_env=set(compose['services']['review-console'].get('environment',{})); identity_env=set(compose['services']['identity-api'].get('environment',{}))
    result.require('IDENTITY_API_INTERNAL_URL' in review_env,'Review Console does not receive identity API URL')
    result.require(not {'OIDC_CLIENT_SECRET','OIDC_ISSUER_URL','OIDC_EGRESS_URL'} & review_env,'Review Console must not own OIDC provider secrets/egress')
    result.require({'OIDC_CLIENT_ID','OIDC_CLIENT_SECRET','OIDC_ISSUER_URL','OIDC_EGRESS_URL','IDENTITY_DATABASE_URL'} <= identity_env,'identity-api OIDC/runtime configuration incomplete')
    result.require('identity-api' in egress['channels']['oidc']['callers'] and 'review-console' not in egress['channels']['oidc']['callers'],'OIDC egress caller must be identity-api only')
    service_by={item['id']:item for item in services['services']}
    allowed_callers={c for channel in egress['channels'].values() for c in channel['callers']}
    billing_boundary=service_by['billing-gateway']
    billing_actual=actual_compose['billing-gateway']
    billing_reference=compose['services']['billing-gateway']
    billing_expected_env={
        'DATABASE_URL','BILLING_DATABASE_URL','BILLING_GATEWAY_BIND_ADDR','BILLING_GATEWAY_MODE',
        'BILLING_LEASE_SECONDS','BILLING_ONCE','BILLING_POLL_MILLIS','BILLING_WORKER_ID',
        'DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN','DONATION_TEST_PAYMENT_OUTCOME','GURINE_ENV',
        'PAYMENT_FIXTURE_BILLING_HMAC_KEY_CURRENT','PAYMENT_FIXTURE_BILLING_HMAC_KEY_PREVIOUS',
        'PUBLIC_WEB_BILLING_HMAC_KEY_CURRENT','PUBLIC_WEB_BILLING_HMAC_KEY_PREVIOUS',
    } | PAYMENT_FIXTURE_KEYRING_ENV
    result.require(set(billing_actual.get('environment',{}))==billing_expected_env,'billing-gateway actual Compose environment differs from closed R6e ABI')
    result.require(set(billing_reference.get('environment',{}))==billing_expected_env,'billing-gateway reference Compose environment differs from closed R6e ABI')
    result.require(billing_actual.get('networks')==['internal','data'] and not billing_actual.get('ports'),'billing-gateway must have internal+data networks only and no published port')
    result.require(billing_actual.get('environment',{}).get('BILLING_GATEWAY_MODE')=='${BILLING_GATEWAY_MODE:-DISABLED}','billing-gateway must default to DISABLED')
    result.require(env_values.get('BILLING_GATEWAY_MODE')=='DISABLED' and prod_env_values.get('BILLING_GATEWAY_MODE')=='DISABLED','development and production examples must keep billing-gateway DISABLED')
    result.require(billing_boundary.get('db_role')=='gurine_billing_gateway' and billing_boundary.get('database_access',{}).get('direct_table_dml') is False,'billing-gateway database role/direct DML boundary differs')
    result.require(billing_boundary.get('external_egress')==[] and 'billing-gateway' not in allowed_callers,'billing-gateway must have no direct or active mediated provider egress in R6e')
    public_web_actual=actual_compose['public-web']
    result.require({'BILLING_GATEWAY_INTERNAL_URL','PUBLIC_WEB_BILLING_HMAC_KEY_CURRENT','DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN'} <= set(public_web_actual.get('environment',{})),'public-web billing BFF environment is incomplete')
    result.require(public_web_actual.get('depends_on',{}).get('billing-gateway',{}).get('condition')=='service_healthy','public-web must wait for billing-gateway health')
    entry_by={entry['name']:entry for entry in config['entries']}
    result.require(set(entry_by['PUBLIC_WEB_BILLING_HMAC_KEY_CURRENT']['services'])=={'billing-gateway','public-web'},'current billing assertion key ownership differs')
    result.require(set(entry_by['PUBLIC_WEB_BILLING_HMAC_KEY_PREVIOUS']['services'])=={'billing-gateway'},'previous billing assertion key must remain verifier-only')
    result.require(set(entry_by['DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN']['services'])=={'billing-gateway','public-web'},'test payment token ownership differs')
    payment_outcome=entry_by['DONATION_TEST_PAYMENT_OUTCOME']
    result.require(set(payment_outcome['services'])=={'billing-gateway'} and set(payment_outcome.get('allowed',[]))=={'PENDING','SUCCEEDED','FAILED','CANCELED'},'test payment outcome ownership or enum differs')
    result.require(payment_outcome.get('required_when')=='BILLING_GATEWAY_MODE=TEST_ONLY' and payment_outcome.get('forbidden_when')=='GURINE_ENV is not test or BILLING_GATEWAY_MODE is not TEST_ONLY','test payment outcome activation boundary differs')
    result.require(billing_actual.get('environment',{}).get('DONATION_TEST_PAYMENT_OUTCOME')=='${DONATION_TEST_PAYMENT_OUTCOME:-}' and billing_reference.get('environment',{}).get('DONATION_TEST_PAYMENT_OUTCOME')=='${DONATION_TEST_PAYMENT_OUTCOME:-}','test payment outcome must be explicitly configured with no default')
    result.require('DONATION_TEST_PAYMENT_OUTCOME' not in public_web_actual.get('environment',{}),'public-web must not receive the fixture payment outcome')
    result.require(set(entry_by['PAYMENT_FIXTURE_BILLING_HMAC_KEY_CURRENT']['services'])=={'billing-gateway'} and set(entry_by['PAYMENT_FIXTURE_BILLING_HMAC_KEY_PREVIOUS']['services'])=={'billing-gateway'},'fixture webhook assertion keys must be billing-gateway-only')
    fixture_keys=[entry_by['PAYMENT_FIXTURE_BILLING_HMAC_KEY_CURRENT'],entry_by['PAYMENT_FIXTURE_BILLING_HMAC_KEY_PREVIOUS']]
    result.require(all('GURINE_ENV is not test' in key.get('forbidden_when','') for key in fixture_keys),'fixture webhook assertion keys must be forbidden outside test')
    payment_keyrings=billing_boundary.get('test_only_keyrings',{})
    keyring_boundary_names={payment_keyrings.get(keyring,{}).get(slot) for keyring in ('identity_hmac','billing_key_vault_hmac') for slot in ('current','current_version','previous','previous_version')}
    result.require(keyring_boundary_names==PAYMENT_FIXTURE_KEYRING_ENV,'billing-gateway keyring environment ABI differs from PAYMENT-TEST-V1')
    for name in PAYMENT_FIXTURE_KEYRING_ENV:
        entry=entry_by.get(name,{})
        is_version=name.endswith('_VERSION')
        result.require(set(entry.get('services',[]))=={'billing-gateway'} and entry.get('authority_ref')=='PAYMENT-TEST-V1','payment fixture keyring ownership or authority differs')
        result.require(entry.get('kind')==('config' if is_version else 'secret') and entry.get('secret')==(not is_version),f'{name}: key/version secrecy contract differs')
        result.require(entry.get('forbidden_when')=='GURINE_ENV is not test or BILLING_GATEWAY_MODE is not TEST_ONLY',f'{name}: TEST_ONLY activation boundary differs')
        result.require(billing_actual.get('environment',{}).get(name)==f'${{{name}:-}}' and billing_reference.get('environment',{}).get(name)==f'${{{name}:-}}',f'{name}: Compose must forward the exact TEST_ONLY variable without a default')
    fixture_only_names=PAYMENT_FIXTURE_KEYRING_ENV|{'PAYMENT_FIXTURE_BILLING_HMAC_KEY_CURRENT','PAYMENT_FIXTURE_BILLING_HMAC_KEY_PREVIOUS'}
    result.require(all(env_values.get(name)=='' and prod_env_values.get(name)=='' for name in fixture_only_names),'fixture payment material must be blank in development and production examples')
    result.require(not PAYMENT_FIXTURE_KEYRING_ENV & set(public_web_actual.get('environment',{})),'payment identity and billing-key-vault material must remain billing-gateway-only')
    economics_database=entry_by['ECONOMICS_DATABASE_URL']
    economics_preflight=economics_database.get('production_preflight',{})
    workflow_actual_env=set(actual_compose['workflow-worker'].get('environment',{}))
    workflow_reference_env=set(compose['services']['workflow-worker'].get('environment',{}))
    result.require(set(economics_database['services'])=={'workflow-worker'} and economics_database.get('database_role')=='gurine_economics_importer','economics database credential ownership/role differs')
    result.require(economics_preflight.get('when_configured_username')=='gurine_economics_importer' and economics_preflight.get('activation_effect')=='NONE','economics database production preflight boundary differs')
    result.require('ECONOMICS_DATABASE_URL' in workflow_actual_env and 'ECONOMICS_DATABASE_URL' in workflow_reference_env,'workflow-worker economics database credential is not forwarded')
    result.require('ECONOMICS_DATABASE_URL' not in billing_actual.get('environment',{}) and 'ECONOMICS_DATABASE_URL' not in billing_reference.get('environment',{}),'billing-gateway must never receive the economics importer credential')
    live_finance_markers=('PAYMENT_MERCHANT','PAYMENT_WEBHOOK','PROVIDER_MERCHANT','PROVIDER_WEBHOOK','PAYMENT_PROVIDER','EGRESS_PAYMENT','TOSS_PAYMENTS','KAKAO_PAY','STRIPE_','TAX_INVOICE_ASP','ASP_API','ASP_HOST')
    result.require(not any(marker in name for name in names for marker in live_finance_markers),'live payment-provider or tax-invoice ASP config is forbidden in R6e')
    control_auth=service_by['control-api'].get('authentication',{})
    identity_auth=service_by['identity-api'].get('authentication',{})
    result.require(control_auth.get('accepted_credential')=='X-Gurine-Actor-Assertion only','Control API actor assertion boundary differs')
    result.require(control_auth.get('browser_cookie_access') is False,'Control API must never receive browser cookies')
    result.require(identity_auth.get('accepted_credential')=='X-Gurine-Service-Assertion only on private routes','Identity API service assertion boundary differs')
    result.require(control_auth.get('replay_guard')=='ops.assertion_replay_guard via ops.consume_assertion_jti','Control API replay guard differs')
    result.require(identity_auth.get('replay_guard')=='ops.assertion_replay_guard via ops.consume_assertion_jti','Identity API replay guard differs')
    for service in services['services']:
        if service.get('egress_via'): result.require(service['id'] in allowed_callers,f"{service['id']}: egress caller not allowed")
        if service.get('external_egress'): result.require(service['id']=='egress-gateway' or not service['external_egress'],f"{service['id']}: direct external egress forbidden")

    identity_spec=load_yaml(root/'specs/api/identity-service-internal.openapi.yaml')
    identity_ops={node['operationId'] for item in identity_spec['paths'].values() for node in item.values() if isinstance(node,dict) and node.get('operationId')}
    result.require({'issueActorAssertion','closeStepUpAuthorization'} <= identity_ops,'private identity request-bound assertion operations are incomplete')
    oidc=load_yaml(root/'specs/config/oidc-contract.yaml')
    step_cookie=oidc['cookies']['step_up_authorization']
    result.require(step_cookie['name']=='gurine_step_up_authorization' and step_cookie['maximum_actor_assertion_issues']==3,'bounded step-up authorization cookie contract differs')
    result.require('step-up-transaction-envelope.yaml' in oidc['cookies']['step_up_transaction']['cryptography_contract'],'encrypted step-up transaction cookie contract missing')
    start_op=next(o for o in load_yaml(root/'specs/api/operation-contracts.yaml')['operations'] if o['operation_id']=='startStepUpAuthentication')
    result.require({f['name'] for f in start_op['request_fields']}=={'returnTo','actionDescriptor','csrfToken'},'step-up start must accept typed action descriptor and no caller-supplied digest')
    control_ops=[o for o in load_yaml(root/'specs/api/operation-contracts.yaml')['operations'] if o['api']=='control-api']
    result.require(all('reauthProof' not in {f['name'] for f in o.get('request_fields',[])} for o in control_ops),'Control API must not receive raw step-up proof')
    migrations='\n'.join(x.read_text(encoding='utf-8') for x in sorted((root/'specs/database/migrations').glob('*.sql')))
    result.require('TO gurine_identity_api' in migrations and 'ops.claim_step_up_authorization' in migrations,'Identity API step-up authorization grant missing')
    result.require('GRANT EXECUTE ON FUNCTION ops.claim_step_up_authorization' in migrations and 'TO gurine_control_api' not in migrations[migrations.rfind('GRANT EXECUTE ON FUNCTION ops.claim_step_up_authorization'):migrations.rfind('GRANT EXECUTE ON FUNCTION ops.claim_step_up_authorization')+300],'Control API must not claim raw step-up authorization')
    result.stats.update({'cargo_members':len(actual_cargo),'bun_workspaces':len(actual_bun),'compose_services':len(actual_compose),'runtime_variables':len(names),'egress_channels':len(egress['channels']),'service_boundaries':len(service_ids),'first_party_images':len(image_targets)})
