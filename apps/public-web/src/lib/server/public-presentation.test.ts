import { describe, expect, it } from "vitest";
import {
  publicDatasetPresentation,
  publicLedgerPresentation,
} from "./public-presentation";

const asOf = "2026-07-30T00:00:00Z";

function uuid(index: number) {
  return `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`;
}

function counts() {
  return {
    total: 9,
    publication: Object.fromEntries(
      "neverPublished publishedAnomaly publishedExplained officiallyConfirmed corrected retracted temporarilyRestricted"
        .split(" ")
        .map((name) => [name, 0]),
    ),
    investigation: Object.fromEntries(
      "signalDetected triage investigating awaitingResponse editorialReview legalReview readyToPublish closed"
        .split(" ")
        .map((name) => [name, 0]),
    ),
    resolution: Object.fromEntries(
      "none dataError duplicate explained insufficientEvidence referredConfidential archived"
        .split(" ")
        .map((name) => [name, 0]),
    ),
  };
}

function coverage() {
  return {
    dateRange: { label: "2026년" },
    sourceIds: [],
    recordCount: 9,
    knownGaps: [],
    freshness: { asOf, status: "CURRENT" },
  };
}

function page(items: readonly unknown[], appliedFilters = {}) {
  return { items, appliedFilters, asOf };
}

function rows(build: (index: number) => Record<string, unknown>) {
  return Array.from({ length: 9 }, (_, index) => build(index + 1));
}

const cases = rows((index) => ({
  slug: `case-${index}`,
  title: `공개 사건 ${index}`,
  publicState: "PUBLISHED_EXPLAINED",
  summary: `사건 요약 ${index}`,
  revision: index,
  updatedAt: asOf,
  href: `/cases/case-${index}`,
}));

describe("closed public ledger presentation", () => {
  it.each([
    ["PUB-001", "listPublicCases", page(cases)],
    [
      "PUB-002",
      "searchPublicRecords",
      page(
        rows((index) => ({
          resultType: "CASE",
          id: `case-${index}`,
          title: `검색 결과 ${index}`,
          summary: `검색 요약 ${index}`,
          status: "PUBLISHED_EXPLAINED",
          updatedAt: asOf,
          href: `/cases/case-${index}`,
        })),
        {
          q: "가상 계약",
          types: ["CASE", "RULE", "DATASET"],
          agencyId: uuid(101),
          sidoCode: "11",
          sigunguCode: "11680",
          sort: "relevance",
        },
      ),
    ],
    [
      "PUB-003",
      "listPublicCases",
      page(cases, {
        publicationState: ["PUBLISHED_EXPLAINED"],
        agencyId: uuid(101),
        sidoCode: "11",
        sigunguCode: "11680",
        sort: "updated_desc",
      }),
    ],
    [
      "PUB-007",
      "listAgencies",
      page(
        rows((index) => ({
          id: uuid(index),
          name: `가상 기관 ${index}`,
          agencyType: "지방자치단체",
          jurisdiction: "가상도",
          sidoCode: "11",
          sigunguCode: "11680",
          regionCodeVersion: "행정표준코드-2026.1",
          caseCounts: counts(),
          coverage: coverage(),
          href: `/agencies/agency-${index}`,
        })),
      ),
    ],
    [
      "PUB-009",
      "listSuppliers",
      page(
        rows((index) => ({
          id: uuid(index),
          name: `가상 업체 ${index}`,
          businessStatus: "ACTIVE",
          caseCounts: counts(),
          coverage: coverage(),
          identityWarnings: [],
          href: `/suppliers/supplier-${index}`,
        })),
      ),
    ],
    [
      "PUB-011",
      "listContracts",
      page(
        rows((index) => ({
          id: uuid(index),
          contractNumber: `C-${index}`,
          title: `가상 계약 ${index}`,
          agency: {
            id: uuid(100 + index),
            name: `가상 기관 ${index}`,
            entityType: "AGENCY",
            href: `/agencies/agency-${index}`,
          },
          status: "ACTIVE",
          signedAt: "2026-07-30",
          amount: { amount: String(index * 100_000_000), currency: "KRW" },
          href: `/contracts/contract-${index}`,
        })),
      ),
    ],
    [
      "PUB-018",
      "listCorrections",
      page(
        rows((index) => ({
          id: uuid(index),
          sourceRevision: index,
          targetRevision: index + 1,
          summary: `정정 기록 ${index}`,
          reason: `정정 사유 ${index}`,
          publishedAt: asOf,
          href: `/corrections/correction-${index}`,
        })),
      ),
    ],
  ])("preserves every validated %s row without exposing the page DTO", (screenId, operationId, response) => {
    const presentation = publicLedgerPresentation(screenId, {
      [operationId]: response,
    });

    expect(presentation?.viewModel.rows).toHaveLength(9);
    expect(
      presentation?.viewModel.rows.every((row) => row.href?.startsWith("/")),
    ).toBe(true);
    expect(presentation?.viewModel).not.toHaveProperty("items");
    expect(presentation?.viewModel).not.toHaveProperty("appliedFilters");
  });

  it("rejects an OpenAPI-undeclared field instead of silently projecting it", () => {
    expect(() =>
      publicLedgerPresentation("PUB-003", {
        listPublicCases: { ...page(cases), internalNote: "must-not-leak" },
      }),
    ).toThrow();
  });

  it("never copies a raw, non-allowlisted item href into the ledger", () => {
    const response = page([
      { ...cases[0], href: "https://attacker.example/case" },
    ]);
    const presentation = publicLedgerPresentation("PUB-003", {
      listPublicCases: response,
    });

    expect(presentation?.viewModel.rows[0]?.href).toBeUndefined();
  });
});

describe("closed public dataset presentation", () => {
  it("keeps only the dataset card fields and preserves every item", () => {
    const records = publicDatasetPresentation("PUB-020", {
      listPublicDatasets: page(
        rows((index) => ({
          id: `dataset-${index}`,
          title: `공개 데이터셋 ${index}`,
          description: `데이터셋 설명 ${index}`,
          format: "CSV, JSONL",
          coverage: coverage(),
          license: "공개 이용",
          updatedAt: asOf,
          downloadUrl: `/downloads/dataset-${index}`,
        })),
      ),
    });

    expect(records).toHaveLength(9);
    expect(records?.[0]).toEqual({
      id: "dataset-1",
      title: "공개 데이터셋 1",
      description: "데이터셋 설명 1",
      format: "CSV, JSONL",
      license: "공개 이용",
      updatedAt: asOf,
    });
    expect(records?.[0]).not.toHaveProperty("coverage");
    expect(records?.[0]).not.toHaveProperty("downloadUrl");
  });
});
