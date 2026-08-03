import { Buffer } from "node:buffer";
import { createHash } from "node:crypto";
import {
  FIXTURE_AS_OF,
  publicAgencyRows,
  publicCasePublishedAtBySlug,
  publicCaseRows,
  publicContractRows,
  publicSearchRows,
  publicSupplierRows,
} from "./mock-api-public-ledger-fixtures";
import { OPERATIONAL_INTERPRETATION_NOTICE } from "./mock-api-public-notices";
import { problem } from "./mock-api-state";

type JsonObject = Record<string, unknown>;
type ExportFormat = "CSV" | "JSONL";
type ExportColumn = readonly [key: string, heading: string];

const EXPORT_NOTICE = "이상 징후 기록이며 위법·부패의 확정이 아님";
const TEST_SIDO_CODE = "11";
const TEST_SIGUNGU_CODE = "11680";
const TEST_REGION_CODE_VERSION = "행정표준코드-2026.1";
const TEST_RULE_ID = "contract-unit-price-comparison";

const CASE_EXPORT_COLUMNS: readonly ExportColumn[] = [
  ["slug", "slug"],
  ["title", "title"],
  ["publicState", "publicState"],
  ["summary", "summary"],
  ["revision", "revision"],
  ["updatedAt", "updatedAt"],
  ["responseStatus", "responseStatus"],
  ["correctionStatus", "correctionStatus"],
  ["nonConclusion", "nonConclusion"],
  ["href", "href"],
];

const SEARCH_EXPORT_COLUMNS: readonly ExportColumn[] = [
  ["resultType", "resultType"],
  ["id", "id"],
  ["title", "title"],
  ["subtitle", "subtitle"],
  ["status", "status"],
  ["summary", "summary"],
  ["nonConclusion", "nonConclusion"],
  ["interpretationNotice", "interpretationNotice"],
  ["updatedAt", "updatedAt"],
  ["href", "href"],
];

const CONTRACT_EXPORT_COLUMNS: readonly ExportColumn[] = [
  ["id", "id"],
  ["contractNumber", "contractNumber"],
  ["title", "title"],
  ["agencyName", "agencyName"],
  ["supplierName", "supplierName"],
  ["status", "status"],
  ["signedAt", "signedAt"],
  ["amount", "amount"],
  ["currency", "currency"],
  ["interpretationNotice", "interpretationNotice"],
];

function jsonObject(value: unknown): JsonObject | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? Object.fromEntries(Object.entries(value))
    : undefined;
}

function values(url: URL, name: string) {
  return url.searchParams.getAll(name).filter(Boolean);
}

function optionalFilter(
  filters: JsonObject,
  url: URL,
  name: string,
  parse: (value: string) => unknown = (value) => value,
) {
  const value = url.searchParams.get(name);
  if (value !== null) filters[name] = parse(value);
}

function caseAppliedFilters(url: URL): JsonObject {
  const filters: JsonObject = {
    publicationState: values(url, "publicationState"),
    sort: url.searchParams.get("sort") ?? "updated_desc",
  };
  for (const name of [
    "agencyId",
    "sidoCode",
    "sigunguCode",
    "supplierId",
    "ruleId",
    "publishedFrom",
    "publishedTo",
  ])
    optionalFilter(filters, url, name);
  for (const name of ["hasResponse", "hasCorrection"])
    optionalFilter(filters, url, name, (value) => value === "true");
  return filters;
}

function searchAppliedFilters(url: URL): JsonObject {
  const filters: JsonObject = {
    q: url.searchParams.get("q")?.trim() ?? "",
    types: values(url, "types").map((value) => value.toUpperCase()),
    publicationState: values(url, "publicationState"),
    sort: url.searchParams.get("sort") ?? "relevance",
  };
  for (const name of [
    "agencyId",
    "sidoCode",
    "sigunguCode",
    "dateFrom",
    "dateTo",
  ])
    optionalFilter(filters, url, name);
  return filters;
}

