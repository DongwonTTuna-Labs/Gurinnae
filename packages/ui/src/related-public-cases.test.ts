import { describe, expect, it } from "vitest";
import { buildRelatedPublicCases } from "./related-public-cases";
import type { ScreenSectionProjection } from "./screen-projection";

describe("buildRelatedPublicCases", () => {
  it("projects only a title, Korean status and canonical public case href", () => {
    const projection = relatedProjection([
      record({
        slug: "case-2026-001",
        title: "해솔시 청사 유지보수 계약",
        publicState: "PUBLISHED_ANOMALY",
        nonConclusion:
          "현재 자료만으로 위법성이나 부패 여부를 판단할 수 없습니다.",
        summary: "렌더하지 않는 내부 요약",
        href: "https://attacker.invalid/cases/case-2026-001",
      }),
    ]);

    expect(buildRelatedPublicCases(projection)).toEqual([
      {
        title: "해솔시 청사 유지보수 계약",
        status: "이상 징후 게시됨",
        notice: {
          kind: "NON_CONCLUSION",
          label: "비확정 고지",
          text: "현재 자료만으로 위법성이나 부패 여부를 판단할 수 없습니다.",
        },
        href: "/cases/case-2026-001",
      },
    ]);
  });

  it("accepts a projected case href only when the server verified it", () => {
    const projection = relatedProjection([
      record({
        slug: "bad/slug",
        title: "한빛군 재난 안전 계약",
        publicState: "PUBLISHED_EXPLAINED",
        nonConclusion:
          "추가 자료로 차이가 설명됐으며 탐지와 검증 과정을 함께 공개합니다.",
        href: "/cases/case-2026-002",
      }),
    ]);

    expect(
      buildRelatedPublicCases(projection, [
        {
          label: "한빛군 재난 안전 계약",
          href: "/cases/case-2026-002",
        },
      ]),
    ).toEqual([
      {
        title: "한빛군 재난 안전 계약",
        status: "소명 병기 게시됨",
        notice: {
          kind: "NON_CONCLUSION",
          label: "비확정 고지",
          text: "추가 자료로 차이가 설명됐으며 탐지와 검증 과정을 함께 공개합니다.",
        },
        href: "/cases/case-2026-002",
      },
    ]);
  });

  it("fails closed for unverified, external and incomplete records", () => {
    const projection = relatedProjection([
      record({
        slug: "bad/slug",
        title: "검증되지 않은 경로",
        publicState: "PUBLISHED_ANOMALY",
        nonConclusion:
          "현재 자료만으로 위법성이나 부패 여부를 판단할 수 없습니다.",
        href: "/cases/unverified",
      }),
      record({
        slug: "also/bad",
        title: "외부 경로",
        publicState: "PUBLISHED_ANOMALY",
        nonConclusion:
          "현재 자료만으로 위법성이나 부패 여부를 판단할 수 없습니다.",
        href: "https://example.com/cases/external",
      }),
      record({ slug: "case-without-status", title: "상태 없음" }),
    ]);

    expect(
      buildRelatedPublicCases(projection, [
        { label: "외부 경로", href: "https://example.com/cases/external" },
      ]),
    ).toEqual([]);
  });

  it("preserves valid source order after dropping invalid rows", () => {
    const projection = relatedProjection([
      record({
        slug: "invalid/slug",
        title: "제외되는 사건",
        publicState: "PUBLISHED_ANOMALY",
        nonConclusion:
          "현재 자료만으로 위법성이나 부패 여부를 판단할 수 없습니다.",
      }),
      record({
        slug: "case-2026-004",
        title: "첫 유효 사건",
        publicState: "PUBLISHED_ANOMALY",
        nonConclusion:
          "현재 자료만으로 위법성이나 부패 여부를 판단할 수 없습니다.",
      }),
      record({
        slug: "case-2026-005",
        title: "두 번째 유효 사건",
        publicState: "PUBLISHED_EXPLAINED",
        nonConclusion:
          "추가 자료로 차이가 설명됐으며 탐지와 검증 과정을 함께 공개합니다.",
      }),
    ]);

    expect(buildRelatedPublicCases(projection)).toEqual([
      {
        title: "첫 유효 사건",
        status: "이상 징후 게시됨",
        notice: {
          kind: "NON_CONCLUSION",
          label: "비확정 고지",
          text: "현재 자료만으로 위법성이나 부패 여부를 판단할 수 없습니다.",
        },
        href: "/cases/case-2026-004",
      },
      {
        title: "두 번째 유효 사건",
        status: "소명 병기 게시됨",
        notice: {
          kind: "NON_CONCLUSION",
          label: "비확정 고지",
          text: "추가 자료로 차이가 설명됐으며 탐지와 검증 과정을 함께 공개합니다.",
        },
        href: "/cases/case-2026-005",
      },
    ]);
  });

  it.each([
    "PUB-008",
    "PUB-010",
  ] as const)("binds %s recentCases to the same closed row model", (screenId) => {
    const projection = relatedProjection([
      record({
        slug: "case-2026-006",
        title: "기관·업체 관련 공개 사건",
        publicState: "PUBLISHED_ANOMALY",
        nonConclusion:
          "현재 자료만으로 위법성이나 부패 여부를 판단할 수 없습니다.",
      }),
    ]);
    const recentCases = {
      ...projection,
      screenId,
      sectionId: "cases",
      fields: projection.fields.map((field) => ({
        ...field,
        name: "recentCases",
      })),
    };

    expect(buildRelatedPublicCases(recentCases)).toHaveLength(1);
    expect(buildRelatedPublicCases(recentCases)[0]?.notice.kind).toBe(
      "NON_CONCLUSION",
    );
  });

  it("rejects projections from any other screen or section", () => {
    const projection = relatedProjection([
      record({
        slug: "case-2026-003",
        title: "다른 화면의 사건",
        publicState: "PUBLISHED_ANOMALY",
        nonConclusion:
          "현재 자료만으로 위법성이나 부패 여부를 판단할 수 없습니다.",
      }),
    ]);

    expect(
      buildRelatedPublicCases({ ...projection, screenId: "PUB-004" }),
    ).toEqual([]);
    expect(
      buildRelatedPublicCases({ ...projection, sectionId: "identity" }),
    ).toEqual([]);
  });
});

function relatedProjection(
  items: ReadonlyArray<ReturnType<typeof record>>,
): ScreenSectionProjection {
  return {
    screenId: "PUB-012",
    sectionId: "related",
    region: "evidence",
    component: "RelatedPublicCases",
    fields: [
      {
        name: "relatedCases",
        label: "관련 사건 목록",
        value: { kind: "list", items, omittedCount: 0 },
        known: true,
        source: "getContract.$.relatedCases",
      },
    ],
    state: "READY",
    errorMessage: null,
    focusTarget: "pub_012__state__success__related",
  };
}

function record(values: Readonly<Record<string, string>>) {
  return {
    kind: "record" as const,
    entries: Object.entries(values).map(([name, value]) => ({
      name,
      label: name,
      value,
    })),
    omittedCount: 0,
  };
}
