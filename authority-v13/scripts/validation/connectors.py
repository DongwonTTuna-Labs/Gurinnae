from __future__ import annotations
from pathlib import Path
from .loaders import load_json, load_yaml
from .models import Validation

REST_ORIGIN='synthetic-structural-not-live-evidence'; MANIFEST_ORIGIN='synthetic-manifest-contract-not-live-evidence'

def validate(root: Path, result: Validation) -> None:
    catalog=load_yaml(root/'specs/connectors/connector-catalog.yaml'); result.require(catalog['status']=='FINAL','connector catalog must be FINAL')
    activation=load_yaml(root/'specs/connectors/activation-responsibility-matrix.yaml')
    activation_by={x['connector_id']:x for x in activation['connectors']}
    result.require(len(catalog['connectors'])==6,'expected 6 connectors'); total=0
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
    result.require(total==catalog['total_operations']==44,f'expected 44 connector operations, found {total}')
    result.stats.update({'connectors':6,'connector_operations':total})
