import { Buffer } from "node:buffer";
import { createHash } from "node:crypto";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  PUBLIC_EXPORT_NOTICE,
  PUBLIC_OPERATIONAL_INTERPRETATION_NOTICE,
  parsePublicExportRequest,
  publicExportDestination,
  publicExportResponse,
  verifiedPublicDownloadPayload,
} from "./public-export";

const invokePublicOperation = vi.hoisted(() => vi.fn());
const privateEnv = vi.hoisted(() => ({
  PUBLIC_API_INTERNAL_URL: "http://public-api.test",
}));

vi.mock("@gurine/api-client-public", () => ({ invokePublicOperation }));
vi.mock("$env/dynamic/private", () => ({ env: privateEnv }));

const agencyId = "00000000-0000-4000-8000-000000000001";
const nonConclusion =
  "공개자료 비교에서 설명이 필요한 차이가 확인됐습니다. 현재 자료만으로 위법성이나 부패 여부를 판단할 수 없습니다.";
const expectedSearchFilters = {
  q: "계약",
  types: ["CASE", "AGENCY"],
  publicationState: [],
  agencyId,
  sort: "relevance",
};

function jsonl(...rows: Readonly<Record<string, unknown>>[]) {
  return `${[{ notice: PUBLIC_EXPORT_NOTICE }, ...rows]
    .map((row) => JSON.stringify(row))
    .join("\n")}\n`;
}

function searchCaseRow(overrides: Readonly<Record<string, unknown>> = {}) {
  return {
    resultType: "CASE",
    id: "case-1",
    title: "계약 사례",
    subtitle: "공개 사례",
    status: "PUBLISHED_ANOMALY",
    summary: "공개 사례 요약",
    nonConclusion,
    interpretationNotice: null,
    updatedAt: "2026-07-30T12:00:00Z",
    href: "/cases/case-1",
    ...overrides,
  };
}

