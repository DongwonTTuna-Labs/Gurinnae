import { describe, expect, it } from "bun:test";
import { Buffer } from "node:buffer";
import { createHash } from "node:crypto";
import { handleReadRoutes } from "./mock-api-reads";

type JsonObject = Record<string, unknown>;

const NOTICE = "이상 징후 기록이며 위법·부패의 확정이 아님";
const ENVELOPE_KEYS = [
  "appliedFilters",
  "byteLength",
  "contentBase64",
  "contentSha256",
  "filename",
  "format",
  "generatedAt",
  "id",
  "mediaType",
  "rowCount",
  "status",
  "version",
];

function record(value: unknown): JsonObject {
  if (typeof value !== "object" || value === null || Array.isArray(value))
    throw new Error("expected a JSON object");
  return Object.fromEntries(Object.entries(value));
}

async function get(path: string) {
  const url = new URL(path, "http://mock.test");
  const response = await handleReadRoutes(new Request(url), url);
  const text = await response.text();
  if (response.status !== 200)
    throw new Error(`${path} failed mock routing: ${text}`);
  return record(JSON.parse(text));
}

function decodedContent(envelope: JsonObject) {
  expect(Object.keys(envelope).sort()).toEqual(ENVELOPE_KEYS);
  const base64 = String(envelope.contentBase64);
  const bytes = Buffer.from(base64, "base64");
  expect(bytes.toString("base64")).toBe(base64);
  expect(bytes.byteLength).toBe(envelope.byteLength);
  expect(createHash("sha256").update(bytes).digest("hex")).toBe(
    envelope.contentSha256,
  );
  expect(envelope.id).toBe(
    `${String(envelope.filename).replace(/\.(?:csv|jsonl)$/u, "")}-${String(envelope.contentSha256)}`,
  );
  return bytes.toString("utf8");
}

function verifyNoticeAndRows(envelope: JsonObject, content: string) {
  const rowCount = Number(envelope.rowCount);
  if (envelope.format === "JSONL") {
    const rows = content
      .trimEnd()
      .split("\n")
      .map((line) => record(JSON.parse(line)));
    expect(rows[0]).toEqual({ notice: NOTICE });
    expect(rows.slice(1)).toHaveLength(rowCount);
    return rows.slice(1);
  }
  const records = content.split("\r\n");
  expect(records.pop()).toBe("");
  expect(records[0]).toBe(NOTICE);
  expect(records.slice(2)).toHaveLength(rowCount);
  return records.slice(1);
}

function caseDownloadPath(format: "CSV" | "JSONL") {
  const query = new URLSearchParams({
    format,
    agencyId: "11000000-0000-4000-8000-000000000001",
    supplierId: "22000000-0000-4000-8000-000000000001",
    ruleId: "contract-unit-price-comparison",
    sidoCode: "11",
    sigunguCode: "11680",
    publishedFrom: "2026-07-01",
    publishedTo: "2026-07-30",
    hasResponse: "true",
    hasCorrection: "false",
    sort: "title_asc",
  });
  query.append("publicationState", "PUBLISHED_ANOMALY");
  return `/v1/cases/download?${query}`;
}

function searchDownloadPath(format: "CSV" | "JSONL") {
  const query = new URLSearchParams({
    format,
    q: "계약",
    dateFrom: "2026-07-01",
    dateTo: "2026-07-30",
    sort: "title_asc",
  });
  query.append("types", "RULE");
  query.append("types", "DATASET");
  return `/v1/search/download?${query}`;
}

