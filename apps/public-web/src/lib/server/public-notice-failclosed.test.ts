import { describe, expect, it } from "vitest";
import {
  publicFailClosedLedgerPresentation,
  publicLedgerPresentation,
} from "./public-presentation";
import {
  PUBLIC_EMPTY_RESULT_NOTICE,
  PUBLIC_OPERATIONAL_INTERPRETATION_NOTICE,
} from "./public-presentation-schemas";
import {
  publicFailClosedSeoPresentation,
  publicSeoPresentation,
} from "./public-seo-presentation";
import { publicStatusPresentation } from "./public-status-presentation";

const asOf = "2026-07-30T00:00:00Z";

function emptyPage(description: string, canonicalUrl: string) {
  return {
    items: [],
    appliedFilters: {},
    asOf,
    seo: {
      title: "공개 대장 · 구린네",
      description,
      openGraphDescription: description,
      canonicalUrl,
      robots: "index,follow",
    },
  };
}

function coverage() {
  return {
    asOf,
    sources: [],
    dateRange: { label: "2026년" },
    recordCounts: {
      sourceDocuments: 0,
      contracts: 0,
      contractLineItems: 0,
      agencies: 0,
      suppliers: 0,
      publicCases: 0,
    },
    knownGaps: [],
    methodologyVersion: "coverage-v1",
  };
}

function systemStatus() {
  return {
    status: "operational",
    asOf,
    affectedCapabilities: [],
    sourceStatus: [],
  };
}

