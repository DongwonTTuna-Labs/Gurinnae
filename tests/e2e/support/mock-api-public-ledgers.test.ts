import { describe, expect, it } from "bun:test";
import { handleMockRequest } from "./mock-api-routes";

type JsonObject = Record<string, unknown>;

const MINIMUM_LEDGER_ROWS = 8;

function record(value: unknown): JsonObject {
  if (typeof value !== "object" || value === null || Array.isArray(value))
    throw new Error("expected a JSON object");
  return Object.fromEntries(Object.entries(value));
}

function rows(page: JsonObject) {
  const items = page.items;
  if (!Array.isArray(items)) throw new Error("public page items are missing");
  return items.map(record);
}

async function publicPage(path: string) {
  const response = await handleMockRequest(
    new Request(`http://mock.test${path}`),
  );
  const payload = await response.text();
  if (response.status !== 200)
    throw new Error(`${path} failed OpenAPI validation: ${payload}`);
  const value: unknown = JSON.parse(payload);
  return record(value);
}

describe("populated public ledger mock", () => {
  it("keeps all five public ledgers at eight schema-valid rows", async () => {
    for (const path of [
      "/v1/cases",
      "/v1/agencies",
      "/v1/suppliers",
      "/v1/contracts",
      "/v1/corrections",
    ]) {
      expect(rows(await publicPage(path)).length).toBeGreaterThanOrEqual(
        MINIMUM_LEDGER_ROWS,
      );
    }
  });

  it("populates the default listPublicCases response used by home", async () => {
    const caseRows = rows(await publicPage("/v1/cases"));
    expect(caseRows).toHaveLength(MINIMUM_LEDGER_ROWS);
    expect(caseRows.every((row) => String(row.title).includes("계약"))).toBe(
      true,
    );
  });

  it("returns schema-valid CASE, RULE, and DATASET results only for a non-blank q", async () => {
    const populated = await publicPage("/v1/search?q=%20%EA%B3%84%EC%95%BD%20");
    const populatedRows = rows(populated);
    expect(
      populatedRows.filter((row) => row.resultType === "CASE"),
    ).toHaveLength(MINIMUM_LEDGER_ROWS);
    expect(
      [...new Set(populatedRows.map((row) => String(row.resultType)))].sort(),
    ).toEqual(["CASE", "DATASET", "RULE"]);
    expect(record(populated.appliedFilters).q).toBe("계약");

    const blank = await publicPage("/v1/search?q=%20%20");
    expect(rows(blank)).toHaveLength(0);
    expect(record(blank.appliedFilters).q).toBe("");
  });

  it("uses clearly fictional Korean organizations and positive KRW amounts", async () => {
    const agencyRows = rows(await publicPage("/v1/agencies"));
    const supplierRows = rows(await publicPage("/v1/suppliers"));
    const contractRows = rows(await publicPage("/v1/contracts"));

    for (const row of [...agencyRows, ...supplierRows]) {
      expect(String(row.name)).toMatch(/[가-힣]+.*\(가상\)$/u);
      expect(String(row.href)).not.toStartWith("/internal/");
    }
    for (const row of contractRows) {
      const amount = record(row.amount);
      expect(String(row.title)).toMatch(/[가-힣]/u);
      expect(amount.currency).toBe("KRW");
      expect(Number(amount.amount)).toBeGreaterThan(0);
      expect(String(row.href)).not.toStartWith("/internal/");
    }
    expect(
      JSON.stringify([...agencyRows, ...supplierRows, ...contractRows]),
    ).not.toContain("Synthetic");
  });

  it("keeps agency and supplier contract choices on the Korean public fixture", async () => {
    for (const path of [
      "/v1/agencies/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/contracts",
      "/v1/suppliers/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/contracts",
    ]) {
      const contractRows = rows(await publicPage(path));
      expect(contractRows).toHaveLength(1);
      expect(String(contractRows[0]?.title)).toMatch(/[가-힣]/u);
      expect(JSON.stringify(contractRows)).not.toContain("Synthetic");
      expect(JSON.stringify(contractRows)).not.toContain("SYNTHETIC");
    }
  });
});
