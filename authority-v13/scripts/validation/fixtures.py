from __future__ import annotations
from pathlib import Path
from jsonschema import Draft202012Validator
from referencing import Registry, Resource
from .loaders import load_json
from .models import Validation

def validate(root: Path, result: Validation) -> None:
    schemas={}; registry=Registry()
    for path in sorted((root/'specs/schemas').glob('*.json')):
        schema=load_json(path); Draft202012Validator.check_schema(schema); schemas[path.name]=schema
        if schema.get('$id'): registry=registry.with_resource(schema['$id'],Resource.from_contents(schema))
    mappings=[('fixtures/raw/*.source-document.json','source-document.schema.json'),('fixtures/normalized/*.contract.json','contract.schema.json'),('fixtures/expected-signals/*.signal.json','anomaly-signal.schema.json'),('fixtures/cases/*.case.json','investigation-case.schema.json'),('fixtures/expected-publications/*.json','publication.schema.json'),('fixtures/expected-events/*.json','event-envelope.schema.json'),('fixtures/responses/*.json','response-submission.schema.json'),('fixtures/reviews/*.editor-approval.json','review-decision.schema.json')]
    valid=0
    for pattern,schema_name in mappings:
        paths=sorted(root.glob(pattern)); result.require(bool(paths),f'no fixtures matched {pattern}'); validator=Draft202012Validator(schemas[schema_name],registry=registry)
        for path in paths:
            errors=list(validator.iter_errors(load_json(path))); result.require(not errors,f'{path.relative_to(root)} invalid: {errors[0].message if errors else ""}'); valid+=not errors
    result.require(valid==75,f'expected 75 schema-valid fixtures, found {valid}')
    result.stats.update({'json_schemas':len(schemas),'schema_valid_fixtures':valid})