describe("public collection notice closure", () => {
  it.each([
    [
      "PUB-003",
      "listPublicCases",
      "/cases",
      PUBLIC_EMPTY_RESULT_NOTICE,
      "NON_CONCLUSION",
    ],
    [
      "PUB-007",
      "listAgencies",
      "/agencies",
      PUBLIC_OPERATIONAL_INTERPRETATION_NOTICE,
      "INTERPRETATION",
    ],
    [
      "PUB-009",
      "listSuppliers",
      "/suppliers",
      PUBLIC_OPERATIONAL_INTERPRETATION_NOTICE,
      "INTERPRETATION",
    ],
    [
      "PUB-011",
      "listContracts",
      "/contracts",
      PUBLIC_OPERATIONAL_INTERPRETATION_NOTICE,
      "INTERPRETATION",
    ],
    [
      "PUB-016",
      "listSourceStatus",
      "/sources",
      PUBLIC_OPERATIONAL_INTERPRETATION_NOTICE,
      "INTERPRETATION",
    ],
    [
      "PUB-018",
      "listCorrections",
      "/corrections",
      PUBLIC_EMPTY_RESULT_NOTICE,
      "NON_CONCLUSION",
    ],
  ] as const)("%s binds its empty authority to SEO, OpenGraph and the ledger", (screenId, operationId, pathname, notice, kind) => {
    const page = emptyPage(`공개 대장 · ${notice}`, pathname);
    const data = { [operationId]: page };
    const seo = publicSeoPresentation(
      screenId,
      "공개 대장",
      data,
      new URL(pathname, "https://gurinnae.example"),
    );
    const ledger = publicLedgerPresentation(screenId, data);

    expect(seo?.description).toContain(notice);
    expect(seo?.openGraphDescription).toContain(notice);
    expect(ledger?.viewModel.rows).toEqual([]);
    expect(ledger?.viewModel.collectionNotices).toEqual([
      {
        kind,
        label: kind === "NON_CONCLUSION" ? "비확정 고지" : "상태 해석",
        text: notice,
      },
    ]);
  });

  it("uses one publication notice for an all-empty home", () => {
    const publicationPage = emptyPage(PUBLIC_EMPTY_RESULT_NOTICE, "/cases");
    const sourcePage = emptyPage(
      PUBLIC_OPERATIONAL_INTERPRETATION_NOTICE,
      "/sources",
    );
    const data = {
      listPublicCases: publicationPage,
      listCorrections: {
        ...publicationPage,
        seo: { ...publicationPage.seo, canonicalUrl: "/corrections" },
      },
      listSourceStatus: sourcePage,
    };

    const seo = publicSeoPresentation(
      "PUB-001",
      "홈",
      data,
      new URL("https://gurinnae.example/"),
    );
    const ledger = publicLedgerPresentation("PUB-001", data);

    expect(seo?.description).toBe(PUBLIC_EMPTY_RESULT_NOTICE);
    expect(seo?.openGraphDescription).toBe(PUBLIC_EMPTY_RESULT_NOTICE);
    expect(ledger?.viewModel.collectionNotices).toHaveLength(1);
    expect(ledger?.viewModel.collectionNotices[0]?.text).toBe(
      PUBLIC_EMPTY_RESULT_NOTICE,
    );
  });

  it.each([
    ["PUB-015", "getCoverage", "/coverage", coverage()],
    ["PUB-034", "getPublicSystemStatus", "/status", systemStatus()],
  ] as const)("%s closes an empty operational collection", (screenId, operationId, pathname, response) => {
    const data = { [operationId]: response };
    const seo = publicSeoPresentation(
      screenId,
      "운영 현황",
      data,
      new URL(pathname, "https://gurinnae.example"),
    );
    const ledger = publicLedgerPresentation(screenId, data);

    expect(seo?.description).toBe(PUBLIC_OPERATIONAL_INTERPRETATION_NOTICE);
    expect(seo?.openGraphDescription).toBe(
      PUBLIC_OPERATIONAL_INTERPRETATION_NOTICE,
    );
    expect(ledger?.viewModel.collectionNotices[0]?.text).toBe(
      PUBLIC_OPERATIONAL_INTERPRETATION_NOTICE,
    );
  });

  it("rejects absent, empty and mismatched list SEO authority", () => {
    const requestUrl = new URL("https://gurinnae.example/cases");
    expect(() =>
      publicSeoPresentation("PUB-003", "공개 사례", {}, requestUrl),
    ).toThrow("주 응답 누락");
    expect(() =>
      publicSeoPresentation(
        "PUB-003",
        "공개 사례",
        { listPublicCases: emptyPage("", "/cases") },
        requestUrl,
      ),
    ).toThrow();
    expect(() =>
      publicSeoPresentation(
        "PUB-003",
        "공개 사례",
        { listPublicCases: emptyPage("일반 설명", "/cases") },
        requestUrl,
      ),
    ).toThrow("상태 고지 누락");
  });

  it("rejects missing home, coverage and status authority", () => {
    expect(() =>
      publicSeoPresentation(
        "PUB-001",
        "홈",
        {},
        new URL("https://gurinnae.example/"),
      ),
    ).toThrow("주 응답 누락");
    expect(() =>
      publicSeoPresentation(
        "PUB-015",
        "범위",
        {},
        new URL("https://gurinnae.example/coverage"),
      ),
    ).toThrow("주 응답 누락");
    expect(() =>
      publicSeoPresentation(
        "PUB-034",
        "상태",
        {},
        new URL("https://gurinnae.example/status"),
      ),
    ).toThrow("주 응답 누락");
  });

  it("keeps a canonical notice-only fallback after a presentation failure", () => {
    const requestUrl = new URL(
      "https://gurinnae.example/agencies/agency-1?internal=discard",
    );
    expect(
      publicFailClosedSeoPresentation("PUB-008", "기관 상세", requestUrl),
    ).toEqual({
      title: "기관 상세 · 구린네",
      description: PUBLIC_OPERATIONAL_INTERPRETATION_NOTICE,
      openGraphDescription: PUBLIC_OPERATIONAL_INTERPRETATION_NOTICE,
      canonicalUrl: "https://gurinnae.example/agencies/agency-1",
      robots: "index,follow",
    });
    expect(
      publicFailClosedLedgerPresentation("PUB-003")?.viewModel
        .collectionNotices[0]?.text,
    ).toBe(PUBLIC_EMPTY_RESULT_NOTICE);
  });

  it("fixes the exact copy-guidelines section 12 notice", () => {
    expect(PUBLIC_EMPTY_RESULT_NOTICE).toBe(
      "현재 선택한 조건에서 공개된 사례가 없습니다. 이는 문제 없음이나 청렴성을 의미하지 않으며, 수집 범위와 검토 상태에 따라 결과가 달라질 수 있습니다.",
    );
  });

  it("rejects a missing detail primary before secondary data can be presented", () => {
    expect(() =>
      publicStatusPresentation("PUB-008", {
        listAgencyContracts: { items: [{ title: "노출 금지 계약" }] },
      }),
    ).toThrow("getAgency");
  });
});
