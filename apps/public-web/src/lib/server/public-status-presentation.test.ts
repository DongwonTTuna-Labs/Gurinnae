import { describe, expect, it } from "vitest";
import { publicStatusPresentation } from "./public-status-presentation";

const nonConclusion =
  "공개자료 비교에서 설명이 필요한 차이가 확인됐습니다. 현재 자료만으로 위법성이나 부패 여부를 판단할 수 없습니다.";
const interpretationNotice =
  "이 상태는 자료의 수집·공개·검토 상태이며 위법성이나 부패 여부에 대한 판단이 아닙니다.";
const asOf = "2026-07-30T00:00:00Z";

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
      interpretationNotice,
    },
    links: [],
    seo: {
      title: "데이터 출처 상세 · 구린네",
      description: interpretationNotice,
      openGraphDescription: interpretationNotice,
      canonicalUrl: "/sources/source-1",
      robots: "index,follow",
    },
  };
}

describe("public status presentation", () => {
  it.each([
    [
      "PUB-004",
      "getPublicCase",
      {
        title: "공개 사건",
        publicState: "PUBLISHED_ANOMALY",
        nonConclusion,
      },
      { label: "사건명", text: "공개 사건" },
      { label: "공개 상태", text: "이상 징후 게시됨" },
      "NON_CONCLUSION",
      "비확정 고지",
      nonConclusion,
    ],
    [
      "PUB-005",
      "getPublicCaseRevision",
      {
        content: {
          case: {
            title: "공개 사건 개정본",
            publicState: "PUBLISHED_ANOMALY",
          },
          nonConclusion,
        },
      },
      { label: "사건명", text: "공개 사건 개정본" },
      { label: "공개 상태", text: "이상 징후 게시됨" },
      "NON_CONCLUSION",
      "비확정 고지",
      nonConclusion,
    ],
    [
      "PUB-006",
      "getCaseReproducibility",
      { caseSlug: "case-1", nonConclusion },
      { label: "사건 식별자", text: "case-1" },
      undefined,
      "NON_CONCLUSION",
      "비확정 고지",
      nonConclusion,
    ],
    [
      "PUB-008",
      "getAgency",
      {
        name: "가상 기관",
        freshness: { status: "CURRENT" },
        interpretationNotice,
      },
      { label: "기관명", text: "가상 기관" },
      { label: "수집 상태", text: "현재" },
      "INTERPRETATION",
      "상태 해석",
      interpretationNotice,
    ],
    [
      "PUB-010",
      "getSupplier",
      {
        name: "가상 업체",
        freshness: { status: "CURRENT" },
        interpretationNotice,
      },
      { label: "업체명", text: "가상 업체" },
      { label: "수집 상태", text: "현재" },
      "INTERPRETATION",
      "상태 해석",
      interpretationNotice,
    ],
    [
      "PUB-012",
      "getContract",
      { title: "가상 계약", status: "ACTIVE", interpretationNotice },
      { label: "계약명", text: "가상 계약" },
      { label: "계약 상태", text: "활성" },
      "INTERPRETATION",
      "상태 해석",
      interpretationNotice,
    ],
    [
      "PUB-019",
      "getCorrection",
      {
        data: {
          summary: "금액 표기 정정",
          publicState: "CORRECTED",
          nonConclusion,
        },
      },
      { label: "정정 요약", text: "금액 표기 정정" },
      { label: "공개 상태", text: "정정됨" },
      "NON_CONCLUSION",
      "비확정 고지",
      nonConclusion,
    ],
    [
      "PUB-017",
      "getSource",
      sourceResponse(),
      { label: "출처명", text: "공개 출처" },
      { label: "수집 상태", text: "현재" },
      "INTERPRETATION",
      "상태 해석",
      interpretationNotice,
    ],
  ] as const)("maps %s only from its exact subject, status and notice paths", (screenId, operationId, response, subject, status, kind, label, text) => {
    expect(
      publicStatusPresentation(screenId, { [operationId]: response }),
    ).toEqual({
      subject,
      ...(status ? { status } : {}),
      notice: { kind, label, text },
    });
  });

  it("fails closed when an applicable response breaks any exact binding", () => {
    expect(() =>
      publicStatusPresentation("PUB-005", {
        getPublicCaseRevision: {
          content: {
            case: {
              title: "공개 사건 개정본",
              publicState: "PUBLISHED_ANOMALY",
            },
          },
        },
      }),
    ).toThrow("getPublicCaseRevision.content.nonConclusion");
    expect(() =>
      publicStatusPresentation("PUB-008", {
        getAgency: { name: "가상 기관", interpretationNotice },
      }),
    ).toThrow("getAgency.freshness.status");
    const source = sourceResponse();
    const { interpretationNotice: _notice, ...sourceDataWithoutNotice } =
      source.data;
    expect(() =>
      publicStatusPresentation("PUB-017", {
        getSource: { ...source, data: sourceDataWithoutNotice },
      }),
    ).toThrow();
  });

  it("strictly validates the complete source response before binding status", () => {
    const source = sourceResponse();
    const { officialUrl: _officialUrl, ...sourceDataWithoutOfficialUrl } =
      source.data;
    expect(() =>
      publicStatusPresentation("PUB-017", {
        getSource: { ...source, internalNote: "must-not-leak" },
      }),
    ).toThrow();
    expect(() =>
      publicStatusPresentation("PUB-017", {
        getSource: {
          ...source,
          data: { ...source.data, internalNote: "must-not-leak" },
        },
      }),
    ).toThrow();
    expect(() =>
      publicStatusPresentation("PUB-017", {
        getSource: { ...source, data: sourceDataWithoutOfficialUrl },
      }),
    ).toThrow();
  });

  it("returns undefined only when the screen is not applicable", () => {
    expect(publicStatusPresentation("PUB-031", {})).toBeUndefined();
    expect(() => publicStatusPresentation("PUB-008", {})).toThrow("getAgency");
  });
});
