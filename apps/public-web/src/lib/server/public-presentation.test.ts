import { describe, expect, it } from "vitest";
import { publicLedgerPresentation } from "./public-presentation";

const asOf = "2026-07-30T00:00:00Z";
const nonConclusion =
  "공개자료 비교 결과의 이상 징후이며 위법·부패의 확정이 아닙니다.";
const interpretationNotice =
  "이 상태는 자료의 수집·공개·검토 상태이며 위법성이나 부패 여부에 대한 판단이 아닙니다.";
const sectionNonConclusion = "이상 징후 기록이며 위법·부패의 확정이 아님";

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

function page(
  items: readonly unknown[],
  appliedFilters = {},
  includeSeo = true,
) {
  return {
    items,
    appliedFilters,
    asOf,
    ...(includeSeo
      ? {
          seo: {
            title: "공개 대장 · 구린네",
            description: nonConclusion,
            openGraphDescription: nonConclusion,
            canonicalUrl: "/records",
            robots: "index,follow",
          },
        }
      : {}),
  };
}

function rows(build: (index: number) => Record<string, unknown>) {
  return Array.from({ length: 9 }, (_, index) => build(index + 1));
}

function sourceStatusItem(index: number) {
  return {
    sourceId: `source-${index}`,
    displayName: `공개 출처 ${index}`,
    status: "CURRENT",
    lastSuccessAt: asOf,
    lagSeconds: 0,
    publicMessage: "정상 수집 중",
    interpretationNotice,
  };
}

function coverageResponse() {
  return {
    asOf,
    sources: rows((index) => ({
      sourceId: `source-${index}`,
      displayName: `공개 출처 ${index}`,
      status: "CURRENT",
      dateRange: { label: "2026년" },
      recordCount: index,
      freshness: { asOf, status: "CURRENT" },
      knownGaps: [],
      interpretationNotice,
    })),
    dateRange: { label: "2026년" },
    recordCounts: {
      sourceDocuments: 9,
      contracts: 9,
      contractLineItems: 9,
      agencies: 9,
      suppliers: 9,
      publicCases: 9,
    },
    knownGaps: [],
    methodologyVersion: "coverage-v1",
  };
}

function systemStatusResponse() {
  return {
    status: "operational",
    asOf,
    affectedCapabilities: [],
    publicMessage: "정상 운영 중",
    sourceStatus: rows(sourceStatusItem),
  };
}

const cases = rows((index) => ({
  slug: `case-${index}`,
  title: `공개 사건 ${index}`,
  publicState: "PUBLISHED_EXPLAINED",
  summary: `사건 요약 ${index}`,
  revision: index,
  updatedAt: asOf,
  href: `/cases/case-${index}`,
  nonConclusion,
}));