function contractAppliedFilters(url: URL): JsonObject {
  const filters: JsonObject = {};
  optionalFilter(filters, url, "q");
  for (const name of [
    "agencyId",
    "supplierId",
    "signedFrom",
    "signedTo",
    "amountMin",
    "amountMax",
  ])
    optionalFilter(filters, url, name);
  for (const name of ["contractStatus", "procurementMethod"]) {
    const selected = values(url, name);
    if (selected.length > 0) filters[name] = selected;
  }
  return filters;
}

function matchesValue(url: URL, name: string, actual: string) {
  const expected = url.searchParams.get(name);
  return expected === null || expected === actual;
}

function matchesDateRange(
  value: string,
  url: URL,
  fromName: string,
  toName: string,
) {
  const date = value.slice(0, 10);
  const from = url.searchParams.get(fromName);
  const to = url.searchParams.get(toName);
  return (!from || date >= from) && (!to || date <= to);
}

function casePublishedAt(row: (typeof publicCaseRows)[number]) {
  const publishedAt = publicCasePublishedAtBySlug[row.slug];
  if (!publishedAt)
    throw new Error(`public case ${row.slug} has no publication fixture`);
  return publishedAt;
}

function caseMatches(
  row: (typeof publicCaseRows)[number],
  index: number,
  url: URL,
) {
  const states = values(url, "publicationState");
  const responseExpected = url.searchParams.get("hasResponse");
  const correctionExpected = url.searchParams.get("hasCorrection");
  const hasResponse = row.responseStatus === "RECEIVED";
  const hasCorrection = row.correctionStatus !== null;
  return (
    (states.length === 0 || states.includes(row.publicState)) &&
    matchesValue(url, "agencyId", publicAgencyRows[index]?.id ?? "") &&
    matchesValue(url, "supplierId", publicSupplierRows[index]?.id ?? "") &&
    matchesValue(url, "ruleId", TEST_RULE_ID) &&
    matchesValue(url, "sidoCode", TEST_SIDO_CODE) &&
    matchesValue(url, "sigunguCode", TEST_SIGUNGU_CODE) &&
    matchesDateRange(
      casePublishedAt(row),
      url,
      "publishedFrom",
      "publishedTo",
    ) &&
    (responseExpected === null || responseExpected === String(hasResponse)) &&
    (correctionExpected === null ||
      correctionExpected === String(hasCorrection))
  );
}

function caseRows(url: URL) {
  const rows = publicCaseRows.filter((row, index) =>
    caseMatches(row, index, url),
  );
  const sort = url.searchParams.get("sort") ?? "updated_desc";
  return rows.toSorted((left, right) =>
    sort === "title_asc"
      ? left.title.localeCompare(right.title, "ko")
      : sort === "published_desc"
        ? casePublishedAt(right).localeCompare(casePublishedAt(left))
        : right.updatedAt.localeCompare(left.updatedAt),
  );
}

function searchCaseIndex(row: (typeof publicSearchRows)[number]) {
  if (row.resultType !== "CASE") return -1;
  return publicCaseRows.findIndex((candidate) => candidate.slug === row.id);
}

function searchMatches(row: (typeof publicSearchRows)[number], url: URL) {
  const types = values(url, "types").map((value) => value.toUpperCase());
  const states = values(url, "publicationState");
  const caseIndex = searchCaseIndex(row);
  const regionFiltered = ["agencyId", "sidoCode", "sigunguCode"].some((name) =>
    url.searchParams.has(name),
  );
  return (
    (types.length === 0 || types.includes(row.resultType)) &&
    (states.length === 0 || (caseIndex >= 0 && states.includes(row.status))) &&
    (!regionFiltered ||
      (caseIndex >= 0 &&
        matchesValue(url, "agencyId", publicAgencyRows[caseIndex]?.id ?? "") &&
        matchesValue(url, "sidoCode", TEST_SIDO_CODE) &&
        matchesValue(url, "sigunguCode", TEST_SIGUNGU_CODE))) &&
    matchesDateRange(row.updatedAt, url, "dateFrom", "dateTo")
  );
}

