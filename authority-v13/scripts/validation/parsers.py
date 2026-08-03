from __future__ import annotations
import hashlib,json,subprocess,sys
from pathlib import Path
from jsonschema import Draft202012Validator
from .loaders import load_json,load_yaml
from .models import Validation

EXPECTED_FORMATS={'csv','xml','xlsx','docx','hwpx','pdf-digital','pdf-ocr','hwp-binary'}

def validate(root:Path,result:Validation)->None:
 cat=load_yaml(root/'specs/parsers/parser-catalog.yaml'); sandbox=load_yaml(root/'specs/parsers/sandbox-contract.yaml'); bom=load_yaml(root/'specs/parsers/runtime-bom.yaml'); manifest=load_yaml(root/'specs/parsers/fixture-manifest.yaml')
 result.require(cat['status']=='FINAL' and cat['specification_version']=='13.0.0','parser catalog mismatch')
 result.require({x['id'] for x in cat['formats']}==EXPECTED_FORMATS,'parser format set differs')
 policy=cat['binary_hwp_policy']; result.require(policy['mode']=='QUARANTINE_UNSUPPORTED' and policy['required_action']=='TRUSTED_OFFLINE_CONVERSION_TO_PDF_OR_HWPX','binary HWP policy missing')
 result.require(sandbox['network']=='none' and sandbox['process']['no_new_privileges'] is True,'parser sandbox not fail-closed')
 required_rejections={'ZIP_PATH_TRAVERSAL','ZIP_BOMB','ZIP_DUPLICATE_ENTRY','ZIP_SYMLINK_ENTRY','OOXML_EXTERNAL_RELATIONSHIP','XML_DTD_OR_ENTITY','BINARY_HWP_UNSUPPORTED_REQUIRES_TRUSTED_CONVERSION','PDF_TRUNCATED_OR_INVALID'}
 result.require(required_rejections<=set(sandbox['rejections']),'parser rejection set incomplete')
 result.require(bom['external_tools']['pdftotext']=='25.06.0' and bom['external_tools']['pdftoppm']=='25.06.0' and bom['external_tools']['tesseract']=='5.5.0','parser tool versions differ')
 schema=load_json(root/'specs/parsers/extraction-result.schema.json'); Draft202012Validator.check_schema(schema); validator=Draft202012Validator(schema)
 expected_dir=root/'specs/parsers'/manifest['golden_output_directory']; golden=0
 for item in manifest['fixtures']:
  p=root/'specs/parsers/fixtures'/item['file']; result.require(p.is_file(),f'parser fixture missing: {item["file"]}'); result.require(hashlib.sha256(p.read_bytes()).hexdigest()==item['sha256'],f'parser fixture digest differs: {item["file"]}')
  ep=expected_dir/item['expectedOutput']; result.require(ep.is_file(),f'parser golden output missing: {item["expectedOutput"]}')
  if ep.is_file():
   value=load_json(ep); errs=list(validator.iter_errors(value)); result.require(not errs,f'{ep.name}: extraction schema invalid: {errs[0].message if errs else ""}'); result.require(value['status']==item['expected'],f'{ep.name}: expected status differs'); golden+=1
 result.require(len(manifest['fixtures'])==15 and golden==15,'parser fixture/golden count differs')
 proc=subprocess.run([sys.executable,'-B',str(root/'specs/parsers/reference_harness.py')],cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 result.require(proc.returncode==0,f'parser extraction harness failed: {proc.stdout[-1500:]}')
 if proc.returncode==0:
  payload=json.loads(proc.stdout); result.require(payload['result']=='PASS' and payload['caseCount']==15 and payload['goldenCount']==15,'parser extraction result differs')
  versions=payload.get('toolVersions',{}); result.require(versions.get('pdftotext')=='25.06.0' and versions.get('pdftoppm')=='25.06.0' and versions.get('tesseract')=='5.5.0','parser runtime tool version drift')
 result.stats.update({'parser_formats':len(cat['formats']),'parser_fixtures':len(manifest['fixtures']),'parser_golden_outputs':golden})