describe("closed public ledger presentation", () => {
  it.each([
    ["PUB-001", "listPublicCases", page(cases), "NON_CONCLUSION"],
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
          nonConclusion,
          interpretationNotice: null,
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
      "NON_CONCLUSION",
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
      "NON_CONCLUSION",
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
          interpretationNotice,
        })),
      ),
      "INTERPRETATION",
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
          interpretationNotice,
        })),
      ),
      "INTERPRETATION",
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
          interpretationNotice,
        })),
      ),
      "INTERPRETATION",
    ],
    ["PUB-015", "getCoverage", coverageResponse(), "INTERPRETATION"],
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
          publicState: "CORRECTED",
          nonConclusion,
        })),
      ),
      "NON_CONCLUSION",
    ],
    [
      "PUB-016",
      "listSourceStatus",
      page(rows(sourceStatusItem), { status: ["CURRENT"] }),
      "INTERPRETATION",
    ],
  ] as const)("preserves every validated %s row without exposing the page DTO", (screenId, operationId, response, noticeKind) => {
    const presentation = publicLedgerPresentation(screenId, {
      [operationId]: response,
    });

    expect(presentation?.viewModel.rows).toHaveLength(9);
    expect(
      presentation?.viewModel.rows.every((row) => row.href?.startsWith("/")),
    ).toBe(true);
    expect(
      presentation?.viewModel.rows.every(
        (row) => row.status !== undefined && row.notice?.kind === noticeKind,
      ),
    ).toBe(true);
    expect(presentation?.viewModel.collectionNotices).toHaveLength(1);
    expect(presentation?.viewModel.collectionNotices[0]?.kind).toBe(noticeKind);
    expect(presentation?.viewModel.collectionNotices[0]?.text).toBe(
      noticeKind === "NON_CONCLUSION"
        ? sectionNonConclusion
        : interpretationNotice,
    );
    expect(presentation?.viewModel).not.toHaveProperty("items");
    expect(presentation?.viewModel).not.toHaveProperty("appliedFilters");
  });

  it("rejects a never-published case from every public ledger", () => {
    const item = cases.at(0);
    if (!item) throw new Error("공개 사건 검증 기준 행 누락");
    expect(() =>
      publicLedgerPresentation("PUB-003", {
        listPublicCases: page([{ ...item, publicState: "NEVER_PUBLISHED" }]),
      }),
    ).toThrow();
  });

  it.each([
    ["CASE", nonConclusion, null, "NON_CONCLUSION"],
    ["CORRECTION", nonConclusion, null, "NON_CONCLUSION"],
    ["AGENCY", null, interpretationNotice, "INTERPRETATION"],
    ["SUPPLIER", null, interpretationNotice, "INTERPRETATION"],
    ["CONTRACT", null, interpretationNotice, "INTERPRETATION"],
    ["RULE", null, null, null],
    ["DATASET", null, null, null],
    ["SOURCE", null, interpretationNotice, "INTERPRETATION"],
  ] as const)("closes the %s search-result notice combination", (resultType, itemNonConclusion, itemInterpretationNotice, kind) => {
    const presentation = publicLedgerPresentation("PUB-002", {
      searchPublicRecords: page([
        {
          resultType,
          id: `${resultType.toLowerCase()}-1`,
          title: `${resultType} 검색 결과`,
          status: "CURRENT",
          summary: "검색 결과 요약",
          updatedAt: asOf,
          href: searchHref(resultType),
          nonConclusion: itemNonConclusion,
          interpretationNotice: itemInterpretationNotice,
        },
      ]),
    });

    expect(presentation?.viewModel.rows[0]?.notice?.kind ?? null).toBe(kind);
  });

  it.each([
    ["CASE", nonConclusion, interpretationNotice],
    ["AGENCY", nonConclusion, null],
    ["RULE", null, interpretationNotice],
  ] as const)("rejects the invalid %s search-result notice combination", (resultType, itemNonConclusion, itemInterpretationNotice) => {
    expect(() =>
      publicLedgerPresentation("PUB-002", {
        searchPublicRecords: page([
          {
            resultType,
            id: `${resultType.toLowerCase()}-invalid`,
            title: `${resultType} 잘못된 검색 결과`,
            status: "CURRENT",
            summary: "검색 결과 요약",
            updatedAt: asOf,
            href: searchHref(resultType),
            nonConclusion: itemNonConclusion,
            interpretationNotice: itemInterpretationNotice,
          },
        ]),
      }),
    ).toThrow("검색");
  });

  it("rejects an OpenAPI-undeclared field instead of silently projecting it", () => {
    expect(() =>
      publicLedgerPresentation("PUB-003", {
        listPublicCases: { ...page(cases), internalNote: "must-not-leak" },
      }),
    ).toThrow();
  });

  it("fails closed when a source ledger row omits its interpretation notice", () => {
    expect(() =>
      publicLedgerPresentation("PUB-016", {
        listSourceStatus: page([
          {
            sourceId: "source-1",
            displayName: "공개 출처",
            status: "CURRENT",
            lastSuccessAt: asOf,
          },
        ]),
      }),
    ).toThrow();
  });

  it("renders every system-status source with adjacent status and notice", () => {
    const presentation = publicLedgerPresentation("PUB-034", {
      getPublicSystemStatus: systemStatusResponse(),
    });

    expect(presentation?.viewModel.rows).toHaveLength(9);
    expect(
      presentation?.viewModel.rows.every(
        (row) =>
          row.status !== undefined &&
          row.notice?.kind === "INTERPRETATION" &&
          row.href === undefined,
      ),
    ).toBe(true);
  });

  it("fails closed on missing or undeclared coverage and system source fields", () => {
    const coveragePayload = coverageResponse();
    const [firstCoverage, ...remainingCoverage] = coveragePayload.sources;
    if (!firstCoverage) throw new Error("출처 범위 기준 행 누락");
    const { interpretationNotice: _coverageNotice, ...coverageWithoutNotice } =
      firstCoverage;
    expect(() =>
      publicLedgerPresentation("PUB-015", {
        getCoverage: {
          ...coveragePayload,
          sources: [coverageWithoutNotice, ...remainingCoverage],
        },
      }),
    ).toThrow();
    expect(() =>
      publicLedgerPresentation("PUB-015", {
        getCoverage: { ...coveragePayload, internalNote: "must-not-leak" },
      }),
    ).toThrow();

    const systemPayload = systemStatusResponse();
    const [firstStatus, ...remainingStatus] = systemPayload.sourceStatus;
    if (!firstStatus) throw new Error("출처 상태 기준 행 누락");
    const { interpretationNotice: _statusNotice, ...statusWithoutNotice } =
      firstStatus;
    expect(() =>
      publicLedgerPresentation("PUB-034", {
        getPublicSystemStatus: {
          ...systemPayload,
          sourceStatus: [statusWithoutNotice, ...remainingStatus],
        },
      }),
    ).toThrow();
    expect(() =>
      publicLedgerPresentation("PUB-034", {
        getPublicSystemStatus: {
          ...systemPayload,
          sourceStatus: [
            { ...firstStatus, internalNote: "must-not-leak" },
            ...remainingStatus,
          ],
        },
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

function searchHref(resultType: string): string {
  const pathByType: Readonly<Record<string, string>> = {
    AGENCY: "/agencies/agency-1",
    CASE: "/cases/case-1",
    CONTRACT: "/contracts/contract-1",
    CORRECTION: "/corrections/correction-1",
    DATASET: "/data",
    RULE: "/methodology/rules/rule-1",
    SOURCE: "/sources/source-1",
    SUPPLIER: "/suppliers/supplier-1",
  };
  const href = pathByType[resultType];
  if (!href) throw new Error(`테스트 검색 유형 경로 누락: ${resultType}`);
  return href;
}
