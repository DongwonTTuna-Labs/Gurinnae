#!/usr/bin/env python3
import base64
import csv
import hashlib
import io
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
EXPORT_NOTICE = "이상 징후 기록이며 위법·부패의 확정이 아님"

ENDPOINTS = {
    "downloadCaseReproducibility": "/v1/cases/integration-case/reproducibility/download?format=JSON",
    "downloadContracts": "/v1/contracts/download?format=JSONL",
    "downloadPublicCases": (
        f"/v1/cases/download?format=JSONL&publicationState=PUBLISHED_ANOMALY&agencyId={AGENCY}"
        f"&sidoCode=11&sigunguCode=11680&supplierId={SUPPLIER}&ruleId=unit-price-ratio"
        "&publishedFrom=2026-07-01&publishedTo=2026-07-31&hasResponse=false"
        "&hasCorrection=true&sort=title_asc"
    ),
    "downloadPublicOpenApi": "/v1/openapi.json",
    "downloadPublicSearchRecords": (
        f"/v1/search/download?format=CSV&q=통합&types=CASE&publicationState=PUBLISHED_ANOMALY"
        f"&agencyId={AGENCY}&sidoCode=11&sigunguCode=11680&dateFrom=2026-01-01"
        "&dateTo=2026-12-31&sort=title_asc"
    ),
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


def assert_download_bytes(body):
    encoded = body["contentBase64"]
    decoded = base64.b64decode(encoded, validate=True)
    assert base64.b64encode(decoded).decode("ascii") == encoded
    assert len(decoded) == body["byteLength"], body
    assert hashlib.sha256(decoded).hexdigest() == body["contentSha256"], body
    assert body["rowCount"] <= 5_000, body["rowCount"]
    return decoded


def assert_public_cases_download(body):
    decoded = assert_download_bytes(body)
    records = [json.loads(line) for line in decoded.decode("utf-8").splitlines()]
    assert body["format"] == "JSONL"
    assert body["filename"] == "public-cases.jsonl"
    assert body["mediaType"] == "application/x-ndjson; charset=utf-8"
    assert records[0] == {"notice": EXPORT_NOTICE}
    assert body["rowCount"] == len(records) - 1 == 1
    assert records[1]["slug"] == "integration-case"
    assert body["appliedFilters"] == {
        "publicationState": ["PUBLISHED_ANOMALY"],
        "agencyId": AGENCY,
        "sidoCode": "11",
        "sigunguCode": "11680",
        "supplierId": SUPPLIER,
        "ruleId": "unit-price-ratio",
        "publishedFrom": "2026-07-01",
        "publishedTo": "2026-07-31",
        "hasResponse": False,
        "hasCorrection": True,
        "sort": "title_asc",
    }


def assert_public_search_download(body):
    decoded = assert_download_bytes(body)
    rows = list(csv.reader(io.StringIO(decoded.decode("utf-8"), newline="")))
    assert body["format"] == "CSV"
    assert body["filename"] == "public-search-records.csv"
    assert body["mediaType"] == "text/csv; charset=utf-8"
    assert rows[0] == [EXPORT_NOTICE]
    assert rows[1] == [
        "resultType",
        "id",
        "title",
        "subtitle",
        "status",
        "summary",
        "updatedAt",
        "href",
    ]
    assert body["rowCount"] == len(rows) - 2 == 1
    assert rows[2][0] == "CASE"
    assert rows[2][3] == "integration-case"
    assert body["appliedFilters"] == {
        "q": "통합",
        "types": ["CASE"],
        "publicationState": ["PUBLISHED_ANOMALY"],
        "agencyId": AGENCY,
        "sidoCode": "11",
        "sigunguCode": "11680",
        "dateFrom": "2026-01-01",
        "dateTo": "2026-12-31",
        "sort": "title_asc",
    }


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
        assert len(body["paths"]) == 43
        continue
    schema = operations[operation_id]["responses"]["200"]["content"]["application/json"]["schema"]
    Draft202012Validator(schema, resolver=resolver).validate(body)
    if operation_id == "downloadPublicCases":
        assert_public_cases_download(body)
    if operation_id == "downloadPublicSearchRecords":
        assert_public_search_download(body)
    if operation_id.startswith("list") or operation_id == "searchPublicRecords":
        assert body["items"], f"{operation_id} returned an empty fixture-backed projection"


def get_json(path):
    request = urllib.request.Request(
        BASE + path,
        headers={"X-Request-ID": "22345678-1234-4234-8234-123456789012"},
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        assert response.status == 200, (path, response.status)
        return json.load(response)


etag_request = urllib.request.Request(
    BASE + "/v1/contracts?limit=10",
    headers={"X-Request-ID": "32345678-1234-4234-8234-123456789012"},
)
with urllib.request.urlopen(etag_request, timeout=10) as response:
    etag = response.headers.get("ETag")
    assert etag and etag.startswith('"') and etag.endswith('"'), etag
conditional = urllib.request.Request(
    BASE + "/v1/contracts?limit=10",
    headers={
        "X-Request-ID": "42345678-1234-4234-8234-123456789012",
        "If-None-Match": etag,
    },
)
try:
    urllib.request.urlopen(conditional, timeout=10)
    raise AssertionError("matching ETag should return 304")
except urllib.error.HTTPError as error:
    assert error.code == 304, error.code
    assert error.headers.get("ETag") == etag


contract_filters = get_json(
    "/v1/contracts?procurementMethod=OPEN_BID&signedFrom=2026-01-01&signedTo=2026-12-31"
    "&amountMin=100000&amountMax=120000&limit=10"
)
assert [item["id"] for item in contract_filters["items"]] == [CONTRACT]
assert get_json("/v1/contracts?procurementMethod=NO_SUCH_METHOD&limit=10")["items"] == []
assert get_json("/v1/contracts?amountMax=100000&limit=10")["items"] == []

case_filters = get_json(
    f"/v1/cases?agencyId={AGENCY}&supplierId={SUPPLIER}&ruleId=unit-price-ratio"
    "&publishedFrom=2026-07-01&publishedTo=2026-07-31"
    "&hasResponse=false&hasCorrection=true&limit=10"
)
assert [item["slug"] for item in case_filters["items"]] == ["integration-case"]
case_detail = get_json("/v1/cases/integration-case")
case_revision = get_json("/v1/cases/integration-case/revisions/1")
for internal_key in ("agencyId", "supplierId", "ruleId", "agencyIds", "supplierIds", "ruleIds"):
    assert internal_key not in case_detail, (internal_key, case_detail)
    assert internal_key not in case_revision["content"], (internal_key, case_revision)
response_only = get_json("/v1/cases?hasResponse=true&hasCorrection=false&limit=10")
assert [item["slug"] for item in response_only["items"]] == ["filter-control-case"]

source_page = get_json("/v1/sources/status?status=CURRENT&limit=1")
assert [item["sourceId"] for item in source_page["items"]] == ["koneps"]
assert "nextCursor" not in source_page

assert [
    item["id"]
    for item in get_json("/v1/contracts?sort=amount_desc&limit=1")["items"]
] == ["c2222222-2222-4222-8222-222222222222"]
assert [
    item["id"]
    for item in get_json("/v1/suppliers?identityStatus=VERIFIED&limit=10")["items"]
] == [SUPPLIER]
assert get_json("/v1/rules?status=RETIRED&limit=10")["items"] == []
assert get_json("/v1/corrections?publishedFrom=2027-01-01&limit=10")["items"] == []
assert get_json("/v1/datasets?format=CSV&limit=10")["items"] == []
search_contracts = get_json(
    "/v1/search?q=%ED%86%B5%ED%95%A9&types=CONTRACT&dateFrom=2026-01-01"
    "&dateTo=2026-12-31&sort=title_asc&limit=10"
)
assert search_contracts["items"]
assert {item["resultType"] for item in search_contracts["items"]} == {"CONTRACT"}
assert get_json("/v1/transparency-reports?periodFrom=2027-01-01&limit=10")["items"] == []

for invalid in [
    "/v1/contracts?agencyId=not-a-uuid",
    "/v1/contracts?amountMin=1e3",
    "/v1/contracts?amountMin=2&amountMax=1",
    "/v1/contracts?sort=updated_desc",
    "/v1/contracts/download?format=json",
    "/v1/cases?publishedFrom=2026-02-30",
    "/v1/cases?hasResponse=yes",
    "/v1/cases?sort=unknown",
    "/v1/search?q=%ED%86%B5%ED%95%A9&dateFrom=2027-01-01&dateTo=2026-01-01",
]:
    try:
        urllib.request.urlopen(BASE + invalid, timeout=10)
        raise AssertionError(f"{invalid} should be 400")
    except urllib.error.HTTPError as error:
        assert error.code == 400, (invalid, error.code)

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

print("public API 43-operation PostgreSQL projection/filter/OpenAPI integration: PASS")