function csvRecord(values: readonly string[]) {
  return values
    .map((value) =>
      /[,"\r\n]/u.test(value) ? `"${value.replaceAll('"', '""')}"` : value,
    )
    .join(",");
}

function envelope(
  content: string,
  overrides: Readonly<Record<string, unknown>> = {},
) {
  const bytes = Buffer.from(content, "utf8");
  return {
    id: "download-1",
    status: "READY",
    version: 1,
    notice: PUBLIC_EXPORT_NOTICE,
    filename: "gurine-search.jsonl",
    mediaType: "application/x-ndjson; charset=utf-8",
    byteLength: bytes.byteLength,
    contentSha256: createHash("sha256").update(bytes).digest("hex"),
    contentBase64: bytes.toString("base64"),
    format: "JSONL",
    rowCount: 1,
    nonConclusionNotices: [nonConclusion],
    interpretationNotice: null,
    appliedFilters: expectedSearchFilters,
    generatedAt: "2026-07-30T12:00:00Z",
    ...overrides,
  };
}

function searchUrl(extra = ""): URL {
  return new URL(
    `/downloads/search?q=%EA%B3%84%EC%95%BD&types=case&types=AGENCY&agencyId=${agencyId}&format=JSONL${extra}`,
    "https://public.example",
  );
}

beforeEach(() => {
  invokePublicOperation.mockReset();
});

describe("public export query boundary", () => {
  it("retains only the closed current filters and never carries pagination", () => {
    const destination = publicExportDestination(
      "PUB-002",
      "CSV",
      new URLSearchParams({
        q: " 계약 ",
        types: "case,AGENCY",
        sidoCode: "11",
        cursor: "old-page",
        limit: "100",
        internal: "must-not-survive",
      }),
    );

    expect(destination).toBeDefined();
    const url = new URL(destination ?? "", "https://public.example");
    expect([...url.searchParams.entries()]).toEqual([
      ["q", "계약"],
      ["types", "CASE"],
      ["types", "AGENCY"],
      ["sidoCode", "11"],
      ["sort", "relevance"],
      ["format", "CSV"],
    ]);
    expect(url.searchParams.has("cursor")).toBe(false);
    expect(url.searchParams.has("limit")).toBe(false);
    expect(
      parsePublicExportRequest("PUB-002", searchUrl().searchParams),
    ).toEqual({ format: "JSONL", filters: expectedSearchFilters });
    expect(
      parsePublicExportRequest(
        "PUB-003",
        new URLSearchParams({ format: "CSV" }),
      ),
    ).toEqual({
      format: "CSV",
      filters: { publicationState: [], sort: "updated_desc" },
    });
  });

  it("rejects direct side-door parameters, invalid formats and missing search terms", () => {
    expect(
      parsePublicExportRequest("PUB-002", searchUrl("&limit=1").searchParams),
    ).toBeUndefined();
    expect(
      parsePublicExportRequest(
        "PUB-002",
        new URLSearchParams({ q: "계약", format: "PDF" }),
      ),
    ).toBeUndefined();
    expect(
      publicExportDestination("PUB-002", "JSONL", new URLSearchParams()),
    ).toBeUndefined();
    expect(
      publicExportDestination(
        "PUB-002",
        "JSONL",
        new URLSearchParams({ q: "계" }),
      ),
    ).toBeUndefined();
  });
});

describe("public export binary boundary", () => {
  it("calls the generated client server-side and returns only verified bytes", async () => {
    const content = jsonl(searchCaseRow());
    invokePublicOperation.mockResolvedValue({
      data: envelope(content),
      response: new Response(null, { status: 200 }),
    });

    const response = await publicExportResponse({
      fetch: globalThis.fetch,
      kind: "SEARCH",
      operationId: "downloadPublicSearchRecords",
      screenId: "PUB-002",
      url: searchUrl(),
    });

    expect(invokePublicOperation).toHaveBeenCalledWith({
      operationId: "downloadPublicSearchRecords",
      baseUrl: "http://public-api.test",
      fetch: globalThis.fetch,
      query: {
        ...expectedSearchFilters,
        format: "JSONL",
      },
    });
    expect(response.status).toBe(200);
    expect(await response.text()).toBe(content);
    expect(response.headers.get("content-type")).toBe(
      "application/x-ndjson; charset=utf-8",
    );
    expect(response.headers.get("content-disposition")).toContain(
      'attachment; filename="gurine-search.jsonl"',
    );
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
  });

  it.each([
    ["unclosed envelope", { unexpected: true }],
    ["missing envelope notice", { notice: undefined }],
    ["filter echo mismatch", { appliedFilters: { q: "다른 검색" } }],
    [
      "reordered filter echo",
      {
        appliedFilters: {
          ...expectedSearchFilters,
          types: ["AGENCY", "CASE"],
        },
      },
    ],
    [
      "duplicated filter echo",
      {
        appliedFilters: {
          ...expectedSearchFilters,
          types: ["CASE", "AGENCY", "AGENCY"],
        },
      },
    ],
    ["digest mismatch", { contentSha256: "0".repeat(64) }],
    ["length mismatch", { byteLength: 999 }],
    ["format media mismatch", { mediaType: "text/csv; charset=utf-8" }],
    ["row count mismatch", { rowCount: 2 }],
    ["notice metadata mismatch", { nonConclusionNotices: [] }],
    [
      "interpretation metadata mismatch",
      { interpretationNotice: PUBLIC_OPERATIONAL_INTERPRETATION_NOTICE },
    ],
  ])("fails closed on %s", async (_name, overrides) => {
    invokePublicOperation.mockResolvedValue({
      data: envelope(jsonl(searchCaseRow()), overrides),
      response: new Response(null, { status: 200 }),
    });

    const response = await publicExportResponse({
      fetch: globalThis.fetch,
      kind: "SEARCH",
      operationId: "downloadPublicSearchRecords",
      screenId: "PUB-002",
      url: searchUrl(),
    });

    expect(response.status).toBe(502);
    expect(response.headers.get("cache-control")).toBe("no-store");
  });

  it("rejects valid bytes whose first record omits the redistribution notice", async () => {
    invokePublicOperation.mockResolvedValue({
      data: envelope(`${JSON.stringify({ data: "first" })}\n`),
      response: new Response(null, { status: 200 }),
    });

    const response = await publicExportResponse({
      fetch: globalThis.fetch,
      kind: "SEARCH",
      operationId: "downloadPublicSearchRecords",
      screenId: "PUB-002",
      url: searchUrl(),
    });

    expect(response.status).toBe(502);
  });

  it("rejects a notice-only artifact that claims one data row", () => {
    const content = jsonl();
    expect(
      verifiedPublicDownloadPayload(
        envelope(content, {
          rowCount: 1,
          nonConclusionNotices: [],
        }),
        { format: "JSONL", kind: "SEARCH" },
      ),
    ).toBeUndefined();
  });

  it("requires the operational envelope notice even for an empty contract export", () => {
    const content = jsonl();
    const contractEnvelope = envelope(content, {
      filename: "contracts.jsonl",
      rowCount: 0,
      nonConclusionNotices: [],
      interpretationNotice: PUBLIC_OPERATIONAL_INTERPRETATION_NOTICE,
    });
    expect(
      verifiedPublicDownloadPayload(contractEnvelope, {
        format: "JSONL",
        kind: "CONTRACTS",
      }),
    ).toBeDefined();
    expect(
      verifiedPublicDownloadPayload(
        { ...contractEnvelope, interpretationNotice: null },
        { format: "JSONL", kind: "CONTRACTS" },
      ),
    ).toBeUndefined();
  });

  it("rejects a search row whose required non-conclusion notice was stripped", () => {
    const content = jsonl(searchCaseRow({ nonConclusion: null }));
    expect(
      verifiedPublicDownloadPayload(
        envelope(content, { nonConclusionNotices: [] }),
        { format: "JSONL", kind: "SEARCH" },
      ),
    ).toBeUndefined();
  });

  it("rejects missing states, noncanonical fixed notices, and unknown result types", () => {
    const invalidRows = [
      {
        row: searchCaseRow({ status: undefined }),
        nonConclusionNotices: [nonConclusion],
      },
      {
        row: searchCaseRow({ nonConclusion: "임의 비확정 문구" }),
        nonConclusionNotices: ["임의 비확정 문구"],
      },
      {
        row: {
          resultType: "REPORT",
          nonConclusion: null,
          interpretationNotice: null,
        },
        nonConclusionNotices: [],
      },
    ];
    for (const invalid of invalidRows) {
      expect(
        verifiedPublicDownloadPayload(
          envelope(jsonl(invalid.row), {
            nonConclusionNotices: invalid.nonConclusionNotices,
          }),
          { format: "JSONL", kind: "SEARCH" },
        ),
      ).toBeUndefined();
    }
  });

  it("validates every search result branch and stable-deduplicates artifact notices", () => {
    const correctionNotice =
      "이 페이지는 정정됐습니다. 정정 기록에서 변경된 근거와 영향을 확인할 수 있습니다.";
    const operational = (resultType: string) => ({
      resultType,
      nonConclusion: null,
      interpretationNotice: PUBLIC_OPERATIONAL_INTERPRETATION_NOTICE,
    });
    const neither = (resultType: string) => ({
      resultType,
      nonConclusion: null,
      interpretationNotice: null,
    });
    const content = jsonl(
      searchCaseRow(),
      {
        resultType: "CORRECTION",
        status: "CORRECTED",
        nonConclusion: correctionNotice,
        interpretationNotice: null,
      },
      operational("AGENCY"),
      operational("SUPPLIER"),
      operational("CONTRACT"),
      operational("SOURCE"),
      neither("RULE"),
      neither("DATASET"),
      searchCaseRow({ id: "case-2" }),
    );
    const payload = verifiedPublicDownloadPayload(
      envelope(content, {
        rowCount: 9,
        nonConclusionNotices: [nonConclusion, correctionNotice],
        interpretationNotice: PUBLIC_OPERATIONAL_INTERPRETATION_NOTICE,
      }),
      { format: "JSONL", kind: "SEARCH" },
    );

    expect(payload?.bytes.toString("utf8")).toBe(content);
  });

  it("accepts an RFC 4180 quoted newline and escaped quote in a case row", () => {
    const header = [
      "slug",
      "title",
      "publicState",
      "summary",
      "revision",
      "updatedAt",
      "responseStatus",
      "correctionStatus",
      "nonConclusion",
      "href",
    ];
    const row = [
      "case-1",
      '첫 줄\r\n둘째 줄의 "인용"',
      "PUBLISHED_ANOMALY",
      "쉼표, 줄바꿈과 인용부호를 보존합니다.",
      "1",
      "2026-07-30T12:00:00Z",
      "",
      "",
      nonConclusion,
      "/cases/case-1",
    ];
    const content = `${[
      csvRecord([PUBLIC_EXPORT_NOTICE]),
      csvRecord(header),
      csvRecord(row),
    ].join("\r\n")}\r\n`;
    const payload = verifiedPublicDownloadPayload(
      envelope(content, {
        filename: "gurine-cases.csv",
        mediaType: "text/csv; charset=utf-8",
        format: "CSV",
      }),
      { format: "CSV", kind: "CASES" },
    );

    expect(payload?.bytes.toString("utf8")).toBe(content);
  });

  it("redirects only the declared 5,000-row precondition failure to neutral dataset guidance", async () => {
    invokePublicOperation.mockResolvedValue({
      error: { code: "PRECONDITION_FAILED" },
      response: new Response(null, { status: 422 }),
    });

    const response = await publicExportResponse({
      fetch: globalThis.fetch,
      kind: "SEARCH",
      operationId: "downloadPublicSearchRecords",
      screenId: "PUB-002",
      url: searchUrl(),
    });

    expect(response.status).toBe(303);
    const location = response.headers.get("location");
    expect(location).toContain("/data?notice=");
    expect(decodeURIComponent(location ?? "")).toContain("5,000건");
  });

  it("does not reinterpret another upstream 422 as the row-limit guidance", async () => {
    invokePublicOperation.mockResolvedValue({
      error: { code: "VALIDATION_FAILED" },
      response: new Response(null, { status: 422 }),
    });

    const response = await publicExportResponse({
      fetch: globalThis.fetch,
      kind: "SEARCH",
      operationId: "downloadPublicSearchRecords",
      screenId: "PUB-002",
      url: searchUrl(),
    });

    expect(response.status).toBe(422);
    expect(response.headers.get("location")).toBeNull();
  });
});
