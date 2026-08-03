from __future__ import annotations
import hashlib
from pathlib import Path
from jsonschema import Draft202012Validator
from referencing import Registry, Resource
from .loaders import load_json
from .models import Validation


def _named_person_guard_error(value: dict) -> str | None:
    assessment = value["assessment"]
    findings = assessment["findings"]
    for finding in findings:
        if finding["endUtf16"] <= finding["startUtf16"]:
            return "named-person finding endUtf16 must be greater than startUtf16"
    receipt = value["overrideReceipt"]
    if not findings:
        if receipt is not None or value["legalReviewed"]:
            return "finding-free assessment must not carry an override or legalReviewed=true"
        return None
    if receipt is None:
        return None
    if not value["legalReviewed"]:
        return "named-person override receipt requires legalReviewed=true"
    if receipt["publicTextSha256"] != assessment["publicTextSha256"]:
        return "override receipt publicTextSha256 does not bind the assessment"
    if receipt["rulesetVersion"] != assessment["rulesetVersion"]:
        return "override receipt rulesetVersion does not bind the assessment"
    legal_reviewer = receipt["legalReviewerId"]
    if legal_reviewer != value["currentLegalActorId"]:
        return "override legalReviewerId must be the current submitReview actor"
    editorial_decision = value["editorialReviewDecision"]
    if receipt["editorialReviewDecisionId"] != editorial_decision["id"]:
        return "override editorialReviewDecisionId does not bind the referenced decision"
    if editorial_decision["reviewerId"] in {
        value["snapshotAuthorId"],
        value["currentLegalActorId"],
    }:
        return "referenced APPROVE reviewer must differ from snapshot author and current legal actor"
    hasher = hashlib.sha256()
    for part in [
        receipt["receiptVersion"],
        receipt["publicTextSha256"],
        receipt["rulesetVersion"],
        receipt["reasonCode"],
        receipt["officialSourceLocator"],
        receipt["officialSourceSha256"],
        receipt["editorialReviewDecisionId"],
        legal_reviewer,
    ]:
        encoded = part.encode("utf-8")
        hasher.update(len(encoded).to_bytes(8, "big"))
        hasher.update(encoded)
    if hasher.hexdigest() != receipt["receiptSha256"]:
        return "override receiptSha256 does not match the canonical preimage"
    return None

def validate(root: Path, result: Validation) -> None:
    schemas={}; registry=Registry()
    for path in sorted((root/'specs/schemas').glob('*.json')):
        schema=load_json(path); Draft202012Validator.check_schema(schema); schemas[path.name]=schema
        if schema.get('$id'): registry=registry.with_resource(schema['$id'],Resource.from_contents(schema))
    mappings=[('fixtures/raw/*.source-document.json','source-document.schema.json'),('fixtures/normalized/*.contract.json','contract.schema.json'),('fixtures/expected-signals/*.signal.json','anomaly-signal.schema.json'),('fixtures/cases/*.case.json','investigation-case.schema.json'),('fixtures/expected-publications/*.json','publication.schema.json'),('fixtures/publication-guards/*.json','named-individual-publication-guard.schema.json'),('fixtures/expected-events/*.json','event-envelope.schema.json'),('fixtures/responses/*.json','response-submission.schema.json'),('fixtures/reviews/*.editor-approval.json','review-decision.schema.json')]
    valid=0
    for pattern,schema_name in mappings:
        paths=sorted(root.glob(pattern)); result.require(bool(paths),f'no fixtures matched {pattern}'); validator=Draft202012Validator(schemas[schema_name],registry=registry)
        for path in paths:
            value=load_json(path); errors=list(validator.iter_errors(value)); message=errors[0].message if errors else ''
            if not errors and schema_name=='named-individual-publication-guard.schema.json':
                message=_named_person_guard_error(value) or ''
                if message: errors=[message]
            result.require(not errors,f'{path.relative_to(root)} invalid: {message}'); valid+=not errors
    result.require(valid==77,f'expected 77 schema-valid fixtures, found {valid}')
    result.stats.update({'json_schemas':len(schemas),'schema_valid_fixtures':valid})