function searchRows(url: URL) {
  if ((url.searchParams.get("q")?.trim().length ?? 0) === 0) return [];
  const rows = publicSearchRows.filter((row) => searchMatches(row, url));
  const sort = url.searchParams.get("sort") ?? "relevance";
  if (sort === "relevance") return rows;
  return rows.toSorted((left, right) =>
    sort === "title_asc"
      ? left.title.localeCompare(right.title, "ko")
      : right.updatedAt.localeCompare(left.updatedAt),
  );
}

function exportCaseRows(url: URL): JsonObject[] {
  return caseRows(url).map((row) => ({
    slug: row.slug,
    title: row.title,
    publicState: row.publicState,
    summary: row.summary,
    revision: row.revision,
    updatedAt: row.updatedAt,
    responseStatus: row.responseStatus,
    correctionStatus: row.correctionStatus,
    nonConclusion: row.nonConclusion,
    href: row.href,
  }));
}

function exportSearchRows(url: URL): JsonObject[] {
  return searchRows(url).map((row) => ({
    resultType: row.resultType,
    id: row.id,
    title: row.title,
    subtitle: row.subtitle,
    status: row.status,
    summary: row.summary,
    nonConclusion: row.nonConclusion,
    interpretationNotice: row.interpretationNotice,
    updatedAt: row.updatedAt,
    href: row.href,
  }));
}

function exportContractRows(url: URL): JsonObject[] {
  const statuses = values(url, "contractStatus");
  const amountMin = Number(url.searchParams.get("amountMin") ?? "-Infinity");
  const amountMax = Number(url.searchParams.get("amountMax") ?? "Infinity");
  const q = url.searchParams.get("q")?.trim() ?? "";
  return publicContractRows
    .filter((row) => {
      const amount = Number(row.amount.amount);
      return (
        matchesValue(url, "agencyId", row.agency.id) &&
        matchesValue(url, "supplierId", row.supplier.id) &&
        matchesDateRange(row.signedAt, url, "signedFrom", "signedTo") &&
        (statuses.length === 0 || statuses.includes(row.status)) &&
        (!q || `${row.contractNumber} ${row.title}`.includes(q)) &&
        Number.isFinite(amount) &&
        amount >= amountMin &&
        amount <= amountMax &&
        !url.searchParams.has("procurementMethod")
      );
    })
    .map((row) => ({
      id: row.id,
      contractNumber: row.contractNumber,
      title: row.title,
      agencyName: row.agency.name,
      supplierName: row.supplier.name,
      status: row.status,
      signedAt: row.signedAt,
      amount: row.amount.amount,
      currency: row.amount.currency,
      interpretationNotice: row.interpretationNotice,
    }));
}

