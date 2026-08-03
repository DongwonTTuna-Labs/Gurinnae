import { describe, expect, it } from "vitest";
import { PUBLIC_EMPTY_RESULT_NOTICE } from "./public-presentation-schemas";
import { publicSeoPresentation } from "./public-seo-presentation";

const requestUrl = new URL("https://gurinnae.example/cases?q=계약");
const noticeA = "공개자료 비교 결과의 비확정 고지입니다.";
const noticeB = "정정 기록의 비확정 고지입니다.";
const sourceNotice =
  "이 상태는 자료의 수집·공개·검토 상태이며 위법성이나 부패 여부에 대한 판단이 아닙니다.";
const asOf = "2026-07-30T00:00:00Z";

function seo(description = noticeA) {
  return {
    title: "공개 대장 · 구린네",
    description,
    openGraphDescription: description,
    canonicalUrl: "/cases",
    robots: "index,follow",
  };
}

function page(items: readonly unknown[]) {
  return {
    items,
    appliedFilters: {},
    asOf: "2026-07-30T00:00:00Z",
    seo: seo(),
  };
}

function caseItem(nonConclusion = noticeA) {
  return {
    slug: "case-1",
    title: "공개 사건",
    publicState: "PUBLISHED_ANOMALY",
    summary: "사건 요약",
    revision: 1,
    updatedAt: "2026-07-30T00:00:00Z",
    href: "/cases/case-1",
    nonConclusion,
  };
}

function correctionItem(nonConclusion = noticeB) {
  return {
    id: "00000000-0000-4000-8000-000000000001",
    sourceRevision: 1,
    targetRevision: 2,
    summary: "정정 요약",
    reason: "정정 사유",
    publishedAt: "2026-07-30T00:00:00Z",
    href: "/corrections/correction-1",
    publicState: "CORRECTED",
    nonConclusion,
  };
}

function sourcePage(description = sourceNotice) {
  return {
    items: [
      {
        sourceId: "source-1",
        displayName: "공개 출처",
        status: "CURRENT",
        lastSuccessAt: "2026-07-30T00:00:00Z",
        lagSeconds: 0,
        publicMessage: "정상 수집 중",
        interpretationNotice: sourceNotice,
      },
    ],
    appliedFilters: {},
    asOf: "2026-07-30T00:00:00Z",
    seo: {
      title: "데이터 출처 · 구린네",
      description,
      openGraphDescription: description,
      canonicalUrl: "/sources",
      robots: "index,follow",
    },
  };
}

function sourceStatus() {
  return {
    sourceId: "source-1",
    displayName: "공개 출처",
    status: "CURRENT",
    lastSuccessAt: asOf,
    lagSeconds: 0,
    publicMessage: "정상 수집 중",
    interpretationNotice: sourceNotice,
  };
}

