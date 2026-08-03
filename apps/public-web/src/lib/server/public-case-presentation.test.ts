import { describe, expect, it } from "vitest";
import { publicCasePresentation } from "./public-case-presentation";

const asOf = "2026-07-30T00:00:00Z";

type EvidenceMetadata = Readonly<{
  sourceUrl: string | null;
  documentTitle: string | null;
  publisher: string | null;
  publishedAt: string | null;
  pageAnchor: string | null;
}>;

function evidence(
  metadata: EvidenceMetadata = {
    sourceUrl: "https://records.example/document.pdf",
    documentTitle: "가상 계약 공고문",
    publisher: "가상 한강시청",
    publishedAt: asOf,
    pageAnchor: "12쪽",
  },
) {
  return {
    id: "80000000-0000-4000-8000-000000000001",
    title: "내부 공개 제목",
    evidenceType: "DOCUMENT",
    sourceLocator: "protected-locator",
    contentSha256: "a".repeat(64),
    publicExcerpt: "공개 발췌",
    restriction: null,
    ...metadata,
  };
}

function response(evidenceItem = evidence()) {
  return {
    slug: "synthetic-case",
    title: "가상 계약 공개 사건",
    publicState: "PUBLISHED_ANOMALY",
    revision: 4,
    publishedAt: asOf,
    updatedAt: asOf,
    summary: "공개 자료에서 확인된 계약 차이",
    agencyName: "가상 한강시청",
    contractName: "가상 공공시설 유지보수 계약",
    amount: { amount: "1234567890", currency: "KRW" },
    nonConclusion: "이 기록은 이상 징후이며 위법·부패의 확정이 아닙니다.",
    confirmedFacts: [{ id: "fact-1" }, { id: "fact-2" }],
    criticalUnknowns: [{ id: "unknown-1" }],
    partyResponses: [{ id: "response-1" }],
    signals: [],
    counterEvidence: [],
    claims: [],
    evidence: [evidenceItem],
    timeline: [],
    corrections: [],
    freshness: { asOf, status: "CURRENT" },
    limitations: [],
    seo: {
      title: "가상 계약 공개 사건 · 구린네",
      description: "가상 계약 공개 사건의 근거와 미확인 범위",
      openGraphDescription: "가상 계약 공개 사건의 근거와 미확인 범위",
      canonicalUrl: "/cases/synthetic-case",
      robots: "index,follow",
    },
  };
}

const requestUrl = new URL(
  "https://gurinnae.example/cases/synthetic-case?source=test",
);

describe("closed public case presentation", () => {
  it("projects the lead, source metadata and same-origin SEO without raw evidence fields", () => {
    const presentation = publicCasePresentation(
      "PUB-004",
      { getPublicCase: response() },
      requestUrl,
    );

    expect(presentation?.lead).toMatchObject({
      agencyName: "가상 한강시청",
      contractName: "가상 공공시설 유지보수 계약",
      amountLabel: "₩1,234,567,890",
      confirmedCount: 2,
      unknownCount: 1,
      responseCount: 1,
    });
    expect(presentation?.evidence).toEqual([
      {
        key: "public-evidence-1",
        documentTitle: "가상 계약 공고문",
        publisher: "가상 한강시청",
        publishedAt: asOf,
        sourceUrl: "https://records.example/document.pdf",
        pageAnchor: "12쪽",
      },
    ]);
    expect(presentation?.seo).toEqual({
      title: "가상 계약 공개 사건 · 구린네",
      description: "가상 계약 공개 사건의 근거와 미확인 범위",
      openGraphDescription: "가상 계약 공개 사건의 근거와 미확인 범위",
      canonicalUrl: "https://gurinnae.example/cases/synthetic-case",
      robots: "index,follow",
    });
    const browserEnvelope = JSON.stringify(presentation);
    expect(browserEnvelope).not.toContain("protected-locator");
    expect(browserEnvelope).not.toContain("contentSha256");
    expect(browserEnvelope).not.toContain("publicExcerpt");
    expect(browserEnvelope).not.toContain(
      "80000000-0000-4000-8000-000000000001",
    );
  });

  it("rejects undeclared response fields at the server boundary", () => {
    expect(() =>
      publicCasePresentation(
        "PUB-004",
        { getPublicCase: { ...response(), internalOnly: true } },
        requestUrl,
      ),
    ).toThrow();
  });

  it("rejects a never-published state from the public detail surface", () => {
    expect(() =>
      publicCasePresentation(
        "PUB-004",
        {
          getPublicCase: {
            ...response(),
            publicState: "NEVER_PUBLISHED",
          },
        },
        requestUrl,
      ),
    ).toThrow();
  });

  it("requires the nullable lead fields while preserving explicit nulls", () => {
    const nullable = {
      ...response(),
      agencyName: null,
      contractName: null,
      amount: null,
    };
    expect(
      publicCasePresentation("PUB-004", { getPublicCase: nullable }, requestUrl)
        ?.lead,
    ).toMatchObject({
      agencyName: null,
      contractName: null,
      amountLabel: null,
    });

    const { agencyName: _agencyName, ...missingAgencyName } = response();
    expect(() =>
      publicCasePresentation(
        "PUB-004",
        { getPublicCase: missingAgencyName },
        requestUrl,
      ),
    ).toThrow();
  });

  it("rejects non-HTTPS evidence links", () => {
    const value = response(
      evidence({
        sourceUrl: "http://records.example/document.pdf",
        documentTitle: "가상 계약 공고문",
        publisher: "가상 한강시청",
        publishedAt: asOf,
        pageAnchor: "12쪽",
      }),
    );
    expect(() =>
      publicCasePresentation("PUB-004", { getPublicCase: value }, requestUrl),
    ).toThrow();
  });

  it("rejects a cross-origin canonical URL", () => {
    const value = response();
    value.seo.canonicalUrl = "https://attacker.example/cases/synthetic-case";
    expect(() =>
      publicCasePresentation("PUB-004", { getPublicCase: value }, requestUrl),
    ).toThrow("PUBLIC_CASE_CANONICAL_NOT_SAME_ORIGIN");
  });

  it("omits evidence rows whose approved source metadata is entirely absent", () => {
    const value = response(
      evidence({
        sourceUrl: null,
        documentTitle: null,
        publisher: null,
        publishedAt: null,
        pageAnchor: null,
      }),
    );
    const presentation = publicCasePresentation(
      "PUB-004",
      { getPublicCase: value },
      requestUrl,
    );

    expect(presentation?.evidence).toEqual([]);
  });
});
