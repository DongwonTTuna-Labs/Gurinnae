from __future__ import annotations
from pathlib import Path
from .loaders import load_json, load_yaml
from .models import Validation

REST_ORIGIN='synthetic-structural-not-live-evidence'; MANIFEST_ORIGIN='synthetic-manifest-contract-not-live-evidence'
EXPECTED_CONNECTORS=8; EXPECTED_OPERATIONS=56

def validate(root: Path, result: Validation) -> None:
    catalog=load_yaml(root/'specs/connectors/connector-catalog.yaml'); result.require(catalog['status']=='FINAL','connector catalog must be FINAL')
    activation=load_yaml(root/'specs/connectors/activation-responsibility-matrix.yaml')
    activation_by={x['connector_id']:x for x in activation['connectors']}
    result.require(len(catalog['connectors'])==EXPECTED_CONNECTORS,f'expected {EXPECTED_CONNECTORS} connectors'); total=0
    for connector in catalog['connectors']:
        directory=root/connector['directory']; operations=load_yaml(directory/'operations.yaml')['operations']; total+=len(operations)
        result.require(len(operations)==connector['operation_count'],f"{connector['id']}: operation count mismatch")
        for name in ['connector.yaml','operations.yaml','field-mapping.yaml','error-policy.yaml']: result.require((directory/name).is_file(),f"{connector['id']}: missing {name}")
        kind=connector['source_kind']; expected=REST_ORIGIN if kind in {'OFFICIAL_REST_API','OFFICIAL_REST_AND_ZIP_XML_API'} else MANIFEST_ORIGIN
        for fixture in sorted((directory/'fixtures').glob('*.json')):
            data=load_json(fixture); result.require(data.get('fixture_origin')==expected,f"{connector['id']}:{fixture.name}: wrong fixture origin")
        result.require(connector.get('activation_mode') in catalog['activation_modes'],f"{connector['id']}: activation mode missing")
        result.require(connector['id'] in activation_by and activation_by[connector['id']]['activation_mode']==connector['activation_mode'],f"{connector['id']}: activation responsibility matrix mismatch")
        result.require(activation_by[connector['id']]['synthetic_fixture_evidence']=='STRUCTURAL_ONLY',f"{connector['id']}: synthetic fixtures cannot be live evidence")
        result.require(bool(connector.get('operator_responsibility')),f"{connector['id']}: operator responsibility missing")
        result.require(bool(connector.get('official_references')),f"{connector['id']}: official references missing")
        contract=load_yaml(directory/'connector.yaml')
        result.require(any(bool(value) for key,value in contract.get('activation',{}).items() if key.startswith('requires_')),f"{connector['id']}: production preflight not required")
        if kind not in {'OFFICIAL_REST_API','OFFICIAL_REST_AND_ZIP_XML_API'}:
            result.require(all(op.get('kind') in {'official-link-entry','official-file-manifest','official-document-index','manifest','document'} for op in operations),f"{connector['id']}: manifest source invents REST transport")
    sanctions=next((connector for connector in catalog['connectors'] if connector['id']=='pps-sanctions'),None)
    result.require(bool(sanctions) and sanctions.get('runtime_default_enabled') is False,'pps-sanctions must be registered disabled')
    result.require(bool(sanctions) and sanctions.get('legal_blocker')=='PPS_SANCTIONS_REUSE_RIGHTS_UNCONFIRMED','pps-sanctions rights blocker missing')
    deferred=load_yaml(root/'specs/connectors/r6c-deferred-sources.yaml')
    result.require({entry['id'] for entry in deferred['deferred_sources']}=={'koneps-structured-bidder-participation','open-dart-affiliates','open-dart-major-holder-identity','alio-officer-normalization'},'R6c deferred connector set must remain exact')
    result.require(all(entry['state']=='BLOCKED' and bool(entry.get('unlock_condition')) for entry in deferred['deferred_sources']),'every deferred connector must name a blocker and unlock condition')
    bid_results=load_yaml(root/'specs/connectors/koneps-bid-results/operations.yaml')['operations']
    result.require({operation['remote_operation'] for operation in bid_results}=={'getOpengResultListInfoThngPPSSrch','getOpengResultListInfoCnstwkPPSSrch','getOpengResultListInfoServcPPSSrch','getOpengResultListInfoFrgcptPPSSrch','getScsbidListSttusThngPPSSrch','getScsbidListSttusCnstwkPPSSrch','getScsbidListSttusServcPPSSrch','getScsbidListSttusFrgcptPPSSrch'},'KONEPS bid-result operation set must remain exact')
    result.require(all('opengCorpInfo' in operation['normalization_boundary'].get('opaque_never_parse',[]) for operation in bid_results if operation['kind']=='opening-metadata'),'opengCorpInfo must remain opaque')
    bid_mapping=load_yaml(root/'specs/connectors/koneps-bid-results/field-mapping.yaml')['persistence_boundary']
    result.require(bid_mapping['canonical_projection_state']=='BLOCKED' and bid_mapping['canonical_domain_output_rows']==0,'KONEPS bid-result canonical projection must remain blocked until mapping activation')
    dart_mapping=load_yaml(root/'specs/connectors/open-dart/field-mapping.yaml')['person_normalization_boundary']
    result.require(set(dart_mapping['stored_fields'])=={'contextual_name','role_title','source_locator','identifier_digest'},'OpenDART person projection must remain minimal')
    result.require({'sexdstn','birth_ym','adres','address','tel','phone','mxmm_shrholdr_relate','relate','family','kinship'} <= set(dart_mapping['forbidden_fields']),'OpenDART person projection must reject demographic, contact and family fields')
    dart_holder=load_yaml(root/'specs/connectors/open-dart/field-mapping.yaml')['major_shareholder_normalization_boundary']
    result.require(dart_holder['entity_type_discriminator']=='unavailable' and dart_holder['graph_output_rows']==0,'OpenDART major-holder rows must not infer PERSON or SUPPLIER endpoints')
    generated_records=[]
    for path in sorted((root/'specs/connectors').glob('*/operations.yaml')):
        document=load_yaml(path)
        generated_records.extend({'connector_id':document['connector_id'],'id':operation['id'],'method':operation['method'],'kind':operation['kind'],'remote_path':operation.get('path',''),'pagination':operation['pagination']['strategy']} for operation in document['operations'])
    generated=load_json(root/'verification/generated-connector-catalog.json')
    result.require(generated==generated_records,'generated connector catalog is stale')
    result.require(total==catalog['total_operations']==EXPECTED_OPERATIONS,f'expected {EXPECTED_OPERATIONS} connector operations, found {total}')
    result.stats.update({'connectors':EXPECTED_CONNECTORS,'connector_operations':total})