function csvCell(value: string) {
  return /[,"\r\n]/u.test(value) ? `"${value.replaceAll('"', '""')}"` : value;
}

function renderCsv(
  columns: readonly ExportColumn[],
  rows: readonly JsonObject[],
) {
  const records = [
    csvCell(EXPORT_NOTICE),
    columns.map(([, heading]) => csvCell(heading)).join(","),
    ...rows.map((row) =>
      columns.map(([key]) => csvCell(String(row[key] ?? ""))).join(","),
    ),
  ];
  return `${records.join("\r\n")}\r\n`;
}

function renderJsonl(rows: readonly JsonObject[]) {
  return `${[{ notice: EXPORT_NOTICE }, ...rows]
    .map((row) => JSON.stringify(row))
    .join("\n")}\n`;
}

function stableArtifactNotices(
  rows: readonly JsonObject[],
  key: "interpretationNotice" | "nonConclusion",
) {
  return [
    ...new Set(
      rows.flatMap((row) =>
        typeof row[key] === "string" && row[key].length > 0 ? [row[key]] : [],
      ),
    ),
  ];
}

function exportEnvelope(
  stem: string,
  format: ExportFormat,
  columns: readonly ExportColumn[],
  rows: readonly JsonObject[],
  appliedFilters: JsonObject,
) {
  const content =
    format === "CSV" ? renderCsv(columns, rows) : renderJsonl(rows);
  const bytes = Buffer.from(content, "utf8");
  const contentSha256 = createHash("sha256").update(bytes).digest("hex");
  const extension = format === "CSV" ? "csv" : "jsonl";
  const nonConclusionNotices = stableArtifactNotices(rows, "nonConclusion");
  const interpretationNotices = stableArtifactNotices(
    rows,
    "interpretationNotice",
  );
  if (interpretationNotices.length > 1)
    throw new Error(
      "public export mock has conflicting interpretation notices",
    );
  return {
    id: `${stem}-${contentSha256}`,
    status: "READY",
    version: 1,
    notice: EXPORT_NOTICE,
    filename: `${stem}.${extension}`,
    mediaType:
      format === "CSV"
        ? "text/csv; charset=utf-8"
        : "application/x-ndjson; charset=utf-8",
    byteLength: bytes.byteLength,
    contentSha256,
    contentBase64: bytes.toString("base64"),
    format,
    rowCount: rows.length,
    nonConclusionNotices,
    interpretationNotice:
      stem === "contracts"
        ? OPERATIONAL_INTERPRETATION_NOTICE
        : (interpretationNotices[0] ?? null),
    appliedFilters,
    generatedAt: FIXTURE_AS_OF,
  };
}

function requestedFormat(url: URL): ExportFormat | undefined {
  const formats = url.searchParams.getAll("format");
  return formats.length === 1 &&
    (formats[0] === "CSV" || formats[0] === "JSONL")
    ? formats[0]
    : undefined;
}

/** Returns real file bytes for public synchronous download operations. */
export function publicDownloadRead(url: URL): Response | undefined {
  if (
    url.pathname !== "/v1/cases/download" &&
    url.pathname !== "/v1/search/download" &&
    url.pathname !== "/v1/contracts/download"
  )
    return undefined;
  const format = requestedFormat(url);
  if (!format) return problem(400, "INVALID_PARAMETER");
  if (
    url.pathname === "/v1/search/download" &&
    (url.searchParams.get("q")?.trim().length ?? 0) < 2
  )
    return problem(400, "INVALID_PARAMETER");
  const envelope =
    url.pathname === "/v1/cases/download"
      ? exportEnvelope(
          "public-cases",
          format,
          CASE_EXPORT_COLUMNS,
          exportCaseRows(url),
          caseAppliedFilters(url),
        )
      : url.pathname === "/v1/search/download"
        ? exportEnvelope(
            "public-search-records",
            format,
            SEARCH_EXPORT_COLUMNS,
            exportSearchRows(url),
            searchAppliedFilters(url),
          )
        : exportEnvelope(
            "contracts",
            format,
            CONTRACT_EXPORT_COLUMNS,
            exportContractRows(url),
            contractAppliedFilters(url),
          );
  return Response.json(envelope);
}

function page(
  body: unknown,
  items: readonly JsonObject[],
  appliedFilters: JsonObject,
) {
  const object = jsonObject(body);
  return object
    ? { ...object, items, totalApproximate: items.length, appliedFilters }
    : body;
}

function regionAgency(row: JsonObject): JsonObject {
  return {
    ...row,
    sidoCode: TEST_SIDO_CODE,
    sigunguCode: TEST_SIGUNGU_CODE,
    regionCodeVersion: TEST_REGION_CODE_VERSION,
  };
}

/** Adds test-only regional fixtures and makes their filters affect list rows. */
export function publicReadResponseBody(
  operationId: string,
  body: unknown,
  url: URL,
): unknown {
  if (operationId === "listAgencies") {
    const items = publicAgencyRows.map((row) => regionAgency(row));
    return page(body, items, {
      q: url.searchParams.get("q")?.trim() ?? "",
      agencyType: values(url, "agencyType"),
      jurisdiction: url.searchParams.get("jurisdiction")?.trim() ?? "",
    });
  }
  if (operationId === "getAgency") {
    const object = jsonObject(body);
    const fixture = publicAgencyRows[0];
    return object && fixture
      ? regionAgency({
          ...object,
          name: fixture.name,
          agencyType: fixture.agencyType,
          jurisdiction: fixture.jurisdiction,
        })
      : body;
  }
  if (operationId === "listPublicCases")
    return page(body, caseRows(url), caseAppliedFilters(url));
  if (operationId === "searchPublicRecords")
    return page(body, searchRows(url), searchAppliedFilters(url));
  return body;
}
