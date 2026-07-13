#!/usr/bin/env python3
import json
import os
import urllib.error
import urllib.parse
import urllib.request

from jsonschema import Draft202012Validator, RefResolver

BASE = os.environ["PUBLIC_TEST_BASE_URL"].rstrip("/")
SPEC = json.load(open("specs/api/public-api.openapi.json", encoding="utf-8"))

AGENCY = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
SUPPLIER = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
CONTRACT = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
CORRECTION = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"

ENDPOINTS = {
    "downloadCaseReproducibility": "/v1/cases/integration-case/reproducibility/download?format=json",
    "downloadContracts": "/v1/contracts/download?format=json",
    "downloadPublicOpenApi": "/v1/openapi.json",
    "getAboutContent": "/v1/content/about",
    "getAccessibilityStatement": "/v1/content/accessibility",
    "getAgency": f"/v1/agencies/{AGENCY}",
    "getCaseReproducibility": "/v1/cases/integration-case/reproducibility",
    "getContactContent": "/v1/content/contact",
    "getContract": f"/v1/contracts/{CONTRACT}",
    "getCorrection": f"/v1/corrections/{CORRECTION}",
    "getCoverage": "/v1/coverage",
    "getEditorialPolicy": "/v1/content/editorial-policy",
    "getFundingContent": "/v1/content/funding",
    "getGovernanceContent": "/v1/content/governance",
    "getMethodologyOverview": "/v1/content/methodology",
    "getPrivacyPolicy": "/v1/content/privacy",
    "getPublicApiDocumentation": "/v1/content/api",
    "getPublicCase": "/v1/cases/integration-case",
    "getPublicCaseRevision": "/v1/cases/integration-case/revisions/1",
    "getPublicSystemStatus": "/v1/system/status",
    "getRule": "/v1/rules/unit-price-ratio",
    "getSource": "/v1/sources/koneps",
    "getSupplier": f"/v1/suppliers/{SUPPLIER}",
    "getTerms": "/v1/content/terms",
    "listAgencies": "/v1/agencies?q=통합&limit=1",
    "listAgencyCases": f"/v1/agencies/{AGENCY}/cases?limit=1",
    "listAgencyContracts": f"/v1/agencies/{AGENCY}/contracts?limit=1",
    "listCaseRevisions": "/v1/cases/integration-case/revisions?limit=1",
    "listContractChanges": f"/v1/contracts/{CONTRACT}/changes?limit=1",
    "listContracts": "/v1/contracts?q=통합&limit=1",
    "listCorrections": "/v1/corrections?limit=1",
    "listPublicCases": "/v1/cases?publicationState=PUBLISHED_ANOMALY&limit=1",
    "listPublicDatasets": "/v1/datasets?format=JSONL&limit=1",
    "listRuleCases": "/v1/rules/unit-price-ratio/cases?limit=1",
    "listRules": "/v1/rules?limit=1",
    "listSourceStatus": "/v1/sources/status?status=CURRENT&limit=1",
    "listSupplierCases": f"/v1/suppliers/{SUPPLIER}/cases?limit=1",
    "listSupplierContracts": f"/v1/suppliers/{SUPPLIER}/contracts?limit=1",
    "listSuppliers": "/v1/suppliers?q=통합&limit=1",
    "listTransparencyReports": "/v1/transparency-reports?limit=1",
    "searchPublicRecords": "/v1/search?q=통합&limit=10",
}


def operation_map():
    result = {}
    for path, path_item in SPEC["paths"].items():
        operation = path_item.get("get")
        if operation:
            result[operation["operationId"]] = operation
    return result


operations = operation_map()
assert set(ENDPOINTS) == set(operations), (set(ENDPOINTS) - set(operations), set(operations) - set(ENDPOINTS))
resolver = RefResolver.from_schema(SPEC)

for operation_id, path in ENDPOINTS.items():
    encoded_path = urllib.parse.quote(path, safe="/:?=&,%")
    request = urllib.request.Request(BASE + encoded_path, headers={"X-Request-ID": "12345678-1234-4234-8234-123456789012"})
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            assert response.status == 200, (operation_id, response.status)
            assert response.headers["X-Content-Type-Options"] == "nosniff"
            body = json.load(response)
    except urllib.error.HTTPError as error:
        raise AssertionError((operation_id, path, error.code, error.read().decode())) from error
    if operation_id == "downloadPublicOpenApi":
        assert body["openapi"] == "3.1.0"
        assert len(body["paths"]) == 41
        continue
    schema = operations[operation_id]["responses"]["200"]["content"]["application/json"]["schema"]
    Draft202012Validator(schema, resolver=resolver).validate(body)
    if operation_id.startswith("list") or operation_id == "searchPublicRecords":
        assert body["items"], f"{operation_id} returned an empty fixture-backed projection"

for missing in [
    "/v1/cases/not-published",
    f"/v1/contracts/11111111-1111-4111-8111-111111111111",
    "/v1/rules/not-found",
]:
    try:
        urllib.request.urlopen(BASE + missing, timeout=10)
        raise AssertionError(f"{missing} should be 404")
    except urllib.error.HTTPError as error:
        assert error.code == 404, (missing, error.code)

print("public API 41-operation PostgreSQL projection/OpenAPI integration: PASS")
