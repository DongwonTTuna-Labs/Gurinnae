from __future__ import annotations
from pathlib import Path
from .loaders import load_yaml
from .models import Validation

def validate(root: Path, result: Validation) -> None:
    tree=load_yaml(root/'specs/repository/final-tree.yaml'); services=load_yaml(root/'specs/architecture/service-boundaries.yaml')
    compose=load_yaml(root/'specs/deployment/compose-reference.yaml'); config=load_yaml(root/'specs/config/secret-and-key-catalog.yaml'); egress=load_yaml(root/'specs/deployment/egress-allowlist.yaml')
    cargo=tree['cargo_workspace']['members']; bun=tree['bun_workspace']['workspaces']; service_ids={s['id'] for s in services['services']}
    result.require(len(cargo)==32,f'expected 32 Cargo members, found {len(cargo)}'); result.require(len(bun)==9,f'expected 9 Bun workspaces, found {len(bun)}')
    result.require(len(compose['services'])==20,f'expected 20 Compose services, found {len(compose["services"])}')
    split={'ingest-worker','analysis-worker','projection-worker','notification-worker','workflow-worker'}
    result.require(split<=set(compose['services']) and split<=service_ids,'split worker services incomplete')
    result.require('worker' not in compose['services'] and 'WORKER_DATABASE_URL' not in {e['name'] for e in config['entries']},'monolithic worker is forbidden')
    result.require('egress-gateway' in compose['services'] and 'egress-gateway' in service_ids,'egress gateway missing')
    result.require(compose['networks']['internal'].get('internal') is True,'internal network must deny direct external routing')
    result.require(len(egress['channels'])==5,'expected five egress channels')
    names=[e['name'] for e in config['entries']]; result.require(len(names)==len(set(names)),'duplicate runtime variables')
    required=['INGEST_DATABASE_URL','ANALYSIS_DATABASE_URL','PROJECTOR_DATABASE_URL','NOTIFICATION_DATABASE_URL','WORKFLOW_DATABASE_URL','DOCUMENT_EXTRACTOR_DATABASE_URL']
    for name in required: result.require(name in names,f'missing split database config {name}')

    service_map=load_yaml(root/'specs/deployment/service-config-map.yaml'); mapped={x['service']:x for x in service_map['services']}; internal_derived={x['name'] for x in service_map.get('internal_derived_variables',[])}
    first_party={'migrator','public-api','control-api','identity-api','submission-api','ingest-worker','analysis-worker','projection-worker','notification-worker','workflow-worker','document-extractor','scheduler','egress-gateway','oidc-test-provider','public-web','review-console','response-portal'}
    result.require(set(mapped)==first_party,'service config map does not cover every first-party service')
    for service in first_party:
        actual=set(compose['services'][service].get('environment',{})); declared=set(mapped[service]['compose_environment']); result.require(actual==declared,f'{service}: Compose environment differs from service config map'); result.require(set(mapped[service]['required_variables'])|set(mapped[service]['conditional_variables'])<=actual,f'{service}: scoped runtime variable not forwarded')
    expected_volumes={'submission-api':'gurine-objects:/var/lib/gurine-objects','ingest-worker':'gurine-objects:/var/lib/gurine-objects','workflow-worker':'gurine-objects:/var/lib/gurine-objects','document-extractor':'gurine-objects:/var/lib/gurine-objects','egress-gateway':'gurine-objects:/var/lib/gurine-objects','notification-worker':'gurine-mail:/var/lib/gurine-mail'}
    for service,volume in expected_volumes.items(): result.require(volume in compose['services'][service].get('volumes',[]),f'{service}: development adapter volume missing')
    env_names={line.split('=',1)[0] for line in (root/'.env.example').read_text(encoding='utf-8').splitlines() if line and not line.startswith('#') and '=' in line}; prod_env_names={line.split('=',1)[0] for line in (root/'.env.production.example').read_text(encoding='utf-8').splitlines() if line and not line.startswith('#') and '=' in line}; result.require(set(names)==env_names,'.env.example must define exactly every external cataloged runtime variable'); result.require(set(names)==prod_env_names,'.env.production.example must define exactly every external cataloged runtime variable'); all_compose_env={key for cfg in compose['services'].values() for key in (cfg.get('environment') or {})}; result.require(all_compose_env <= set(names)|internal_derived,f'Compose uses uncataloged/non-derived variables: {sorted(all_compose_env-set(names)-internal_derived)}'); result.require(internal_derived=={'DATABASE_URL','EGRESS_ALLOWLIST_PATH'},'internal derived variable catalog differs')

    result.require('identity-api' in compose['services'] and 'identity-api' in service_ids,'private identity service missing')
    result.require('services/identity-api' in tree['cargo_workspace']['members'],'identity-api Cargo member missing')
    result.require('packages/api-client-identity-internal' in tree['bun_workspace']['workspaces'],'internal identity generated client workspace missing')
    review_env=set(compose['services']['review-console'].get('environment',{})); identity_env=set(compose['services']['identity-api'].get('environment',{}))
    result.require('IDENTITY_API_INTERNAL_URL' in review_env,'Review Console does not receive identity API URL')
    result.require(not {'OIDC_CLIENT_SECRET','OIDC_ISSUER_URL','OIDC_EGRESS_URL'} & review_env,'Review Console must not own OIDC provider secrets/egress')
    result.require({'OIDC_CLIENT_ID','OIDC_CLIENT_SECRET','OIDC_ISSUER_URL','OIDC_EGRESS_URL','IDENTITY_DATABASE_URL'} <= identity_env,'identity-api OIDC/runtime configuration incomplete')
    result.require('identity-api' in egress['channels']['oidc']['callers'] and 'review-console' not in egress['channels']['oidc']['callers'],'OIDC egress caller must be identity-api only')
    service_by={item['id']:item for item in services['services']}
    control_auth=service_by['control-api'].get('authentication',{})
    identity_auth=service_by['identity-api'].get('authentication',{})
    result.require(control_auth.get('accepted_credential')=='X-Gurine-Actor-Assertion only','Control API actor assertion boundary differs')
    result.require(control_auth.get('browser_cookie_access') is False,'Control API must never receive browser cookies')
    result.require(identity_auth.get('accepted_credential')=='X-Gurine-Service-Assertion only on private routes','Identity API service assertion boundary differs')
    result.require(control_auth.get('replay_guard')=='ops.assertion_replay_guard via ops.consume_assertion_jti','Control API replay guard differs')
    result.require(identity_auth.get('replay_guard')=='ops.assertion_replay_guard via ops.consume_assertion_jti','Identity API replay guard differs')
    allowed_callers={c for channel in egress['channels'].values() for c in channel['callers']}
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
    result.stats.update({'cargo_members':len(cargo),'bun_workspaces':len(bun),'compose_services':len(compose['services']),'runtime_variables':len(names),'egress_channels':len(egress['channels']),'service_boundaries':len(service_ids)})