describe("public export mock reads", () => {
  it("includes the normalized default filters in each download echo", async () => {
    const cases = await get("/v1/cases/download?format=JSONL");
    expect(cases.appliedFilters).toEqual({
      publicationState: [],
      sort: "updated_desc",
    });
    expect(cases.rowCount).toBe(8);

    const search = await get(
      "/v1/search/download?format=JSONL&q=%EA%B3%84%EC%95%BD",
    );
    expect(search.appliedFilters).toEqual({
      q: "계약",
      types: [],
      publicationState: [],
      sort: "relevance",
    });
    expect(search.rowCount).toBe(10);
  });

  it("returns actual CSV and JSONL case bytes with an exact normalized filter echo", async () => {
    for (const format of ["CSV", "JSONL"] as const) {
      const envelope = await get(caseDownloadPath(format));
      expect(envelope.format).toBe(format);
      expect(envelope.rowCount).toBe(1);
      expect(envelope.filename).toBe(
        `public-cases.${format === "CSV" ? "csv" : "jsonl"}`,
      );
      expect(envelope.mediaType).toBe(
        format === "CSV"
          ? "text/csv; charset=utf-8"
          : "application/x-ndjson; charset=utf-8",
      );
      expect(envelope.generatedAt).toBe("2026-07-29T09:00:00Z");
      expect(envelope.appliedFilters).toEqual({
        publicationState: ["PUBLISHED_ANOMALY"],
        sort: "title_asc",
        agencyId: "11000000-0000-4000-8000-000000000001",
        sidoCode: "11",
        sigunguCode: "11680",
        supplierId: "22000000-0000-4000-8000-000000000001",
        ruleId: "contract-unit-price-comparison",
        publishedFrom: "2026-07-01",
        publishedTo: "2026-07-30",
        hasResponse: true,
        hasCorrection: false,
      });
      const rows = verifyNoticeAndRows(envelope, decodedContent(envelope));
      if (format === "JSONL")
        expect(record(rows[0])).toMatchObject({
          slug: "civic-building-hvac-review",
          responseStatus: "RECEIVED",
          correctionStatus: null,
        });
      else
        expect(rows[0]).toBe(
          "slug,title,publicState,summary,revision,updatedAt,responseStatus,correctionStatus,href",
        );
    }
  });

  it("filters and sorts case downloads by publication time rather than update time", async () => {
    const envelope = await get(
      "/v1/cases/download?format=JSONL&publishedFrom=2026-07-23&publishedTo=2026-07-26&sort=published_desc",
    );
    expect(envelope.appliedFilters).toEqual({
      publicationState: [],
      sort: "published_desc",
      publishedFrom: "2026-07-23",
      publishedTo: "2026-07-26",
    });
    const rows = verifyNoticeAndRows(envelope, decodedContent(envelope));
    expect(rows.map((row) => record(row).slug)).toEqual([
      "health-sample-transport-confirmed",
      "park-tree-care-review",
    ]);
  });

  it("keeps RULE and DATASET search rows in both real file formats", async () => {
    for (const format of ["CSV", "JSONL"] as const) {
      const envelope = await get(searchDownloadPath(format));
      expect(envelope.format).toBe(format);
      expect(envelope.rowCount).toBe(2);
      expect(envelope.appliedFilters).toEqual({
        q: "계약",
        types: ["RULE", "DATASET"],
        publicationState: [],
        sort: "title_asc",
        dateFrom: "2026-07-01",
        dateTo: "2026-07-30",
      });
      const rows = verifyNoticeAndRows(envelope, decodedContent(envelope));
      if (format === "JSONL")
        expect(rows.map((row) => record(row).resultType).sort()).toEqual([
          "DATASET",
          "RULE",
        ]);
      else
        expect(rows[0]).toBe(
          "resultType,id,title,subtitle,status,summary,updatedAt,href",
        );
    }
  });

  it("publishes explicit test-only region codes and applies them to list filters", async () => {
    const agencies = record(await get("/v1/agencies"));
    const agencyRows = Array.isArray(agencies.items)
      ? agencies.items.map(record)
      : [];
    expect(agencyRows).toHaveLength(8);
    for (const agency of agencyRows) {
      expect(String(agency.name)).toEndWith("(가상)");
      expect(agency.sidoCode).toBe("11");
      expect(agency.sigunguCode).toBe("11680");
      expect(agency.regionCodeVersion).toBe("행정표준코드-2026.1");
    }

    const matchingCases = record(
      await get("/v1/cases?sidoCode=11&sigunguCode=11680"),
    );
    const otherCases = record(
      await get("/v1/cases?sidoCode=26&sigunguCode=26110"),
    );
    expect(
      Array.isArray(matchingCases.items) ? matchingCases.items : [],
    ).toHaveLength(8);
    expect(
      Array.isArray(otherCases.items) ? otherCases.items : [],
    ).toHaveLength(0);

    const matchingSearch = record(
      await get(
        "/v1/search?q=%EA%B3%84%EC%95%BD&types=CASE&sidoCode=11&sigunguCode=11680",
      ),
    );
    const otherSearch = record(
      await get(
        "/v1/search?q=%EA%B3%84%EC%95%BD&types=CASE&sidoCode=26&sigunguCode=26110",
      ),
    );
    expect(
      Array.isArray(matchingSearch.items) ? matchingSearch.items : [],
    ).toHaveLength(8);
    expect(
      Array.isArray(otherSearch.items) ? otherSearch.items : [],
    ).toHaveLength(0);
  });
});
