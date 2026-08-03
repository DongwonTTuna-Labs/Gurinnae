import { createHash } from "node:crypto";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  parsePublicExportRequest,
  publicExportDestination,
  publicExportResponse,
} from "./public-export";

const invokePublicOperation = vi.hoisted(() => vi.fn());
const privateEnv = vi.hoisted(() => ({
  PUBLIC_API_INTERNAL_URL: "http://public-api.test",
}));

vi.mock("@gurine/api-client-public", () => ({ invokePublicOperation }));
vi.mock("$env/dynamic/private", () => ({ env: privateEnv }));

const agencyId = "00000000-0000-4000-8000-000000000001";

function envelope(
  content: string,
  overrides: Readonly<Record<string, unknown>> = {},
) {
  const bytes = Buffer.from(content, "utf8");
  return {
    id: "download-1",
    status: "READY",
    version: 1,
    filename: "gurine-search.jsonl",
    mediaType: "application/x-ndjson; charset=utf-8",
    byteLength: bytes.byteLength,
    contentSha256: createHash("sha256").update(bytes).digest("hex"),
    contentBase64: bytes.toString("base64"),
    format: "JSONL",
    rowCount: 1,
    appliedFilters: {
      q: "계약",
      types: ["CASE", "AGENCY"],
      agencyId,
      sort: "relevance",
    },
    generatedAt: "2026-07-30T12:00:00Z",
    ...overrides,
  };
}

function searchUrl(extra = ""): URL {
  return new URL(
    `/downloads/search?q=%EA%B3%84%EC%95%BD&types=CASE&types=AGENCY&agencyId=${agencyId}&format=JSONL${extra}`,
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
        types: "CASE,AGENCY",
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
    const content = `${JSON.stringify({ notice: "이상 징후 기록" })}\n`;
    invokePublicOperation.mockResolvedValue({
      data: envelope(content),
      response: new Response(null, { status: 200 }),
    });

    const response = await publicExportResponse({
      fetch: globalThis.fetch,
      operationId: "downloadPublicSearchRecords",
      screenId: "PUB-002",
      url: searchUrl(),
    });

    expect(invokePublicOperation).toHaveBeenCalledWith({
      operationId: "downloadPublicSearchRecords",
      baseUrl: "http://public-api.test",
      fetch: globalThis.fetch,
      query: {
        q: "계약",
        types: ["CASE", "AGENCY"],
        agencyId,
        sort: "relevance",
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
    ["filter echo mismatch", { appliedFilters: { q: "다른 검색" } }],
    ["digest mismatch", { contentSha256: "0".repeat(64) }],
    ["length mismatch", { byteLength: 999 }],
    ["format media mismatch", { mediaType: "text/csv; charset=utf-8" }],
  ])("fails closed on %s", async (_name, overrides) => {
    invokePublicOperation.mockResolvedValue({
      data: envelope("one\n", overrides),
      response: new Response(null, { status: 200 }),
    });

    const response = await publicExportResponse({
      fetch: globalThis.fetch,
      operationId: "downloadPublicSearchRecords",
      screenId: "PUB-002",
      url: searchUrl(),
    });

    expect(response.status).toBe(502);
    expect(response.headers.get("cache-control")).toBe("no-store");
  });

  it("redirects only the declared 5,000-row precondition failure to neutral dataset guidance", async () => {
    invokePublicOperation.mockResolvedValue({
      error: { code: "PRECONDITION_FAILED" },
      response: new Response(null, { status: 422 }),
    });

    const response = await publicExportResponse({
      fetch: globalThis.fetch,
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
      operationId: "downloadPublicSearchRecords",
      screenId: "PUB-002",
      url: searchUrl(),
    });

    expect(response.status).toBe(422);
    expect(response.headers.get("location")).toBeNull();
  });
});