function coverageResponse() {
  return {
    asOf,
    sources: [
      {
        sourceId: "source-1",
        displayName: "공개 출처",
        status: "CURRENT",
        dateRange: { label: "2026년" },
        recordCount: 1,
        freshness: { asOf, status: "CURRENT" },
        knownGaps: [],
        interpretationNotice: sourceNotice,
      },
    ],
    dateRange: { label: "2026년" },
    recordCounts: {
      sourceDocuments: 1,
      contracts: 1,
      contractLineItems: 1,
      agencies: 1,
      suppliers: 1,
      publicCases: 1,
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
    sourceStatus: [sourceStatus()],
  };
}

function sourceResponse() {
  return {
    id: { id: "source-1", status: "CURRENT", version: 1 },
    status: "CURRENT",
    data: {
      sourceId: "source-1",
      displayName: "공개 출처",
      owner: "공개 데이터 제공기관",
      accessType: "PUBLIC",
      officialUrl: null,
      status: "CURRENT",
      coverage: {
        dateRange: { label: "2026년" },
        sourceIds: ["source-1"],
        recordCount: 1,
        knownGaps: [],
        freshness: { asOf, status: "CURRENT" },
      },
      freshness: { asOf, status: "CURRENT" },
      knownIssues: [],
      interpretationNotice: sourceNotice,
    },
    links: [],
    seo: {
      title: "데이터 출처 상세 · 구린네",
      description: sourceNotice,
      openGraphDescription: sourceNotice,
      canonicalUrl: "/sources/source-1",
      robots: "index,follow",
    },
  };
}

describe("public SEO presentation", () => {
  it("validates same-origin canonical metadata and exact OpenGraph copy", () => {
    expect(
      publicSeoPresentation(
        "PUB-003",
        "사례 대장",
        { listPublicCases: page([caseItem()]) },
        requestUrl,
      ),
    ).toEqual({
      ...seo(),
      canonicalUrl: "https://gurinnae.example/cases",
    });
  });

  it("rejects cross-origin canonical and divergent OpenGraph copy", () => {
    expect(() =>
      publicSeoPresentation(
        "PUB-003",
        "사례 대장",
        {
          listPublicCases: {
            seo: { ...seo(), canonicalUrl: "https://attacker.example/cases" },
          },
        },
        requestUrl,
      ),
    ).toThrow("canonical origin");
    expect(() =>
      publicSeoPresentation(
        "PUB-003",
        "사례 대장",
        {
          listPublicCases: {
            seo: { ...seo(), openGraphDescription: "다른 설명" },
          },
        },
        requestUrl,
      ),
    ).toThrow("설명 계약 불일치");
  });

  it("rejects API paths and query fragments as a public canonical", () => {
    for (const canonicalUrl of ["/v1/cases", "/cases?cursor=internal"]) {
      expect(() =>
        publicSeoPresentation(
          "PUB-003",
          "사례 대장",
          {
            listPublicCases: {
              ...page([caseItem()]),
              seo: { ...seo(), canonicalUrl },
            },
          },
          requestUrl,
        ),
      ).toThrow("canonical 경로");
    }
  });

  it("merges home case and correction notices in canonical order without duplicates", () => {
    const result = publicSeoPresentation(
      "PUB-001",
      "홈",
      {
        listPublicCases: page([caseItem(), caseItem()]),
        listCorrections: {
          ...page([correctionItem()]),
          seo: seo(noticeB),
        },
        listSourceStatus: { ...sourcePage(), items: [] },
      },
      new URL("https://gurinnae.example/"),
    );
    expect(result?.description).toBe(`${noticeA} · ${noticeB}`);
    expect(result?.openGraphDescription).toBe(result?.description);
    expect(result?.canonicalUrl).toBe("https://gurinnae.example/");
  });

  it("requires every rendered list status notice in SEO and OpenGraph copy", () => {
    expect(() =>
      publicSeoPresentation(
        "PUB-003",
        "사례 대장",
        {
          listPublicCases: {
            ...page([caseItem(noticeB)]),
            seo: seo(noticeA),
          },
        },
        requestUrl,
      ),
    ).toThrow("상태 고지 누락");
  });

  it("requires the exact detail notice in SEO and OpenGraph copy", () => {
    expect(() =>
      publicSeoPresentation(
        "PUB-008",
        "기관 상세",
        {
          getAgency: {
            name: "가상 기관",
            freshness: { status: "CURRENT" },
            interpretationNotice: noticeB,
            seo: {
              ...seo(noticeA),
              canonicalUrl: "/agencies/agency-1",
            },
          },
        },
        new URL("https://gurinnae.example/agencies/agency-1"),
      ),
    ).toThrow("상태 고지 누락");
  });

  it("keeps source list and detail notices in canonical SEO metadata", () => {
    expect(
      publicSeoPresentation(
        "PUB-016",
        "데이터 출처",
        { listSourceStatus: sourcePage() },
        new URL("https://gurinnae.example/sources"),
      ),
    ).toMatchObject({
      description: sourceNotice,
      openGraphDescription: sourceNotice,
      canonicalUrl: "https://gurinnae.example/sources",
    });

    expect(
      publicSeoPresentation(
        "PUB-017",
        "데이터 출처 상세",
        { getSource: sourceResponse() },
        new URL("https://gurinnae.example/sources/source-1"),
      ),
    ).toMatchObject({
      description: sourceNotice,
      openGraphDescription: sourceNotice,
      canonicalUrl: "https://gurinnae.example/sources/source-1",
    });
  });

  it("fails closed when source list SEO omits the row notice", () => {
    expect(() =>
      publicSeoPresentation(
        "PUB-016",
        "데이터 출처",
        { listSourceStatus: sourcePage("데이터 출처") },
        new URL("https://gurinnae.example/sources"),
      ),
    ).toThrow("상태 고지 누락");
  });

  it("carries source notices into home and coverage SEO", () => {
    const home = publicSeoPresentation(
      "PUB-001",
      "홈",
      {
        listPublicCases: {
          ...page([]),
          seo: seo(PUBLIC_EMPTY_RESULT_NOTICE),
        },
        listCorrections: {
          ...page([]),
          seo: seo(PUBLIC_EMPTY_RESULT_NOTICE),
        },
        listSourceStatus: sourcePage(),
      },
      new URL("https://gurinnae.example/"),
    );
    const coverage = publicSeoPresentation(
      "PUB-015",
      "데이터 범위",
      { getCoverage: coverageResponse() },
      new URL("https://gurinnae.example/coverage"),
    );

    expect(home?.description).toContain(sourceNotice);
    expect(home?.openGraphDescription).toBe(home?.description);
    expect(coverage?.description).toBe(sourceNotice);
    expect(coverage?.openGraphDescription).toBe(sourceNotice);
    expect(coverage?.canonicalUrl).toBe("https://gurinnae.example/coverage");
  });

  it("carries system source statuses into canonical SEO and OpenGraph copy", () => {
    expect(
      publicSeoPresentation(
        "PUB-034",
        "시스템 상태",
        { getPublicSystemStatus: systemStatusResponse() },
        new URL("https://gurinnae.example/status"),
      ),
    ).toEqual({
      title: "시스템 상태 · 구린네",
      description: sourceNotice,
      openGraphDescription: sourceNotice,
      canonicalUrl: "https://gurinnae.example/status",
      robots: "index,follow",
    });
  });

  it("fails closed when coverage or system source authority is incomplete", () => {
    const coverage = coverageResponse();
    const firstCoverage = coverage.sources[0];
    if (!firstCoverage) throw new Error("출처 범위 기준 행 누락");
    const { interpretationNotice: _coverageNotice, ...coverageWithoutNotice } =
      firstCoverage;
    expect(() =>
      publicSeoPresentation(
        "PUB-015",
        "데이터 범위",
        {
          getCoverage: {
            ...coverage,
            sources: [coverageWithoutNotice],
          },
        },
        new URL("https://gurinnae.example/coverage"),
      ),
    ).toThrow();

    const system = systemStatusResponse();
    expect(() =>
      publicSeoPresentation(
        "PUB-034",
        "시스템 상태",
        {
          getPublicSystemStatus: {
            ...system,
            sourceStatus: [
              { ...sourceStatus(), internalNote: "must-not-leak" },
            ],
          },
        },
        new URL("https://gurinnae.example/status"),
      ),
    ).toThrow();
  });

  it("provides neutral, canonical SEO before the first search query", () => {
    const result = publicSeoPresentation(
      "PUB-002",
      "통합 검색",
      {},
      new URL("https://gurinnae.example/search"),
    );

    expect(result).toBeDefined();
    expect(result?.description).toBe(result?.openGraphDescription);
    expect(result?.canonicalUrl).toBe("https://gurinnae.example/search");
    expect(result?.robots).toBe("index,follow");
    expect(result?.description).not.toMatch(
      /오류|실패|준비할 수 없습니다|불러오지 못/u,
    );
  });

  it("requires the PUB-020 redistribution notice in canonical SEO metadata", () => {
    const redistributionNotice = "이상 징후 기록이며 위법·부패의 확정이 아님";
    const datasetPage = {
      items: [
        {
          id: "published-cases",
          title: "공개 사례",
          description: "공개 개정본 고정 사례 데이터",
          format: "JSONL",
          coverage: {
            dateRange: { label: "2026년" },
            sourceIds: [],
            recordCount: 1,
            knownGaps: [],
            freshness: {
              asOf: "2026-07-30T00:00:00Z",
              status: "CURRENT",
            },
          },
          license: "CC-BY-4.0",
          updatedAt: "2026-07-30T00:00:00Z",
          redistributionNotice,
        },
      ],
      appliedFilters: {},
      asOf: "2026-07-30T00:00:00Z",
      seo: {
        title: "공개 데이터 · 구린네",
        description: `공개 데이터 · ${redistributionNotice}`,
        openGraphDescription: `공개 데이터 · ${redistributionNotice}`,
        canonicalUrl: "/data",
        robots: "index,follow",
      },
    };

    expect(
      publicSeoPresentation(
        "PUB-020",
        "공개 데이터",
        { listPublicDatasets: datasetPage },
        new URL("https://gurinnae.example/data"),
      ),
    ).toEqual({
      ...datasetPage.seo,
      canonicalUrl: "https://gurinnae.example/data",
    });

    expect(() =>
      publicSeoPresentation(
        "PUB-020",
        "공개 데이터",
        {
          listPublicDatasets: {
            ...datasetPage,
            seo: {
              ...datasetPage.seo,
              description: "공개 데이터",
              openGraphDescription: "공개 데이터",
            },
          },
        },
        new URL("https://gurinnae.example/data"),
      ),
    ).toThrow("상태 고지 누락");
  });
});
